/// Capture this descriptor from the immutable, authorized image at load time.
/// On fault, the page RVA selects its file offset, never a caller-supplied
/// offset or proof direction. The segment, cache root, and mapping must remain
/// protected from writes for the lifetime of the mapping.
public struct NativeExecutableSegment {
  public let rva: UInt64
  public let fileBytes: UInt64
  public let pageSize: UInt64
  private let fileStart: UInt64
  private let index: NativePageIndex

  public init?(
    file: UnsafeRawBufferPointer, image: InspectedImage, programHeader: Int,
    index: NativePageIndex
  ) {
    let h = programHeader
    let headers = image.programHeaders
    guard file.count >= 64, headers.lowerBound >= 0, headers.upperBound <= file.count,
      h >= headers.lowerBound, h <= headers.upperBound - 56, (h - headers.lowerBound) % 56 == 0,
      let id = image.notes.buildID, id.lowerBound >= 0, id.upperBound <= file.count, id.count == 32,
      file.count > 3373, index.canonicalSize == UInt64(file.count - 3373)
    else { return nil }
    let r = ELFReader(bytes: file)
    let page = imagePage(r.u16(18))
    let start = r.u64(h + 8)
    let bytes = r.u64(h + 32)
    let va = r.u64(h + 16)
    guard r.u32(h) == 1, r.u32(h + 4) == 5, page != 0, bytes != 0, bytes == r.u64(h + 40),
      start % page == 0, va % page == 0, bytes <= UInt64.max - va,
      imageContains(UInt64(file.count), start, bytes),
      DigestView(bytes: file, zeros: 0..<0, omit: 0..<0).cv(id.lowerBound, id.upperBound).matches(
        index.root)
    else { return nil }
    self.rva = va
    self.fileBytes = bytes
    self.pageSize = page
    self.fileStart = start
    self.index = index
  }

  /// File page to read into a private frame for this image-relative fault.
  /// Refuse non-code pages and any page intersecting canonicalized metadata.
  public func fileOffset(pageRVA: UInt64) -> UInt64? {
    guard pageRVA >= rva, pageRVA % pageSize == 0, pageRVA - rva < fileBytes else { return nil }
    let offset = fileStart + (pageRVA - rva)
    return index.covers(offset: offset, pageSize: pageSize) ? offset : nil
  }

  /// The frame is exclusive, unpublished and inaccessible to DMA. Verify
  /// the actual storage bytes before erasing any tail outside p_filesz.
  /// On false, discard the frame and terminate with CodeSignatureInvalid.
  public func prepare(
    pageRVA: UInt64, frame: UnsafeMutableBufferPointer<UInt8>,
    witnesses: UnsafeBufferPointer<UInt8>
  ) -> Bool {
    guard let offset = fileOffset(pageRVA: pageRVA),
      verifyFilePage(
        UnsafeBufferPointer(frame), witnesses, index.canonicalSize, offset, pageSize, index.root)
    else { return false }
    let valid = Int(min(pageSize, fileBytes - (pageRVA - rva)))
    for i in valid..<frame.count { frame[i] = 0 }
    return true
  }
}
