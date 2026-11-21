import CryptoKit
import Foundation
import TarwinLoader
import TarwinMMHosted

private let relroHeader: UInt32 = 0x6474_e552

struct HostedSegment {
  let rva: UInt64
  let size: UInt64
  let protection: HostedProtection
  var bytes: Data
}

public struct HostedRelocation {
  public let rva: UInt64
  public let bytes: Data

  public init(rva: UInt64, bytes: Data) {
    self.rva = rva
    self.bytes = bytes
  }
}

public struct HostedVerifiedImage {
  let identity: SHA256.Digest
  let segments: [HostedSegment]
  let span: UInt64
  let alignment: UInt64
  let entry: UInt64
  let relro: Range<UInt64>?
  let records: Data?
  public let train: Data
  public let trapRVAs: [UInt64]
  public let threadLocalImage: Data?
  public let threadLocalSize: UInt64
  public let threadLocalAlignment: UInt64

  public static func admit(
    _ file: Data, requiresEntry: Bool,
    authorize: (_ file: UnsafeRawBufferPointer, _ layout: InspectedImage) throws -> Void
  ) throws -> Self {
    let snapshot = file.withUnsafeBytes { Data($0) }
    return try snapshot.withUnsafeBytes { bytes in
      guard let layout = inspectELF(
        bytes, target: ElfMachine.aarch64, addressLimit: hostedImageWindowSize, finalized: true,
        requiresEntry: requiresEntry), let train = layout.notes.train
      else { throw HostedImageError.invalidImage }
      try authorize(bytes, layout)
      return try Self(file: bytes, layout: layout, trainRange: train)
    }
  }

  private init(
    file: UnsafeRawBufferPointer, layout: InspectedImage, trainRange: Range<Int>
  ) throws {
    func word<T: FixedWidthInteger>(_ at: Int, _: T.Type) -> T {
      T(littleEndian: file.loadUnaligned(fromByteOffset: at, as: T.self))
    }
    func copy(_ start: UInt64, _ length: UInt64) -> Data {
      Data(file[Int(start)..<Int(start + length)])
    }
    var segments: [HostedSegment] = []
    var relro: Range<UInt64>?
    var tls: Data?
    var tlsSize: UInt64 = 0
    var tlsAlignment: UInt64 = 0
    var alignment = hostedPageSize
    for h in stride(from: layout.programHeaders.lowerBound, to: layout.programHeaders.upperBound, by: 56) {
      let type = word(h, UInt32.self)
      let rva = word(h + 16, UInt64.self)
      let size = word(h + 40, UInt64.self)
      let fileCount = word(h + 32, UInt64.self)
      let fileOffset = word(h + 8, UInt64.self)
      let align = word(h + 48, UInt64.self)
      switch type {
      case 1:
        let protection: HostedProtection
        switch word(h + 4, UInt32.self) {
        case 4: protection = .read
        case 5: protection = [.read, .execute]
        case 6: protection = [.read, .write]
        default: throw HostedImageError.invalidImage
        }
        guard size > 0, !protection.contains(.execute) || fileCount == size else {
          throw HostedImageError.invalidImage
        }
        let rounded = (size + hostedPageSize - 1) & ~(hostedPageSize - 1)
        segments.append(HostedSegment(
          rva: rva, size: rounded, protection: protection, bytes: copy(fileOffset, fileCount)))
        alignment = max(alignment, align)
      case relroHeader:
        guard relro == nil, size > 0, rva % hostedPageSize == 0,
          imageContains(hostedImageWindowSize, rva, size)
        else { throw HostedImageError.invalidImage }
        relro = rva..<((rva + size + hostedPageSize - 1) & ~(hostedPageSize - 1))
      case 7:
        guard tls == nil, fileCount <= size, size <= hostedImageWindowSize,
          align.nonzeroBitCount == 1, align <= hostedImageWindowSize,
          imageContains(UInt64(file.count), fileOffset, fileCount)
        else { throw HostedImageError.invalidImage }
        tls = copy(fileOffset, fileCount)
        tlsSize = size
        tlsAlignment = align
      default: break
      }
    }
    if let relro {
      guard segments.contains(where: {
        $0.protection.contains(.write) && $0.rva <= relro.lowerBound
          && $0.rva + $0.size >= relro.upperBound
      }) else { throw HostedImageError.invalidImage }
    }
    guard let last = segments.last else { throw HostedImageError.invalidImage }
    self.segments = segments
    self.span = last.rva + last.size
    self.alignment = alignment
    self.entry = layout.entry
    self.relro = relro
    self.records = layout.loaderRecords.map { Data(file[$0]) }
    self.trapRVAs = try hostedTrapRVAs(file: file, layout: layout, segments: segments)
    self.train = Data(file[trainRange])
    self.identity = SHA256.hash(data: Data(file))
    self.threadLocalImage = tls
    self.threadLocalSize = tlsSize
    self.threadLocalAlignment = tlsAlignment
  }
}
