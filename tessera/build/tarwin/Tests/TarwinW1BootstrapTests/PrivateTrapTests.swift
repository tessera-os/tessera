import TarwinABI
import TarwinArchAarch64
import TarwinSyscall
import TarwinW1Bootstrap
import Testing

private struct ProbeCalls: CallProvider {
  func argumentCount(for number: UInt64) -> UInt32? { 0 }
  mutating func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    false
  }
  mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    CallResult(status: 1, detail: 2, first: 3, second: 4)
  }
}

@Test func trapBridgeDoesNotRewriteAnySavedControlOrFloatingPointState() {
  let frame = UnsafeMutableRawBufferPointer.allocate(byteCount: ArmTrapLayout.size, alignment: 16)
  defer { frame.deallocate() }
  let rx: UInt64 = 1 << 32
  let bank = frame.bindMemory(to: UInt64.self)
  for i in bank.indices { bank[i] = UInt64(i + 1) }
  bank[16] = TarwinCall.handleInfo
  bank[ArmTrapLayout.esr / 8] = 0x5600_0000
  bank[ArmTrapLayout.spsr / 8] = 0
  var calls = ProbeCalls()
  func dispatch(_ f: UnsafeMutableRawBufferPointer) -> Arm64TrapOutcome {
    dispatchPrivateW1Trap(
      frame: f, libraryCode: rx..<rx + 12, userRange: (1 << 43)..<(1 << 46),
      scratch: .init(start: nil, count: 0), provider: &calls)
  }
  bank[ArmTrapLayout.elr / 8] = rx + 16
  let rejected = Array(bank)
  #expect(dispatch(frame) == .terminateBadOrigin && Array(bank) == rejected)
  #expect(dispatch(.init(rebasing: frame.dropFirst(8))) == .invalidKernelFrame)
  bank[ArmTrapLayout.elr / 8] = rx + 12
  let untouched = Array(bank.dropFirst(4))
  #expect(dispatch(frame) == .resumeEL0)
  #expect(Array(bank.prefix(4)) == [1, 2, 3, 4] && Array(bank.dropFirst(4)) == untouched)
}
