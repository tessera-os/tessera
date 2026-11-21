import CryptoKit
import Foundation
import TarwinLoader
import TarwinMMHosted
import TarwinTaskProtocol

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
  public let siteMap: [UInt64: UInt64]
}

public final class HostedImageLoader {
  public typealias BindingResolver = (
    _ kind: LoaderTableKind, _ table: Data, _ count: UInt32, _ imageBase: UInt64
  ) throws -> [HostedRelocation]

  public typealias TrapRewriter = (
    _ code: Data, _ rva: UInt64, _ imageBase: UInt64, _ veneersAt: UInt64
  ) throws -> (text: Data, veneers: Data, siteMap: [UInt64: UInt64])

  public typealias GroupBindingResolver = (
    _ imageIndex: Int, _ imageBases: [UInt64], _ kind: LoaderTableKind, _ table: Data, _ count: UInt32
  ) throws -> [HostedRelocation]

  public typealias GroupTrapRewriter = (
    _ imageIndex: Int, _ code: Data, _ rva: UInt64, _ imageBase: UInt64, _ veneersAt: UInt64
  ) throws -> (text: Data, veneers: Data, siteMap: [UInt64: UInt64])

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
    try loadGroup([image], resolve: { _, bases, kind, table, count in
      try resolve(kind, table, count, bases[0])
    }, rewrite: { _, code, rva, base, veneersAt in
      try rewrite(code, rva, base, veneersAt)
    })[0]
  }

  public func loadGroup(
    _ images: [HostedVerifiedImage], resolve: GroupBindingResolver, rewrite: GroupTrapRewriter
  ) throws -> [HostedLoadedImage] {
    try lock.withLock {
      var random = SystemRandomNumberGenerator()
      let gatePage = TaskGatePage.address..<(TaskGatePage.address + hostedPageSize)
      let occupied = reservations + space.occupiedRanges + [gatePage]
      var ranges: [Range<UInt64>] = []
      for image in images {
        let base = try HostedImagePlacement.choose(
          window: space.window, occupied: occupied + ranges, span: image.span,
          alignment: image.alignment, using: &random)
        ranges.append(base..<(base + image.span))
      }
      let bases = ranges.map(\.lowerBound)
      var sidecars: [Range<UInt64>] = []
      var commands: [HostedMapCommand] = []
      var loaded: [HostedLoadedImage] = []
      for index in images.indices {
        let (image, mappings) = try stage(
          images[index], range: ranges[index],
          occupied: occupied + ranges.enumerated().compactMap { $0.offset == index ? nil : $0.element },
          sidecars: &sidecars,
          resolve: { kind, table, count, _ in try resolve(index, bases, kind, table, count) },
          rewrite: { code, rva, base, veneersAt in try rewrite(index, code, rva, base, veneersAt) })
        loaded.append(image)
        commands += mappings
      }
      do {
        try space.mapBatch(commands.map { (command: $0, charged: !$0.protection.contains(.execute)) })
      } catch HostedMemoryError.rollbackFailed {
        reservations += ranges + sidecars
        throw HostedImageError.rollbackFailed
      }
      reservations += ranges + sidecars
      return loaded
    }
  }

  private func stage(
    _ image: HostedVerifiedImage, range: Range<UInt64>, occupied: [Range<UInt64>],
    sidecars: inout [Range<UInt64>], resolve: BindingResolver, rewrite: TrapRewriter
  ) throws -> (HostedLoadedImage, [HostedMapCommand]) {
    let base = range.lowerBound
    let segments = try relocatedSegments(image, base: base, resolve: resolve)
    let imageMappings = segments.map { (base + $0.rva)..<(base + $0.rva + $0.size) }
    var veneerCommands: [HostedMapCommand] = []
    var siteMap: [UInt64: UInt64] = [:]
    let trapSites = Set(image.trapRVAs.map { base + $0 })
    var commands: [HostedMapCommand] = []
    for segment in segments {
      var segment = segment
      if segment.protection.contains(.execute) {
        let start = base + segment.rva
        let end = start + segment.size
        let gap = veneerGap(
          after: end, window: space.window, occupied: occupied + imageMappings + sidecars)
        let veneersAt = gap?.lowerBound ?? end
        let result = try rewrite(segment.bytes, segment.rva, base, veneersAt)
        let veneerSize = UInt64(result.veneers.count)
        let textEnd = start + UInt64(segment.bytes.count)
        let expected = trapSites.filter { start <= $0 && $0 < textEnd }
        guard result.text.count == segment.bytes.count, veneerSize % 4 == 0,
          Set(result.siteMap.values) == expected, result.siteMap.count == expected.count,
          result.siteMap.keys.allSatisfy({
            $0 >= veneersAt && $0 - veneersAt < veneerSize && $0 % 4 == 0
          })
        else { throw HostedImageError.invalidTrapRewrite }
        segment.bytes = result.text
        if veneerSize != 0 {
          guard let gap, veneerSize <= UInt64(gap.count) else {
            throw HostedImageError.noPlacement
          }
          let size = (veneerSize + hostedPageSize - 1) & ~(hostedPageSize - 1)
          let veneer = HostedSegment(
            rva: veneersAt &- base, size: size, protection: [.read, .execute],
            bytes: result.veneers)
          let entry = try cache.entry(image: image, segment: veneer, share: true)
          veneerCommands.append(try HostedMapCommand(
            address: veneersAt, size: size, entry: entry, protection: veneer.protection))
          sidecars.append(veneersAt..<(veneersAt + size))
          siteMap.merge(result.siteMap) { current, _ in current }
        }
      }
      let copy = segment.protection.contains(.write)
      let entry = try cache.entry(image: image, segment: segment, share: !copy)
      commands.append(try HostedMapCommand(
        address: base + segment.rva, size: segment.size, entry: entry,
        protection: segment.protection, copy: copy))
    }
    return (HostedLoadedImage(
      range: range, entry: image.entry == 0 ? nil : base + image.entry, siteMap: siteMap),
      commands + veneerCommands)
  }
}

private func veneerGap(
  after textEnd: UInt64, window: Range<UInt64>, occupied: [Range<UInt64>]
) -> Range<UInt64>? {
  let nearby = UInt64(1 << 27)
  let lower = max(window.lowerBound, textEnd > nearby ? textEnd - nearby : 0)
  let upper = textEnd + min(nearby, window.upperBound - textEnd)
  guard lower < upper else { return nil }
  var cursor = lower
  var before: Range<UInt64>?
  for range in occupied.sorted(by: { $0.lowerBound < $1.lowerBound }) + [upper..<upper]
    where range.upperBound > lower && range.lowerBound <= upper
  {
    if cursor < range.lowerBound {
      if cursor >= textEnd { return cursor..<range.lowerBound }
      before = cursor..<min(range.lowerBound, textEnd)
    }
    cursor = max(cursor, range.upperBound)
  }
  return before
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
