import TarwinArchAarch64
import TarwinLoader
import TarwinW0Verify

public enum W1CodeRole { case process, library }

/// File-backed RX of one authorized member at its committed load bias.
/// Keep the exact archive and its page index pinned and immutable. This
/// eager path only builds an unpublished root, not an active fault handler.
public struct W1ExecutablePages {
  public let code: Range<UInt64>
  private let index: NativePageIndex
  private let segment: NativeExecutableSegment
  private let file: UnsafeRawBufferPointer

  @unsafe public init?(
    _ set: borrowing W1BootSet, plan: W1AddressPlan, role: W1CodeRole,
    nodes: UnsafeMutableBufferPointer<BlakeCv>
  ) {
    let process = role == .process
    let member = process ? set.process : set.library
    let range = process ? plan.processReservation : plan.libraryReservation
    let layout = member.layout
    guard range.lowerBound >= 1 << 32, range.upperBound <= 1 << 43,
      range.lowerBound % layout.biasAlignment == 0,
      range.upperBound - range.lowerBound == layout.reservationBytes,
      layout.code.upperBound <= layout.reservationBytes,
      let value = Self(
        file: member.bytes, image: layout.image, bias: range.lowerBound,
        expected: layout.code, nodes: nodes)
    else { return nil }
    if process {
      guard layout.code.contains(layout.image.entry),
        plan.processEntry == range.lowerBound + layout.image.entry
      else { return nil }
    } else if value.code != plan.libraryCode {
      return nil
    }
    self = value
  }

  init?(
    file: UnsafeRawBufferPointer, image: InspectedImage, bias: UInt64,
    expected: Range<UInt64>, nodes: UnsafeMutableBufferPointer<BlakeCv>
  ) {
    guard !expected.isEmpty, expected.upperBound <= UInt64.max - bias,
      let index = NativePageIndex(file: file, image: image, storage: nodes)
    else { return nil }
    var rx: NativeExecutableSegment?
    for h in stride(
      from: image.programHeaders.lowerBound, to: image.programHeaders.upperBound, by: 56)
    {
      if let s = NativeExecutableSegment(file: file, image: image, programHeader: h, index: index) {
        guard rx == nil, s.pageSize == 16384, s.rva == expected.lowerBound,
          s.fileBytes == expected.upperBound - expected.lowerBound
        else { return nil }
        rx = s
      }
    }
    guard let rx else { return nil }
    self.file = file
    self.index = index
    self.segment = rx
    self.code = (bias + expected.lowerBound)..<(bias + expected.upperBound)
  }

  /// Supply a fresh pinned private frame at the stated PA, disjoint from the
  /// immutable archive, nodes, tables and witness scratch. No writable or
  /// DMA alias may survive publication. cleanToPoU must synchronize the
  /// verified instructions on all participating CPUs before the leaf exists.
  /// On failure discard the frame; do not retry it as unsigned code.
  @unsafe public func install(
    page: UInt64, physical: UInt64, frame: UnsafeMutableRawBufferPointer,
    nodes: UnsafeBufferPointer<BlakeCv>, witnesses: UnsafeMutableRawBufferPointer,
    tables: inout ArmUserTranslation, cleanToPoU: (UnsafeRawBufferPointer) -> Bool
  ) -> Bool {
    guard code.contains(page), page & 16383 == 0, frame.count == 16384,
      physical != 0, physical & 16383 == 0, physical < 1 << 48,
      let src = file.baseAddress, let dst = frame.baseAddress,
      let offset = segment.fileOffset(pageRVA: segment.rva + (page - code.lowerBound)),
      imageContains(UInt64(file.count), offset, 16384),
      let n = index.witnesses(offset: offset, pageSize: 16384, nodes: nodes, into: witnesses)
    else { return false }
    dst.copyMemory(from: src + Int(offset), byteCount: 16384)
    guard
      segment.prepare(
        pageRVA: segment.rva + (page - code.lowerBound),
        frame: frame.bindMemory(to: UInt8.self),
        witnesses: .init(
          rebasing: UnsafeRawBufferPointer(witnesses).bindMemory(to: UInt8.self).prefix(n))),
      cleanToPoU(UnsafeRawBufferPointer(frame))
    else { return false }
    return tables.insert(virtual: page, physical: physical, write: false, execute: true)
  }
}
