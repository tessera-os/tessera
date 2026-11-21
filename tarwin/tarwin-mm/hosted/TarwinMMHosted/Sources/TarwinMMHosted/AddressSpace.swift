import Foundation

public struct HostedMapCommand {
  public let address: UInt64
  public let size: UInt64
  public let entryOffset: UInt64
  public let entry: HostedMemoryEntry
  public let protection: HostedProtection
  public let copy: Bool

  public init(
    address: UInt64, size: UInt64, entryOffset: UInt64 = 0,
    entry: HostedMemoryEntry, protection: HostedProtection, copy: Bool = false
  ) throws {
    guard address % hostedPageSize == 0, size > 0, size % hostedPageSize == 0,
      address <= UInt64.max - size, entryOffset % hostedPageSize == 0,
      entryOffset <= entry.size, size <= entry.size - entryOffset
    else { throw HostedMemoryError.invalidRange }
    guard protection.isValid, protection.isSubset(of: entry.protection) else {
      throw HostedMemoryError.invalidProtection
    }
    self.address = address
    self.size = size
    self.entryOffset = entryOffset
    self.entry = entry
    self.protection = protection
    self.copy = copy
  }
}

public protocol HostedTaskMappings {
  func map(_ command: HostedMapCommand) throws
  func unmap(address: UInt64, size: UInt64) throws
}

public enum HostedFaultResult: Equatable {
  case unmapped, protection, notPresentOnHost, mapped
}

public enum HostedFaultError: Error, Equatable {
  case incompleteRead
}

public final class HostedFileBacking {
  public typealias ReadPage = (_ offset: UInt64, _ buffer: UnsafeMutableRawBufferPointer) throws -> Int

  private final class CachedPage {
    weak var entry: HostedMemoryEntry?
    init(_ entry: HostedMemoryEntry) { self.entry = entry }
  }

  public let size: UInt64
  private let read: ReadPage
  private let lock = NSLock()
  private var pages: [UInt64: CachedPage] = [:]

  public init(size: UInt64, read: @escaping ReadPage) {
    self.size = size
    self.read = read
  }

  fileprivate func page(at offset: UInt64, writable: Bool) throws -> HostedMemoryEntry {
    try lock.withLock {
      if !writable, let page = pages[offset]?.entry { return page }
      var bytes = [UInt8](repeating: 0, count: Int(hostedPageSize))
      let valid = Int(min(hostedPageSize, size - offset))
      let count = try bytes.withUnsafeMutableBytes { try read(offset, $0) }
      guard count == valid else { throw HostedFaultError.incompleteRead }

      let entry = try HostedMemoryEntry.anonymous(size: hostedPageSize)
      let mapping = try entry.mapLocally(protection: [.read, .write])
      try bytes.withUnsafeBytes {
        try mapping.write(UnsafeRawBufferPointer(rebasing: $0[..<valid]))
      }
      if writable { return entry }
      let readOnly = try entry.restricted(to: .read)
      if pages.count.isMultiple(of: 64) {
        pages = pages.filter { $0.value.entry != nil }
      }
      pages[offset] = CachedPage(readOnly)
      return readOnly
    }
  }
}

public final class HostedAddressSpace {
  private struct FileRegion {
    let range: Range<UInt64>
    let backing: HostedFileBacking
    let offset: UInt64
    let protection: HostedProtection
  }

  private struct Mapping {
    let command: HostedMapCommand
    let charged: Bool
  }

  public let window: Range<UInt64>
  private let task: any HostedTaskMappings
  private let lock = NSLock()
  private var files: [UInt64: FileRegion] = [:]
  private var mappings: [UInt64: Mapping] = [:]

  public init(window: Range<UInt64>, task: any HostedTaskMappings) throws {
    guard !window.isEmpty, window.lowerBound % hostedPageSize == 0,
      window.upperBound % hostedPageSize == 0
    else { throw HostedMemoryError.invalidRange }
    self.window = window
    self.task = task
  }

  public func reserveFile(
    address: UInt64, size: UInt64, backing: HostedFileBacking, offset: UInt64,
    protection: HostedProtection
  ) throws {
    try lock.withLock {
      let range = try checkFree(address: address, size: size)
      guard offset % hostedPageSize == 0, offset < backing.size,
        size - hostedPageSize < backing.size - offset
      else { throw HostedMemoryError.invalidRange }
      guard protection == .read || protection == [.read, .write] else {
        throw HostedMemoryError.invalidProtection
      }
      files[address] = FileRegion(range: range, backing: backing, offset: offset, protection: protection)
    }
  }

