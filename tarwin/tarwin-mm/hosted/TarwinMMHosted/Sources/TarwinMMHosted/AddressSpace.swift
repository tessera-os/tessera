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
  func snapshot(address: UInt64, size: UInt64) throws -> HostedMemoryEntry
}

extension HostedTaskMappings {
  public func snapshot(address: UInt64, size: UInt64) throws -> HostedMemoryEntry {
    throw HostedMemoryError.snapshotUnavailable
  }
}

protocol HostedLiveMemoryAccess {
  func readMemory(address: UInt64, size: Int) throws -> Data
  func writeMemory(address: UInt64, data: Data) throws
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

  private final class Mapping {
    let command: HostedMapCommand
    let charged: Bool
    let cleanSince: UInt64?
    let privateFilePage: Bool

    init(command: HostedMapCommand, charged: Bool, cleanSince: UInt64?, privateFilePage: Bool) {
      self.command = command
      self.charged = charged
      self.cleanSince = cleanSince
      self.privateFilePage = privateFilePage
    }
  }

  public let window: Range<UInt64>
  private let task: any HostedTaskMappings
  private let lock = NSLock()
  private var files: [UInt64: FileRegion] = [:]
  private var mappings: [UInt64: Mapping] = [:]
  private var pins: [UInt64: Int] = [:]

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
      try install(Mapping(command: command, charged: charged, cleanSince: nil, privateFilePage: false))
    }
  }

  public func mapBatch(_ batch: [(command: HostedMapCommand, charged: Bool)]) throws {
    try installBatch(batch.map {
      Mapping(command: $0.command, charged: $0.charged, cleanSince: nil, privateFilePage: false)
    })
  }

  public func fork(into childTask: any HostedTaskMappings) throws -> HostedAddressSpace {
    try lock.withLock {
      let child = try HostedAddressSpace(window: window, task: childTask)
      let batch = try mappings.values.sorted { $0.command.address < $1.command.address }.map {
        mapping in
        let map = mapping.command
        guard map.copy || mapping.privateFilePage else { return mapping }
        let entry = try task.snapshot(address: map.address, size: map.size)
        let copy = try HostedMapCommand(address: map.address, size: map.size, entry: entry,
          protection: map.protection, copy: true)
        return Mapping(command: copy, charged: mapping.charged,
          cleanSince: nil, privateFilePage: mapping.privateFilePage)
      }
      try child.installBatch(batch)
      child.files = files
      return child
    }
  }

  private func installBatch(_ batch: [Mapping]) throws {
    try lock.withLock {
      var installed: [HostedMapCommand] = []
      do {
        for mapping in batch {
          let command = mapping.command
          _ = try checkFree(address: command.address, size: command.size)
          try install(mapping)
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
      if let mapped = mapping(containing: address) {
        return mapped.command.protection.contains(access) ? .notPresentOnHost : .protection
      }
      guard let file = files.values.first(where: { $0.range.contains(address) }) else {
        return .unmapped
      }
      guard file.protection.contains(access) else { return .protection }
      _ = try pageIn(address, from: file)
      return .mapped
    }
  }

  public func copyIn(at guestVA: UInt64, count: Int) throws -> Data {
    try withMemoryPin(at: guestVA, count: count, access: .read) { memory in
      try readPinnedData(memory, at: guestVA, count: count)
    }
  }

  public func withPinned<R>(
    at guestVA: UInt64, count: Int, _ body: (UnsafeRawBufferPointer) throws -> R
  ) throws -> R {
    try withMemoryPin(at: guestVA, count: count, access: .read) { memory in
      let bytes = try readPinnedData(memory, at: guestVA, count: count)
      return try bytes.withUnsafeBytes(body)
    }
  }

  public func copyOut(_ data: Data, to guestVA: UInt64) throws {
    try withMemoryPin(at: guestVA, count: data.count, access: .write) {
      try $0?.writeMemory(address: guestVA, data: data)
    }
  }

  private func readPinnedData(
    _ memory: (any HostedLiveMemoryAccess)?, at address: UInt64, count: Int
  ) throws -> Data {
    let bytes = try memory?.readMemory(address: address, size: count) ?? Data()
    guard bytes.count == count else { throw HostedFaultError.incompleteRead }
    return bytes
  }

  private func withMemoryPin<R>(
    at address: UInt64, count: Int, access: HostedProtection,
    _ body: ((any HostedLiveMemoryAccess)?) throws -> R
  ) throws -> R {
    guard count >= 0, address >= window.lowerBound, address <= window.upperBound,
      UInt64(count) <= window.upperBound - address
    else { throw HostedMemoryError.invalidRange }
    guard count > 0 else { return try body(nil) }
    guard let memory = task as? any HostedLiveMemoryAccess else {
      throw HostedMemoryError.liveMemoryUnavailable
    }
    var addresses: [UInt64] = []
    var objects: [ObjectIdentifier: HostedPurgeableState] = [:]
    defer {
      lock.withLock {
        for object in objects.values { object.unpin() }
        for base in addresses {
          if pins[base] == 1 { pins.removeValue(forKey: base) }
          else { pins[base, default: 0] -= 1 }
        }
      }
    }
    try lock.withLock {
      let end = address + UInt64(count)
      var cursor = address
      while cursor < end {
        let mapped: Mapping
        if let resident = mapping(containing: cursor) {
          guard resident.command.protection.contains(access) else {
            throw HostedMemoryError.invalidProtection
          }
          mapped = resident
        } else {
          guard let file = files.values.first(where: { $0.range.contains(cursor) }) else {
            throw HostedMemoryError.invalidRange
          }
          guard file.protection.contains(access) else { throw HostedMemoryError.invalidProtection }
          mapped = try pageIn(cursor, from: file)
        }
        let command = mapped.command
        if !command.copy, let object = command.entry.purgeable, objects[command.entry.objectID] == nil {
          try object.pin(writing: access == .write)
          objects[command.entry.objectID] = object
        }
        pins[command.address, default: 0] += 1
        addresses.append(command.address)
        cursor = command.address + command.size
      }
    }
    return try body(memory)
  }

  private func mapping(containing address: UInt64) -> Mapping? {
    if let page = mappings[address & ~(hostedPageSize - 1)] { return page }
    return mappings.values.first {
      let map = $0.command
      return address >= map.address && address - map.address < map.size
    }
  }

  private func pageIn(_ address: UInt64, from file: FileRegion) throws -> Mapping {
    let pageAddress = address & ~(hostedPageSize - 1)
    let offset = file.offset + (pageAddress - file.range.lowerBound)
    let writable = file.protection.contains(.write)
    let entry = try file.backing.page(at: offset, writable: writable)
    let command = try HostedMapCommand(
      address: pageAddress, size: hostedPageSize, entry: entry, protection: file.protection)
    let mapping = Mapping(command: command, charged: true,
      cleanSince: writable ? nil : DispatchTime.now().uptimeNanoseconds, privateFilePage: writable)
    try install(mapping)
    return mapping
  }

  public func unmap(address: UInt64, size: UInt64) throws {
    try lock.withLock {
      if let file = files[address], UInt64(file.range.count) == size {
        guard !pins.keys.contains(where: file.range.contains) else { throw HostedMemoryError.pinned }
        try task.unmap(address: address, size: size)
        mappings = mappings.filter { !file.range.contains($0.key) }
        files.removeValue(forKey: address)
      } else if let map = mappings[address], map.command.size == size,
        !files.values.contains(where: { $0.range.contains(address) })
      {
        guard pins[address] == nil else { throw HostedMemoryError.pinned }
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
      var emptied: [ObjectIdentifier: Bool] = [:]
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
          let object = map.entry.objectID
          if let purgeable = map.entry.purgeable {
            let empty = emptied[object] ?? ((try? purgeable.state()) == .empty)
            emptied[object] = empty
            if empty { continue }
          }
          let offset = map.entry.objectOffset + map.entryOffset
          let span = offset..<(offset + map.size)
          seen[object, default: []].append(span)
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

  func reclaimCandidates() throws -> [HostedReclaimCandidate] {
    try lock.withLock {
      var candidates: [HostedReclaimCandidate] = []
      var purgeableObjects: Set<ObjectIdentifier> = []
      for (address, mapping) in mappings.sorted(by: { $0.key < $1.key }) {
        guard pins[address] == nil else { continue }
        if let since = mapping.cleanSince {
          candidates.append(HostedReclaimCandidate(since: since) { [weak self, weak mapping] in
            guard let self, let mapping else { return false }
            return try self.lock.withLock {
              guard self.mappings[address] === mapping, self.pins[address] == nil else { return false }
              try self.task.unmap(address: address, size: mapping.command.size)
              self.mappings.removeValue(forKey: address)
              return true
            }
          })
        } else if !mapping.command.copy, let purgeable = mapping.command.entry.purgeable,
          purgeableObjects.insert(mapping.command.entry.objectID).inserted,
          let candidate = try purgeable.candidate()
        {
          candidates.append(candidate)
        }
      }
      return candidates
    }
  }

  public var occupiedRanges: [Range<UInt64>] {
    lock.withLock {
      files.values.map(\.range) + mappings.values.map {
        $0.command.address..<($0.command.address + $0.command.size)
      }
    }
  }

  private func install(_ mapping: Mapping) throws {
    try task.map(mapping.command)
    mappings[mapping.command.address] = mapping
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
