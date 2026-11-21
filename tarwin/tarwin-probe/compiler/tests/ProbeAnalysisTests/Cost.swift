import TarwinProbe
import Testing

@testable import ProbeAnalysis

func cost(_ terms: [ProbeTerm], _ hook: ProbeHook) -> UInt64 {
  switch worstCase(terms, 64, hook) {
  case .success(let n): return n
  case .failure(let e): return ProbeLimit.invalid
  }
}

@Test
func costIncludesControlFlowAndChecksEvenColdArms() {
  #expect(
    cost([.definedScalar, .counted(Bound(body: 0, bound: 499999)), .directCall(1)], .tracepoint)
      == 1_000_000)
  #expect(
    cost([.definedScalar, .counted(Bound(body: 0, bound: 500000))], .tracepoint)
      == ProbeLimit.invalid)
  #expect(
    cost([.definedScalar, .counted(Bound(body: 0, bound: 0xffff_ffff_ffff_ffff))], .tracepoint)
      == ProbeLimit.invalid)
  #expect(
    cost([.definedScalar, .unsupported, .choice(Edges(a: 0, b: 1))], .tracepoint)
      == ProbeLimit.invalid)
  #expect(cost([.directCall(0)], .tracepoint) == ProbeLimit.invalid)
  #expect(cost([.definedScalar, .unprovenLoop], .tracepoint) == ProbeLimit.invalid)
  #expect(
    cost(
      [.context(ByteRead(offset: 60, width: 4)), .helper(.drop), .sequence(Edges(a: 0, b: 1))],
      .endpoint) == 2)
  #expect(cost([.context(ByteRead(offset: 60, width: 5))], .packet) == ProbeLimit.invalid)
  #expect(cost([.helper(.redirect)], .endpoint) == ProbeLimit.invalid)
  #expect(cost([.helper(.ringWrite)], .audit) == 1)
}
