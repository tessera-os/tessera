import TarwinLoader

func hostedTrapRVAs(
  file: UnsafeRawBufferPointer, layout: InspectedImage, segments: [HostedSegment]
) throws -> [UInt64] {
  func word<T: FixedWidthInteger>(_ at: Int, _: T.Type) -> T {
    T(littleEndian: file.loadUnaligned(fromByteOffset: at, as: T.self))
  }
  func extent(offset: UInt64, size: UInt64) -> Range<Int>? {
    guard imageContains(UInt64(file.count), offset, size) else { return nil }
    return Int(offset)..<Int(offset + size)
  }

  let offset = word(40, UInt64.self)
  if offset == 0 { return [] }
  let count = Int(word(60, UInt16.self))
  let stringIndex = Int(word(62, UInt16.self))
  guard let headers = extent(offset: offset, size: UInt64(count) * 64),
    stringIndex > 0, stringIndex < count else { throw HostedImageError.invalidImage }
  let stringHeader = headers.lowerBound + stringIndex * 64
  guard let names = extent(
    offset: word(stringHeader + 24, UInt64.self), size: word(stringHeader + 32, UInt64.self))
  else { throw HostedImageError.invalidImage }
  let sectionName = Array(".tirtrap".utf8) + [0]
  var table: Range<Int>?
  for header in stride(from: headers.lowerBound + 64, to: headers.upperBound, by: 64) {
    let nameOffset = Int(word(header, UInt32.self))
    guard nameOffset < names.count else { throw HostedImageError.invalidImage }
    guard sectionName.count <= names.count - nameOffset else { continue }
    let name = names.lowerBound + nameOffset
    guard file[name..<(name + sectionName.count)].elementsEqual(sectionName) else { continue }
    let flags = word(header + 8, UInt64.self)
    guard table == nil, word(header + 4, UInt32.self) == 1, flags == 0 || flags == 2,
      let found = extent(offset: word(header + 24, UInt64.self), size: word(header + 32, UInt64.self)),
      found.lowerBound >= 64, found.count >= 4, !found.overlaps(headers), !found.overlaps(names),
      !found.overlaps(layout.programHeaders), layout.loaderRecords?.overlaps(found) != true
    else { throw HostedImageError.invalidImage }
    table = found
  }
  guard let table else { return [] }
  for header in stride(
    from: layout.programHeaders.lowerBound, to: layout.programHeaders.upperBound, by: 56
  ) {
    let type = word(header, UInt32.self)
    let flags = word(header + 4, UInt32.self)
    if type == 4 || (type == 1 && flags != 4) {
      guard let mapped = extent(
        offset: word(header + 8, UInt64.self), size: word(header + 32, UInt64.self)),
        !mapped.overlaps(table) else { throw HostedImageError.invalidImage }
    }
  }

  let first = table.lowerBound + 4
  let entries = Int(word(table.lowerBound, UInt32.self))
  guard table.upperBound - first == entries * 8 else { throw HostedImageError.invalidImage }
  let executable = segments.filter { $0.protection.contains(.execute) }
  var segmentIndex = 0
  var previous: UInt64?
  var syscallSites: [UInt64] = []
  for record in stride(from: first, to: table.upperBound, by: 8) {
    let rva = UInt64(word(record, UInt32.self))
    let code = UInt32(word(record + 4, UInt16.self))
    guard word(record + 6, UInt16.self) == 0, rva % 4 == 0,
      previous.map({ $0 < rva }) ?? true else { throw HostedImageError.invalidImage }
    while segmentIndex < executable.count,
      rva >= executable[segmentIndex].rva + UInt64(executable[segmentIndex].bytes.count)
    {
      segmentIndex += 1
    }
    guard segmentIndex < executable.count else { throw HostedImageError.invalidImage }
    let segment = executable[segmentIndex]
    guard rva >= segment.rva, imageContains(UInt64(segment.bytes.count), rva - segment.rva, 4)
    else { throw HostedImageError.invalidImage }
    let instruction = segment.bytes.withUnsafeBytes {
      UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: Int(rva - segment.rva), as: UInt32.self))
    }
    if instruction == 0xd400_0001 {
      syscallSites.append(rva)
    } else if instruction != 0xd420_0000 | (code << 5) {
      throw HostedImageError.invalidImage
    }
    previous = rva
  }
  return syscallSites
}
