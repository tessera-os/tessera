import CryptoKit
import Foundation
import TarwinLoader
import TarwinMMHosted

public final class HostedImageCache {
  private struct Key: Hashable {
    let image: SHA256.Digest
    let train: Data
    let rva, size: UInt64
    let protection: Int32
    let payload: SHA256.Digest
  }

  private final class CachedEntry {
    weak var entry: HostedMemoryEntry?
    init(_ entry: HostedMemoryEntry) { self.entry = entry }
  }

  private let lock = NSLock()
  private var entries: [Key: CachedEntry] = [:]

  public init() {}

  fileprivate func entry(
    image: HostedVerifiedImage, segment: HostedSegment, share: Bool
  ) throws -> HostedMemoryEntry {
    func create() throws -> HostedMemoryEntry {
      try segment.bytes.withUnsafeBytes { bytes in
        if segment.protection.contains(.execute) {
          return try .sealedCode(size: segment.size, verifiedBytes: bytes)
        }
        let entry = try HostedMemoryEntry.anonymous(size: segment.size)
        let writer = try entry.mapLocally(protection: [.read, .write])
        try writer.write(bytes)
        return try entry.restricted(to: segment.protection)
      }
    }
    guard share else { return try create() }
    let key = Key(
      image: image.identity, train: image.train, rva: segment.rva, size: segment.size,
      protection: segment.protection.rawValue, payload: SHA256.hash(data: segment.bytes))
    return try lock.withLock {
      if let entry = entries[key]?.entry { return entry }
      let entry = try create()
      if entries.count.isMultiple(of: 64) {
        entries = entries.filter { $0.value.entry != nil }
      }
      entries[key] = CachedEntry(entry)
      return entry
    }
  }
}

public struct HostedLoadedImage {
  public let range: Range<UInt64>
  public let entry: UInt64?
}

public final class HostedImageLoader {
  public typealias BindingResolver = (
    _ kind: LoaderTableKind, _ table: Data, _ count: UInt32, _ imageBase: UInt64
  ) throws -> [HostedRelocation]

  public typealias TrapRewriter = (_ code: Data, _ rva: UInt64, _ imageBase: UInt64) throws -> Data

  private let space: HostedAddressSpace
  private let cache: HostedImageCache
  private let lock = NSLock()
  private var reservations: [Range<UInt64>] = []

  public init(space: HostedAddressSpace, cache: HostedImageCache) {
    self.space = space
    self.cache = cache
  }

  public func load(
    _ image: HostedVerifiedImage, resolve: BindingResolver, rewrite: TrapRewriter
  ) throws -> HostedLoadedImage {
    try lock.withLock {
      var random = SystemRandomNumberGenerator()
      let base = try HostedImagePlacement.choose(
        window: space.window, occupied: reservations + space.occupiedRanges, span: image.span,
        alignment: image.alignment, using: &random)
      let range = base..<(base + image.span)
      let segments = try relocatedSegments(image, base: base, resolve: resolve)
      var commands: [HostedMapCommand] = []
      for segment in segments {
        var segment = segment
        if segment.protection.contains(.execute) {
          let result = try rewrite(segment.bytes, segment.rva, base)
          guard result.count == segment.bytes.count else { throw HostedImageError.invalidTrapRewrite }
          segment.bytes = result
        }
        let copy = segment.protection.contains(.write)
        let entry = try cache.entry(image: image, segment: segment, share: !copy)
        commands.append(try HostedMapCommand(
          address: base + segment.rva, size: segment.size, entry: entry,
          protection: segment.protection, copy: copy))
      }
      var installed: [HostedMapCommand] = []
      do {
        for command in commands {
          try space.map(command, charged: !command.protection.contains(.execute))
          installed.append(command)
        }
      } catch {
        var failed = false
        for map in installed.reversed() {
          do { try space.unmap(address: map.address, size: map.size) }
          catch { failed = true }
        }
        if failed {
          reservations.append(range)
          throw HostedImageError.rollbackFailed
        }
        throw error
      }
      reservations.append(range)
      return HostedLoadedImage(range: range, entry: image.entry == 0 ? nil : base + image.entry)
    }
  }
}

