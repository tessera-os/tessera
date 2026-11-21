import TarwinABI
import TarwinArchAarch64
import TarwinSyscall

private struct EmptyProvider: CallProvider {
  func argumentCount(for number: UInt64) -> UInt32? { nil }
  mutating func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    false
  }
  mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    CallResult(status: syscallStatus(90, 1))
  }
}

@_cdecl("tarwin_test_dispatch_slice")
public func dispatchSlice(_ frame: UnsafeMutableRawPointer, _ end: UInt64) -> UInt32 {
  // Test instruction origins, not an enrolled library. No live service.
  let code: Range<UInt64> = 0x1_0001_0000..<end
  var provider = EmptyProvider()
  return w1ArmVectorAction(
    dispatchPrivateW1Trap(
      frame: .init(start: frame, count: ArmTrapLayout.size), libraryCode: code,
      userRange: 1 << 32..<1 << 47, scratch: .init(start: nil, count: 0), provider: &provider))
}
