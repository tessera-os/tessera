import CryptoKit
import Foundation
import XCTest

@testable import TarwinLoader

final class FrozenSDKTests: XCTestCase {
  private func withContract<R>(_ body: (EarlyRIDLContract) throws -> R) rethrows -> R {
    let uuid = UUID(uuidString: "6F1B36CB-CA46-4ED8-9885-486FCCF2A255")!
    let symbol = Data("_RIDL110LibTessera14processCurrentF_v6f1b36cbca464ed8".utf8)
    let text = "struct Handle { let raw : U64 } function processCurrent ( ) -> Handle"
    return try withUnsafeBytes(of: uuid.uuid) { id in
      try symbol.withUnsafeBytes { name in
        try SHA256.hash(data: Data(text.utf8)).withUnsafeBytes { digest in
          try body(
            EarlyRIDLContract(uuid: id, symbol: name, textSHA256: digest, typeTag: 0x8b65_40d3))
        }
      }
    }
  }

  func testFirstCallNeedsEveryFrozenField() {
    withContract { c in
      XCTAssertTrue(c.isW1ProcessCurrent)
      func check(
        _ id: UnsafeRawBufferPointer, _ name: UnsafeRawBufferPointer,
        _ digest: UnsafeRawBufferPointer, _ tag: UInt32
      ) {
        XCTAssertFalse(
          EarlyRIDLContract(
            uuid: id, symbol: name, textSHA256: digest,
            typeTag: tag
          ).isW1ProcessCurrent)
      }
      check(.init(rebasing: c.uuid.dropLast()), c.symbol, c.textSHA256, c.typeTag)
      check(c.uuid, .init(rebasing: c.symbol.dropFirst()), c.textSHA256, c.typeTag)
      check(c.uuid, c.symbol, .init(rebasing: c.textSHA256.dropLast()), c.typeTag)
      check(c.uuid, c.symbol, c.textSHA256, c.typeTag ^ 1)
      for i in 0..<48 {
        var id = Data(c.uuid)
        var digest = Data(c.textSHA256)
        if i < 16 { id[i] ^= 1 } else { digest[i - 16] ^= 1 }
        id.withUnsafeBytes { u in digest.withUnsafeBytes { check(u, c.symbol, $0, c.typeTag) } }
      }
    }
  }

  // Optional producer cross-check only; do not sign, enroll or execute these files.
  func testUnsignedPairFromWriter() throws {
    let env = ProcessInfo.processInfo.environment
    if env["W1_INTEROP_CALLER"] == nil && env["W1_INTEROP_FRAMEWORK"] == nil {
      throw XCTSkip("set W1_INTEROP_CALLER and W1_INTEROP_FRAMEWORK to unsigned writer outputs")
    }
    let caller = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["W1_INTEROP_CALLER"])))
    let library = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["W1_INTEROP_FRAMEWORK"])))
    var stack = [BlakeCv](
      repeating: .init(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
    try withContract { c in
      try caller.withUnsafeBytes { p in
        try library.withUnsafeBytes { l in
          try stack.withUnsafeMutableBufferPointer { scratch in
            let arm = ElfMachine.aarch64
            let (exe, directory, section, _) = try XCTUnwrap(
              parsedUnsignedArtifact(
                p,
                machine: arm, addressLimit: 1 << 32, finalized: false, requiresEntry: true,
                scratch: scratch))
            let (lib, _, _, _) = try XCTUnwrap(
              parsedUnsignedArtifact(
                l,
                machine: arm, addressLimit: 1 << 32, finalized: false, requiresEntry: false,
                scratch: scratch))
            var hint: Int?
            XCTAssertTrue(
              ELFReader(bytes: p).validLocalEntry(
                exe.entry, tag: 0x4d3e_7643,
                machine: arm, programs: exe.programHeaders, hint: &hint))
            let binding = try XCTUnwrap(
              checkedRIDLBinding(
                executable: p, framework: l, caller: exe,
                dir: directory, section: section, lib: lib, machine: arm, contract: c))
            XCTAssertEqual(binding.typeTag, c.typeTag)
            XCTAssertNil(
              inspectEarlyRIDLBinding(
                executable: p, framework: l, machine: arm,
                addressLimit: 1 << 32, scratch: scratch, contract: c), "missing both TSG1 envelopes"
            )
          }
        }
      }
    }
  }
}