private func relocatedSegments(
  _ image: HostedVerifiedImage, base: UInt64, resolve: HostedImageLoader.BindingResolver
) throws -> [HostedSegment] {
  var segments = image.segments
  var writes: [Range<UInt64>] = []
  func destination(_ rva: UInt64, length: UInt64) -> Int? {
    guard length > 0, imageContains(image.span, rva, length) else { return nil }
    return segments.firstIndex {
      $0.protection.contains(.write) && rva >= $0.rva
        && imageContains($0.size, rva - $0.rva, length)
    }
  }
  func apply(_ patch: HostedRelocation) throws {
    let size = UInt64(patch.bytes.count)
    guard let index = destination(patch.rva, length: size) else {
      throw HostedImageError.invalidRelocations
    }
    let span = patch.rva..<(patch.rva + size)
    guard !writes.contains(where: { $0.overlaps(span) }) else {
      throw HostedImageError.invalidRelocations
    }
    writes.append(span)
    let offset = Int(patch.rva - segments[index].rva)
    let end = offset + patch.bytes.count
    if segments[index].bytes.count < end { segments[index].bytes.count = end }
    segments[index].bytes.replaceSubrange(offset..<end, with: patch.bytes)
  }

  if let records = image.records {
    guard let directory = records.withUnsafeBytes({
      inspectLoaderRecords($0, addressLimit: image.span)
    }) else { throw HostedImageError.invalidRelocations }
    let relr = directory[.relative]
    var cursor = RelativeCursor(anchorSeen: false, nextBase: 0, bits: 0, at: 0, imageSize: image.span)
    try records.withUnsafeBytes { bytes in
      for p in stride(from: relr.bytes.lowerBound, to: relr.bytes.upperBound, by: 8) {
        let word = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: p, as: UInt64.self))
        guard cursor.accept(word) else { throw HostedImageError.invalidRelocations }
        while cursor.bits != 0 {
          let slot = cursor.take()
          guard let index = destination(slot, length: 8) else {
            throw HostedImageError.invalidRelocations
          }
          let segment = segments[index]
          let offset = Int(slot - segment.rva)
          var relative: UInt64 = 0
          for i in 0..<8 where offset + i < segment.bytes.count {
            relative |= UInt64(segment.bytes[offset + i]) << (8 * i)
          }
          guard relative < image.span else { throw HostedImageError.invalidRelocations }
          var relocated = (base + relative).littleEndian
          try apply(HostedRelocation(rva: slot, bytes: withUnsafeBytes(of: &relocated) { Data($0) }))
        }
      }
    }
    for kind in [LoaderTableKind.authenticated, .imports, .runtime, .dispatch, .tls, .features, .gpu] {
      let table = directory[kind]
      guard table.count != 0 else { continue }
      let data = Data(records[table.bytes])
      if kind == .gpu && data.allSatisfy({ $0 == 0 }) { continue }
      let patches = try resolve(kind, data, table.count, base)
      let expected = kind == .gpu ? 0 : Int(table.count)
      guard patches.count == expected else { throw HostedImageError.invalidRelocations }
      for patch in patches {
        let size: UInt64 = kind == .features ? 1 : 8
        guard patch.bytes.count == size, patch.rva % size == 0 else {
          throw HostedImageError.invalidRelocations
        }
        if kind != .authenticated {
          guard let relro = image.relro, relro.contains(patch.rva),
            size <= relro.upperBound - patch.rva
          else { throw HostedImageError.invalidRelocations }
        }
        try apply(patch)
      }
    }
  }

  guard let relro = image.relro else { return segments }
  return segments.flatMap { segment -> [HostedSegment] in
    let end = segment.rva + segment.size
    guard segment.rva..<end ~= relro.lowerBound else { return [segment] }
    func piece(_ lo: UInt64, _ hi: UInt64, _ protection: HostedProtection) -> HostedSegment? {
      guard lo < hi else { return nil }
      let start = min(Int(lo - segment.rva), segment.bytes.count)
      let stop = min(Int(hi - segment.rva), segment.bytes.count)
      return HostedSegment(
        rva: lo, size: hi - lo, protection: protection, bytes: Data(segment.bytes[start..<stop]))
    }
    return [
      piece(segment.rva, relro.lowerBound, segment.protection),
      piece(relro.lowerBound, relro.upperBound, .read),
      piece(relro.upperBound, end, segment.protection),
    ].compactMap { $0 }
  }
}
