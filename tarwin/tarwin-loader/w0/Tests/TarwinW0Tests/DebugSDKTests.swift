import Foundation
import TarwinLoader
import TarwinW0Verify
import XCTest

final class DebugSDKTests: XCTestCase {
  /// Host regression, not a CPU feature probe, trusted clock or guest launch.
  func testSignedIntakeArchive() throws {
    let env = ProcessInfo.processInfo.environment
    guard let dir = env["TARWIN_DEBUG_W1_SET"], let keys = env["TARWIN_DEBUG_SDK_DIR"],
      let isa = env["TARWIN_DEBUG_W1_ISA"] else { throw XCTSkip("no external debug boot set") }
    let machine = try XCTUnwrap(["aarch64": ElfMachine.aarch64, "rv64": ElfMachine.rv64,
      "x64": ElfMachine.x64][isa])
    func read(_ root: String, _ name: String) throws -> Data {
      try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name))
    }
    let archive = try read(dir, "TARWIN.TIR"), sig = try read(dir, "TARWIN.SIG")
    let boot = try read(keys, "boot.tqe1"), system = try read(keys, "system.tqe1")
    let sdk = try read(keys, "LibTessera.ridlmeta"), receipt = try read(keys, isa + ".receipt")
    let now = UInt64(Date().timeIntervalSince1970)
    var stack = [BlakeCv](repeating: .init(w0: 0,w1: 0,w2: 0,w3: 0,w4: 0,w5: 0,w6: 0,w7: 0), count: 54)
    var work = [Int32](repeating: 0, count: 2048), msg = [UInt8](repeating: 0, count: 1024)
    func check(_ a: Data, _ signature: Data, _ bootKey: Data, _ sysKey: Data,
      debug: Bool = true, cpu: Bool = true, floor: UInt64? = 1, utc: UInt64? = now
    ) -> Bool {
      let policy = W0Policy(machine: machine, baselineSupported: cpu, trustedUTC: utc,
        train: (26,11,1), tir: (26,11,2), addressLimit: 1 << 32, securityFloor: floor, slot: 0,
        debugEmulator: debug)
      return a.withUnsafeBytes { ar in signature.withUnsafeBytes { sig in
        bootKey.withUnsafeBytes { b in sysKey.withUnsafeBytes { s in
          sdk.withUnsafeBytes { k in receipt.withUnsafeBytes { r in
            stack.withUnsafeMutableBufferPointer { h in work.withUnsafeMutableBufferPointer { w in
              msg.withUnsafeMutableBytes { m in
                withProvisionedDebugW1SDK(k, receipt: r, systemEnrollment: s, policy: policy,
                  hashes: h, polynomials: w, message: m) { c in
                    guard let set = authorizeQEMUStage1(archive: ar, signature: sig, enrollment: b,
                      systemEnrollment: s, policy: policy, contract: c, hashes: h, polynomials: w,
                      message: m), set.machine == machine, set.binding.typeTag == c.typeTag,
                      let plan = set.addressPlan(for: machine, occupied: .init(start: nil, count: 0),
                        nextRandom: { UInt64.max }) else { return false }
                    return !plan.processReservation.overlaps(plan.libraryReservation)
                      && plan.sealReadOnly.contains(plan.slotAddress)
                      && plan.libraryCode.contains(plan.targetAddress)
                  } == true
              }
            } }
          } }
        } }
      } }
    }
    XCTAssertTrue(check(archive, sig, boot, system))
    XCTAssertFalse(check(archive, sig, boot, system, debug: false))
    XCTAssertFalse(check(archive, sig, boot, system, cpu: false))
    XCTAssertFalse(check(archive, sig, boot, system, floor: 2))
    XCTAssertFalse(check(archive, sig, boot, system, utc: nil))
    XCTAssertFalse(check(archive, sig, system, boot))
    XCTAssertFalse(check(archive, sig, system, system))
    var altered = archive
    altered[altered.count - 1] ^= 1
    XCTAssertFalse(check(altered, sig, boot, system))
    var damaged = sig
    damaged[damaged.count - 1] ^= 1
    XCTAssertFalse(check(archive, damaged, boot, system))
  }

  func testProvisionedReleaseAndPolicyRefusals() throws {
    guard let dir = ProcessInfo.processInfo.environment["TARWIN_DEBUG_SDK_DIR"] else {
      throw XCTSkip("run with freshly issued public debug receipts")
    }
    func read(_ name: String) throws -> Data {
      try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
    let enrolled = try read("system.tqe1"), wrong = try read("boot.tqe1")
    let meta = try read("LibTessera.ridlmeta")
    let now = UInt64(Date().timeIntervalSince1970)
    var stack = [BlakeCv](repeating: .init(w0: 0,w1: 0,w2: 0,w3: 0,w4: 0,w5: 0,w6: 0,w7: 0), count: 54)
    var work = [Int32](repeating: 0, count: 2048), msg = [UInt8](repeating: 0, count: 1024)
    for (name, isa) in [("aarch64", ElfMachine.aarch64), ("x64", ElfMachine.x64), ("rv64", ElfMachine.rv64)] {
      let receipt = try read(name + ".receipt")
      func accepts(_ m: Data, _ s: Data, _ pin: Data, machine: UInt16 = isa, utc: UInt64? = now,
        debug: Bool = true) -> Bool {
        let policy = W0Policy(machine: machine, baselineSupported: false, trustedUTC: utc,
          train: (26,11,1), tir: (26,11,2), addressLimit: 1 << 32, securityFloor: nil, slot: 0,
          debugEmulator: debug)
        return m.withUnsafeBytes { b in s.withUnsafeBytes { sig in pin.withUnsafeBytes { k in
          stack.withUnsafeMutableBufferPointer { h in work.withUnsafeMutableBufferPointer { w in
            msg.withUnsafeMutableBytes { out in
              withProvisionedDebugW1SDK(b, receipt: sig, systemEnrollment: k, policy: policy,
                hashes: h, polynomials: w, message: out) { $0.isW1ProcessCurrent } == true
            }
          } }
        } } }
      }
      XCTAssertTrue(accepts(meta, receipt, enrolled))
      XCTAssertFalse(accepts(meta, receipt, enrolled, debug: false))
      XCTAssertFalse(accepts(meta, receipt, enrolled, utc: nil))
      XCTAssertFalse(accepts(meta, receipt, enrolled, utc: 0))
      XCTAssertFalse(accepts(meta, receipt, wrong))
      XCTAssertFalse(accepts(meta, receipt, enrolled, machine: isa == ElfMachine.x64 ? ElfMachine.rv64 : ElfMachine.x64))
      var altered = meta
      altered[47] ^= 1
      XCTAssertFalse(accepts(altered, receipt, enrolled))
      var damaged = receipt
      damaged[damaged.count - 1] ^= 1
      XCTAssertFalse(accepts(meta, damaged, enrolled))
    }
  }
}