  public func map(_ command: HostedMapCommand, charged: Bool = true) throws {
    try lock.withLock {
      _ = try checkFree(address: command.address, size: command.size)
      try install(command, charged: charged)
    }
  }

  public func mapBatch(_ batch: [(command: HostedMapCommand, charged: Bool)]) throws {
    try lock.withLock {
      var installed: [HostedMapCommand] = []
      do {
        for (command, charged) in batch {
          _ = try checkFree(address: command.address, size: command.size)
          try install(command, charged: charged)
          installed.append(command)
        }
      } catch {
        var failed = false
        for command in installed.reversed() {
          do {
            try task.unmap(address: command.address, size: command.size)
            mappings.removeValue(forKey: command.address)
          } catch { failed = true }
        }
        if failed { throw HostedMemoryError.rollbackFailed }
        throw error
      }
    }
  }

  public func fault(address: UInt64, access: HostedProtection) throws -> HostedFaultResult {
    try lock.withLock {
      guard access == .read || access == .write || access == .execute else { return .protection }
      if let mapped = mappings.values.first(where: {
        let mapped = $0.command
        return address >= mapped.address && address - mapped.address < mapped.size
      }) {
        return mapped.command.protection.contains(access) ? .notPresentOnHost : .protection
      }
      guard let file = files.values.first(where: { $0.range.contains(address) }) else {
        return .unmapped
      }
      guard file.protection.contains(access) else { return .protection }
      let pageAddress = address & ~(hostedPageSize - 1)
      let offset = file.offset + (pageAddress - file.range.lowerBound)
      let entry = try file.backing.page(at: offset, writable: file.protection.contains(.write))
      let map = try HostedMapCommand(
        address: pageAddress, size: hostedPageSize, entry: entry, protection: file.protection)
      try install(map, charged: true)
      return .mapped
    }
  }

  public func unmap(address: UInt64, size: UInt64) throws {
    try lock.withLock {
      if let file = files[address], UInt64(file.range.count) == size {
        try task.unmap(address: address, size: size)
        mappings = mappings.filter { !file.range.contains($0.key) }
        files.removeValue(forKey: address)
      } else if let map = mappings[address], map.command.size == size,
        !files.values.contains(where: { $0.range.contains(address) })
      {
        try task.unmap(address: address, size: size)
        mappings.removeValue(forKey: address)
      } else {
        throw HostedMemoryError.invalidRange
      }
    }
  }

  public var footprint: UInt64 {
    lock.withLock {
      var seen: [ObjectIdentifier: [Range<UInt64>]] = [:]
      var bytes: UInt64 = 0
      func charge(_ n: UInt64) {
        let remaining = UInt64.max - bytes
        bytes += min(n, remaining)
      }
      for mapping in mappings.values where mapping.charged {
        let map = mapping.command
        if map.copy {
          charge(map.size)
        } else {
          let offset = map.entry.objectOffset + map.entryOffset
          let span = offset..<(offset + map.size)
          seen[map.entry.objectID, default: []].append(span)
        }
      }
      for spans in seen.values {
        var end: UInt64 = 0
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) where end < span.upperBound {
          charge(span.upperBound - max(end, span.lowerBound))
          end = span.upperBound
        }
      }
      return bytes
    }
  }

  public var occupiedRanges: [Range<UInt64>] {
    lock.withLock {
      files.values.map(\.range) + mappings.values.map {
        $0.command.address..<($0.command.address + $0.command.size)
      }
    }
  }

  private func install(_ command: HostedMapCommand, charged: Bool) throws {
    try task.map(command)
    mappings[command.address] = Mapping(command: command, charged: charged)
  }

  private func checkFree(address: UInt64, size: UInt64) throws -> Range<UInt64> {
    guard address >= window.lowerBound, address < window.upperBound,
      address % hostedPageSize == 0, size > 0, size % hostedPageSize == 0,
      size <= window.upperBound - address
    else { throw HostedMemoryError.invalidRange }
    let range = address..<(address + size)
    guard !files.values.contains(where: { $0.range.overlaps(range) }),
      !mappings.values.contains(where: {
        let map = $0.command
        return range.overlaps(map.address..<(map.address + map.size))
      })
    else { throw HostedMemoryError.invalidRange }
    return range
  }
}
