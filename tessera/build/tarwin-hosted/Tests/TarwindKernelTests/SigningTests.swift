import Foundation
import TarwinLoader
import TarwinLoaderHosted
import TarwindSigning
import XCTest

final class SigningTests: XCTestCase {
  func word<T: FixedWidthInteger>(_ data: Data, _ p: Int, _: T.Type) -> T {
    data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: T.self)) }
  }
  func testSignerAdmitsHostedIdentityBindsAppIDAndListsTwoSyscalls() throws {
    let fixture = try XCTUnwrap(Bundle.module.url(forResource: "w1-init", withExtension: "elf", subdirectory: "Fixtures"))
    let original = try Data(contentsOf: fixture)
    XCTAssertThrowsError(try TarwindAppTrust.admit(original))
    var image = original
    let ph = Int(word(image, 32, UInt64.self)), count = Int(word(image, 56, UInt16.self))
    let noteHeader = try XCTUnwrap(stride(from: ph, to: ph + count * 56, by: 56).first {
      word(image, $0, UInt32.self) == 4
    })
    let noteOffset = Int(word(image, noteHeader + 8, UInt64.self))
    let noteSize = Int(word(image, noteHeader + 32, UInt64.self))
    var notes = Data(image[noteOffset..<noteOffset + noteSize])
    for value: UInt32 in [8, 64, 6] {
      withUnsafeBytes(of: value.littleEndian) { notes.append(contentsOf: $0) }
    }
    notes += Data("Tessera\0".utf8) + Data(repeating: 0, count: 64)
    while !image.count.isMultiple(of: 8) { image.append(0) }
    let newNoteOffset = image.count
    image += notes
    for (p, value) in [(noteHeader + 8, UInt64(newNoteOffset)), (noteHeader + 32, UInt64(notes.count)), (noteHeader + 40, UInt64(notes.count))] {
      withUnsafeBytes(of: value.littleEndian) { image.replaceSubrange(p..<p + 8, with: $0) }
    }
    let sh = Int(word(image, 40, UInt64.self)), shCount = Int(word(image, 60, UInt16.self))
    for h in stride(from: sh, to: sh + shCount * 64, by: 64) where word(image, h + 4, UInt32.self) == 7 {
      for (p, value) in [(h + 24, UInt64(newNoteOffset)), (h + 32, UInt64(notes.count))] {
        withUnsafeBytes(of: value.littleEndian) { image.replaceSubrange(p..<p + 8, with: $0) }
      }
    }
    var sites: [UInt64] = []
    for h in stride(from: ph, to: ph + count * 56, by: 56)
      where word(image, h, UInt32.self) == 1 && word(image, h + 4, UInt32.self) & 1 != 0 {
      let offset = Int(word(image, h + 8, UInt64.self)), size = Int(word(image, h + 32, UInt64.self))
      let rva = word(image, h + 16, UInt64.self)
      for p in stride(from: offset, to: offset + size, by: 4) where word(image, p, UInt32.self) == 0xd400_0001 {
        withUnsafeBytes(of: UInt32(0xd503_201f).littleEndian) { image.replaceSubrange(p..<p + 4, with: $0) }
      }
      if sites.isEmpty {
        for p in [offset + size - 8, offset + size - 4] {
          withUnsafeBytes(of: UInt32(0xd400_0001).littleEndian) { image.replaceSubrange(p..<p + 4, with: $0) }
          sites.append(rva + UInt64(p - offset))
        }
      }
    }
    XCTAssertEqual(sites.count, 2)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("input.elf"), output = directory.appendingPathComponent("signed.elf")
    try image.write(to: input)
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("tarwin-hosted-sign")
    process.arguments = ["--app-id", "org.tessera.conformance.hosted-io-client", "--entitlement", "tessera.network.client", input.path, output.path]
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
    try process.run(); process.waitUntilExit()
    let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 0, log)
    let signed = try Data(contentsOf: output)
    let identity = try TarwindAppTrust.admit(signed)
    XCTAssertEqual(identity.appID, "org.tessera.conformance.hosted-io-client")
    XCTAssertEqual(identity.entitlements, ["tessera.network.client"])
    let admitted = try HostedVerifiedImage.admit(signed, requiresEntry: true) {
      _ = try TarwindAppTrust.authorize($0, layout: $1)
    }
    XCTAssertEqual(admitted.trapRVAs, sites)
    var tampered = signed
    tampered[0x4000] ^= 1
    XCTAssertThrowsError(try TarwindAppTrust.admit(tampered))
    XCTAssertThrowsError(try HostedVerifiedImage.admit(tampered, requiresEntry: true) {
      _ = try TarwindAppTrust.authorize($0, layout: $1)
    })
    XCTAssertThrowsError(try TarwindAppTrust.admit(Data()))
  }
}
