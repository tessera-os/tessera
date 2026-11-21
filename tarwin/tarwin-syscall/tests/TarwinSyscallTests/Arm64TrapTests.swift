import TarwinABI
import TarwinSyscall
import XCTest

private struct Recorder: CallProvider {
  var count: UInt32 = 2, entered = 0, copyOK = false
  func argumentCount(for number: UInt64) -> UInt32? { count }
  mutating func copyUserWords(from address: UInt64, into dst: UnsafeMutableBufferPointer<UInt64>)
    -> Bool
  {
    guard copyOK, address == 0x2000, dst.count == 2 else { return false }
    dst[0] = 80
    dst[1] = 81
    return true
  }
  mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    entered += 1
    return CallResult(status: 0, detail: number, first: words[0], second: words[words.count - 1])
  }
}
final class Arm64TrapTests: XCTestCase {
  func testOnlyFourResultRegistersAreEdited() {
    var p = Recorder()
    var regs = (0..<31).map { UInt64($0 + 10) }
    var scratch = [UInt64](repeating: 0, count: 9)
    regs[16] = TarwinCall.handleInfo
    let saved = regs
    func run(_ elr: UInt64 = 0x1004, _ esr: UInt64 = 0x5600_0000, _ spsr: UInt64 = 0)
      -> Arm64TrapOutcome
    {
      regs.withUnsafeMutableBufferPointer { r in
        scratch.withUnsafeMutableBufferPointer {
          dispatchArm64EL0(
            esr: esr, spsr: spsr, elr: elr, gprs: r, libraryCode: 0x1000..<0x1004,
            userRange: 0x2000..<0x2010, scratch: $0, provider: &p)
        }
      }
    }
    XCTAssertEqual(run(0x1000), .terminateBadOrigin)
    XCTAssertEqual(run(0x1000, 0x5600_0001), .terminateBadOrigin)
    XCTAssertEqual(run(0x1004, 0x5600_0001), .otherSynchronousException)
    XCTAssertEqual(run(0x1004, 0x9600_0000), .otherSynchronousException)
    XCTAssertEqual(run(0x1004, 0x5600_0000, 5), .otherSynchronousException)
    XCTAssertEqual(regs, saved)
    XCTAssertEqual(p.entered, 0)
    XCTAssertEqual(run(), .resumeEL0)
    XCTAssertEqual(Array(regs.prefix(4)), [0, TarwinCall.handleInfo, 10, 11])
    XCTAssertEqual(regs.dropFirst(4), saved.dropFirst(4))
    p.count = 9
    regs[7] = 0x2000
    XCTAssertEqual(run(), .resumeEL0)
    XCTAssertEqual(regs[0], 0x1_0000_0001)
    XCTAssertEqual(p.entered, 1)
    p.copyOK = true
    XCTAssertEqual(run(), .resumeEL0)
    XCTAssertEqual(regs[3], 81)
    XCTAssertEqual(p.entered, 2)
    regs.removeLast()
    XCTAssertEqual(run(), .invalidKernelFrame)
    XCTAssertEqual(p.entered, 2)
  }
}
