import TarwinSyscall
import Testing

@testable import TarwinTrace

func programHardware(_ target: UInt64) -> UInt64 { return target + 1 }
func counterValue(_ token: UInt64) -> UInt64 { return 12 }
func resultValue(_ value: UInt64?) -> UInt64 {
  return switch value {
  case .some(let x): x
  case .none: 0xffff_ffff_ffff_ffff
  }
}
@Test
func counterReadDoesNotDoubleCountAndOwnersCannotCrossTargets() {
  #expect(!counterAccess(.thread, 9, 8, true))
  guard var session = createCounters(TarwinCall.performanceSessionCreate, .process, 99, 7, 7, false)
  else {
    Issue.record("counter creation failed")
    return
  }
  #expect(
    resultValue(
      useCounters(
        TarwinCall.performanceSessionStart, &session, programHardware, counterValue, counterValue))
      == 0)
  #expect(
    resultValue(
      useCounters(
        TarwinCall.performanceSessionRead, &session, programHardware, counterValue, counterValue))
      == 12)
  #expect(
    resultValue(
      useCounters(
        TarwinCall.performanceSessionStop, &session, programHardware, counterValue, counterValue))
      == 0)
  #expect(
    resultValue(
      useCounters(
        TarwinCall.performanceSessionRead, &session, programHardware, counterValue, counterValue))
      == 12)
}
