import Foundation
import TarwinLoader

/// Bounded ELF editing for the development signer; never grants execution authority.
public struct TarwindSigningImage {
  public private(set) var file: Data
  private let programs: Range<Int>
  private var sections: [Data]
  private let stringIndex: Int
  private var names: Data

  public init(_ file: Data) throws {
    guard file.count >= 64, file.count <= 64 * 1024 * 1024,
      file.prefix(7) == Data([0x7f, 69, 76, 70, 2, 1, 1]) else { throw TarwindSigningError.malformedImage }
    self.file = file
    func word<T: FixedWidthInteger>(_ p: Int, _: T.Type) -> T {
      file.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: T.self)) }
    }
    func span(_ offset: UInt64, _ size: UInt64) throws -> Range<Int> {
      guard offset <= file.count, size <= UInt64(file.count) - offset else { throw TarwindSigningError.malformedImage }
      return Int(offset)..<Int(offset + size)
    }
    guard word(16, UInt16.self) == 3, word(18, UInt16.self) == 183,
      word(54, UInt16.self) == 56, word(58, UInt16.self) == 64 else { throw TarwindSigningError.malformedImage }
    programs = try span(word(32, UInt64.self), UInt64(word(56, UInt16.self)) * 56)
    let table = try span(word(40, UInt64.self), UInt64(word(60, UInt16.self)) * 64)
    stringIndex = Int(word(62, UInt16.self))
    guard !programs.isEmpty, table.count > 64, table.count <= 65536,
      stringIndex > 0, stringIndex < table.count / 64 else { throw TarwindSigningError.malformedImage }
    sections = stride(from: table.lowerBound, to: table.upperBound, by: 64).map { Data(file[$0..<$0 + 64]) }
    let h = table.lowerBound + stringIndex * 64
    names = Data(file[try span(word(h + 24, UInt64.self), word(h + 32, UInt64.self))])
  }

  private func word<T: FixedWidthInteger>(_ p: Int, _: T.Type) -> T {
    file.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: T.self)) }
  }
  private func span(_ offset: UInt64, _ size: UInt64) throws -> Range<Int> {
    guard offset <= file.count, size <= UInt64(file.count) - offset else { throw TarwindSigningError.malformedImage }
    return Int(offset)..<Int(offset + size)
  }
  private func sectionWord<T: FixedWidthInteger>(_ index: Int, _ p: Int, _: T.Type) -> T {
    sections[index].withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: T.self)) }
  }
  private func section(_ name: String) throws -> Int? {
    let wanted = Data(name.utf8) + Data([0])
    var found: Int?
    for i in sections.indices.dropFirst() {
      let start = Int(sectionWord(i, 0, UInt32.self))
      guard start < names.count else { throw TarwindSigningError.malformedImage }
      if wanted.count <= names.count - start, names[start..<start + wanted.count] == wanted {
        guard found == nil else { throw TarwindSigningError.malformedImage }
        found = i
      }
    }
    return found
  }

  public func executableWords() throws -> [(rva: UInt32, instruction: UInt32)] {
    var result: [(UInt32, UInt32)] = []
    for p in stride(from: programs.lowerBound, to: programs.upperBound, by: 56)
      where word(p, UInt32.self) == 1 && word(p + 4, UInt32.self) & 1 != 0 {
      let bytes = try span(word(p + 8, UInt64.self), word(p + 32, UInt64.self))
      let base = word(p + 16, UInt64.self)
      guard base & 3 == 0, bytes.count % 4 == 0, base <= UInt32.max,
        UInt64(bytes.count) <= UInt64(UInt32.max) - base else { throw TarwindSigningError.malformedImage }
      for offset in stride(from: 0, to: bytes.count, by: 4) {
        result.append((UInt32(base) + UInt32(offset), word(bytes.lowerBound + offset, UInt32.self)))
      }
    }
    return result
  }

  public mutating func mergeSyscallSites(_ sites: [UInt32]) throws {
    var records: [UInt32: UInt16] = [:]
    let index: Int
    if let existing = try section(".tirtrap") {
      index = existing
      let bytes = try span(sectionWord(index, 24, UInt64.self), sectionWord(index, 32, UInt64.self))
      guard bytes.count >= 4, UInt64(word(bytes.lowerBound, UInt32.self)) * 8 + 4 == bytes.count else {
        throw TarwindSigningError.malformedImage
      }
      for p in stride(from: bytes.lowerBound + 4, to: bytes.upperBound, by: 8) {
        let rva = word(p, UInt32.self)
        guard records[rva] == nil, word(p + 6, UInt16.self) == 0 else { throw TarwindSigningError.malformedImage }
        records[rva] = word(p + 4, UInt16.self)
      }
    } else {
      index = sections.count
      var header = Data(count: 64)
      header.put(UInt32(names.count), at: 0); header.put(UInt32(1), at: 4)
      names += Data(".tirtrap\0".utf8)
      sections.append(header)
    }
    for site in sites where records[site] == nil { records[site] = 0 }
    var table = little(UInt32(records.count))
    for site in records.keys.sorted() { table += little(site) + little(records[site]!) + little(UInt16(0)) }
    appendSection(index, bytes: table)
  }

  private mutating func appendSection(_ index: Int, bytes: Data) {
    while !file.count.isMultiple(of: 8) { file.append(0) }
    sections[index].put(UInt64(0), at: 8)
    sections[index].put(UInt64(file.count), at: 24)
    sections[index].put(UInt64(bytes.count), at: 32)
    file += bytes
  }

  public mutating func prepare(appID: String, entitlements: [String]) throws -> (message: Data, signatures: Range<Int>) {
    guard validIdentifier(appID), entitlements.allSatisfy(validIdentifier) else { throw TarwindSigningError.invalidArguments }
    let keys = try DebugKeys.load()
    let chain = try canonicalJSON(["identity": keys.identity, "scope": "debug-app", "appID": appID])
    let envelope = Data("TSG1".utf8) + little(UInt32(chain.count)) + chain + Data(count: 3373)
    let notes = stride(from: programs.lowerBound, to: programs.upperBound, by: 56)
      .filter { word($0, UInt32.self) == 4 }
    guard notes.count == 1, let noteSection = sections.indices.first(where: { sectionWord($0, 4, UInt32.self) == 7 })
    else { throw TarwindSigningError.invalidELF("expected one note segment and section") }
    let p = notes[0]
    let old = try span(word(p + 8, UInt64.self), word(p + 32, UInt64.self))
    var descriptors: [UInt32: Data] = [:]
    var cursor = old.lowerBound
    while cursor < old.upperBound {
      guard old.upperBound - cursor >= 20, word(cursor, UInt32.self) == 8,
        file[cursor + 12..<cursor + 20] == Data("Tessera\0".utf8) else { throw TarwindSigningError.malformedImage }
      let size = Int(word(cursor + 4, UInt32.self)), kind = word(cursor + 8, UInt32.self)
      let rounded = (size + 3) & ~3
      guard rounded <= old.upperBound - cursor - 20, descriptors[kind] == nil else { throw TarwindSigningError.malformedImage }
      descriptors[kind] = Data(file[cursor + 20..<cursor + 20 + size]); cursor += 20 + rounded
    }
    guard descriptors[7] == Data([0, 0]) else { throw TarwindSigningError.profile }
    descriptors[2] = envelope
    guard descriptors[6]?.count == 64 else {
      throw TarwindSigningError.invalidELF("input must already be compiler-finalized (note 6)")
    }
    descriptors[3] = try canonicalJSON(Array(Set(entitlements)).sorted())
    var stream = Data()
    for kind in descriptors.keys.sorted() {
      let value = descriptors[kind]!
      stream += little(UInt32(8)) + little(UInt32(value.count)) + little(kind) + Data("Tessera\0".utf8) + value
      while !stream.count.isMultiple(of: 4) { stream.append(0) }
    }
    appendSection(noteSection, bytes: stream)
    file.put(sectionWord(noteSection, 24, UInt64.self), at: p + 8)
    file.put(UInt64(stream.count), at: p + 32); file.put(UInt64(stream.count), at: p + 40)
    appendSection(stringIndex, bytes: names)
    while !file.count.isMultiple(of: 8) { file.append(0) }
    file.put(UInt64(file.count), at: 40); file.put(UInt16(sections.count), at: 60)
    for header in sections { file += header }
    var hashes = hashWorkspace()
    guard let layout = file.withUnsafeBytes({ inspectELF($0, target: ElfMachine.aarch64,
      addressLimit: 64 << 30, finalized: true, requiresEntry: true, requiresLoaderRecords: true) }),
      let id = layout.notes.buildID, let signatureRange = layout.notes.signature else {
        throw TarwindSigningError.invalidELF("signed structural layout")
      }
    guard let digest = file.withUnsafeBytes({ bytes in hashes.withUnsafeMutableBufferPointer {
        nativeSigningID(bytes, image: layout, scratch: $0)
      } }) else { throw TarwindSigningError.invalidELF("signing ID") }
    var idBytes = Data()
    for w in [digest.w0, digest.w1, digest.w2, digest.w3, digest.w4, digest.w5, digest.w6, digest.w7] { idBytes += little(w) }
    file.replaceSubrange(id, with: idBytes)
    var message = Data(count: 65536)
    guard let size = file.withUnsafeBytes({ bytes in message.withUnsafeMutableBytes {
      nativeSigningMessage(bytes, notes: layout.notes, into: $0)
    } }) else { throw TarwindSigningError.malformedImage }
    return (Data(message.prefix(size)), signatureRange.upperBound - 3373..<signatureRange.upperBound)
  }

  public mutating func installSignatures(_ bytes: Data, at range: Range<Int>) throws {
    guard bytes.count == 3373, range.count == 3373, range.lowerBound >= 0, range.upperBound <= file.count else {
      throw TarwindSigningError.signature
    }
    file.replaceSubrange(range, with: bytes)
    _ = try TarwindAppTrust.admit(file)
  }
}

private func little<T: FixedWidthInteger>(_ value: T) -> Data {
  withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private extension Data {
  mutating func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
    replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: little(value))
  }
}
