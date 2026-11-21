public enum ElfMachine {
  public static let aarch64: UInt16 = 183
  public static let x64: UInt16 = 62
  public static let rv64: UInt16 = 243
}

public func imagePage(_ machine: UInt16) -> UInt64 {
  if machine == ElfMachine.aarch64 { return 16384 }
  if machine == ElfMachine.x64 || machine == ElfMachine.rv64 { return 4096 }
  return 0
}

public func imageContains(_ size: UInt64, _ offset: UInt64, _ length: UInt64) -> Bool {
  return offset <= size && length <= size - offset
}

// The ELF reader supplies little-endian fields, not host-native pointers.
// No segment is mapped until the entire image, records and signature pass.
public struct ImageHeader {
  public let magic: UInt32
  public let wordClass: UInt8
  public let encoding: UInt8
  public let identVersion: UInt8
  public let version: UInt32
  public let kind: UInt16
  public let machine: UInt16
  public let headerBytes: UInt16
  public let programOffset: UInt64
  public let entryBytes: UInt16
  public let count: UInt16

  public func accepts(_ target: UInt16, _ bytes: UInt64) -> Bool {
    if magic != 0x464c_457f || wordClass != 2 || encoding != 1 { return false }
    if identVersion != 1 || version != 1 || kind != 3 { return false }
    if machine != target || imagePage(machine) == 0 { return false }
    if headerBytes != 64 || entryBytes != 56 || count == 0 { return false }
    if programOffset < UInt64(headerBytes) || (programOffset & 7) != 0 { return false }
    return imageContains(bytes, programOffset, UInt64(count) * UInt64(entryBytes))
  }

  public init(
    magic: UInt32, wordClass: UInt8, encoding: UInt8, identVersion: UInt8, version: UInt32,
    kind: UInt16, machine: UInt16, headerBytes: UInt16, programOffset: UInt64, entryBytes: UInt16,
    count: UInt16
  ) {
    self.magic = magic
    self.wordClass = wordClass
    self.encoding = encoding
    self.identVersion = identVersion
    self.version = version
    self.kind = kind
    self.machine = machine
    self.headerBytes = headerBytes
    self.programOffset = programOffset
    self.entryBytes = entryBytes
    self.count = count
  }
}

public struct LoadSegment {
  public let fileOffset: UInt64
  public let fileBytes: UInt64
  public let virtualAddress: UInt64
  public let memoryBytes: UInt64
  public let alignment: UInt64
  public let flags: UInt32

  public func valid(_ machine: UInt16, _ fileSize: UInt64, _ addressLimit: UInt64) -> Bool {
    let page = imagePage(machine)
    if page == 0 || alignment < page || (alignment & (alignment - 1)) != 0 { return false }
    if fileOffset % page != 0 || virtualAddress % page != 0 { return false }
    if (virtualAddress % alignment) != (fileOffset % alignment) { return false }
    if (flags & 3) == 3 || fileBytes > memoryBytes { return false }
    return imageContains(fileSize, fileOffset, fileBytes)
      && imageContains(addressLimit, virtualAddress, memoryBytes)
  }

  public init(
    fileOffset: UInt64, fileBytes: UInt64, virtualAddress: UInt64, memoryBytes: UInt64,
    alignment: UInt64, flags: UInt32
  ) {
    self.fileOffset = fileOffset
    self.fileBytes = fileBytes
    self.virtualAddress = virtualAddress
    self.memoryBytes = memoryBytes
    self.alignment = alignment
    self.flags = flags
  }
}

// Validate PT_LOAD in program-header order (ELF requires ascending virtual
// addresses). Never allow distinct segments to share a protection page.
public struct LoadOrder {
  public internal(set) var afterLastPage: UInt64
  public internal(set) var seen: Bool

  public mutating func append(
    _ segment: LoadSegment, _ machine: UInt16, _ fileSize: UInt64,
    _ addressLimit: UInt64
  ) -> Bool {
    if !segment.valid(machine, fileSize, addressLimit) { return false }
    if segment.memoryBytes == 0 { return true }
    if seen && segment.virtualAddress < afterLastPage { return false }
    let end = segment.virtualAddress + segment.memoryBytes
    let page = imagePage(machine)
    let pad = (page - end % page) % page
    if pad > addressLimit - end { return false }
    afterLastPage = end + pad
    seen = true
    return true
  }

  public init(afterLastPage: UInt64, seen: Bool) {
    self.afterLastPage = afterLastPage
    self.seen = seen
  }
}

public func forbiddenProgramHeader(_ kind: UInt32) -> Bool {
  // PT_DYNAMIC and PT_INTERP.
  return kind == 2 || kind == 3
}
