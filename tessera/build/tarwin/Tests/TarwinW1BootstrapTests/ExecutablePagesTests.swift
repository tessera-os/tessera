import Foundation
import KCore
import Tarboot
import TarwinArchAarch64
import TarwinLoader
import Testing

@testable import TarwinW1Bootstrap

private struct Bytes: ByteSource {
  let bytes: Data
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ offset: UInt64) -> UInt8 { bytes[Int(offset)] }
}

// Use the W0 diagnostic solely as page-integrity input, not a W1 member.
@Test func realFilePagesAreVerifiedAndPaddedBeforeCodeMapping() throws {
  let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  let path = "../../../../../tarwin/tarwin-loader/w0/Tests/TarwinW0Tests/SignedAArch64/BOOT.TIR"
  let archive = try Data(contentsOf: here.appendingPathComponent(path).standardizedFileURL)
  let member = findBootMember(Bytes(bytes: archive), name: Bytes(bytes: Data("kernel".utf8)))
  try #require(member.validArchive && member.found && member.compression == 0)
  let elf = archive.subdata(in: Int(member.offset)..<Int(member.offset + member.size))
  try elf.withUnsafeBytes { file in
    let image = try #require(
      inspectELF(
        file, target: ElfMachine.aarch64, addressLimit: 1 << 32,
        finalized: false, requiresEntry: true))
    let h = try #require(
      stride(
        from: image.programHeaders.lowerBound, to: image.programHeaders.upperBound,
        by: 56
      ).first {
        file.loadUnaligned(fromByteOffset: $0, as: UInt32.self) == 1
          && file.loadUnaligned(fromByteOffset: $0 + 4, as: UInt32.self) == 5
      })
    func u64(_ field: Int) -> UInt64 {
      UInt64(littleEndian: file.loadUnaligned(fromByteOffset: h + field, as: UInt64.self))
    }
    let code = u64(16)..<(u64(16) + u64(32))
    let fileOffset = Int(u64(8))
    let bias: UInt64 = 1 << 32
    let page = bias + code.lowerBound
    let valid = min(code.count, 16384)
    let zero = BlakeCv(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0)
    let count = try #require(NativePageIndex.capacity(fileBytes: file.count))
    let nodes = UnsafeMutableBufferPointer<BlakeCv>.allocate(capacity: count)
    nodes.initialize(repeating: zero)
    let witnesses = UnsafeMutableRawBufferPointer.allocate(byteCount: 16 * 54 * 32, alignment: 16)
    let frame = UnsafeMutableRawBufferPointer.allocate(byteCount: 16384, alignment: 16)
    let arena = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 * 16384, alignment: 16)
    defer {
      nodes.deallocate()
      frame.deallocate()
      arena.deallocate()
      witnesses.deallocate()
    }
    let rx = try #require(
      W1ExecutablePages(file: file, image: image, bias: bias, expected: code, nodes: nodes))
    guard var t = ArmUserTranslation(backing: arena, physical: 0x80000) else {
      Issue.record("no tables")
      return
    }
    let original = Array(arena)
    var canClean = false
    var calls = 0
    func install(_ va: UInt64) -> Bool {
      rx.install(
        page: va, physical: 0x40000, frame: frame, nodes: .init(nodes),
        witnesses: witnesses, tables: &t,
        cleanToPoU: { stored in
          calls += 1
          return canClean
            && stored.prefix(valid).elementsEqual(file[fileOffset..<fileOffset + valid])
            && stored.dropFirst(valid).allSatisfy { $0 == 0 }
        })
    }
    #expect(rx.code == page..<page + UInt64(code.count))
    #expect(!install(page - 16384) && !install(page + 4) && calls == 0)
    let sibling = (fileOffset / 1024) ^ 1
    let saved = nodes[sibling]
    nodes[sibling] = zero
    #expect(!install(page) && calls == 0 && Array(arena) == original)
    nodes[sibling] = saved
    #expect(!install(page) && calls == 1 && Array(arena) == original)
    canClean = true
    #expect(install(page) && calls == 2 && Array(arena) != original)
    let words = arena.bindMemory(to: UInt64.self)
    let leaf = words[3 * 2048 + Int(armWalkIndex(page, level: 3))]
    #expect(leaf == armUserPage(0x40000, write: false, execute: true, lpa2: false) | (1 << 50))
  }
}
