import LibTesseraTarwin
import TarwinABI
import TarwinRandomCore

/// Store one state per native thread. epoch reads the kernel's coherent
/// generation observation, returning nil when it is unavailable.
public struct NativeRandom: ~Copyable {
  private var state = ThreadRandomState()
  public init() {}
  public mutating func fill<G: NativeGate>(
    _ output: UnsafeMutableRawBufferPointer, gate: inout G,
    epoch: () -> RandomEpoch?
  ) -> CallResult {
    let stale = CallResult(status: 23 | (1 << 32))
    guard let observed = epoch(), observed.available else {
      state.discard()
      return stale
    }
    if !state.fill(output, current: observed) {
      var seed = InlineArray<32, UInt8>(repeating: 0)
      let result = withUnsafeMutableBytes(of: &seed) { bytes in
        gate.enter(
          number: TarwinCall.randomFill,
          registers: CallRegisters(UInt64(UInt(bitPattern: bytes.baseAddress!))))
      }
      guard result.status == 0 else { return result }
      let supplied: RandomEpoch =
        result.first | result.second == 0
        ? .physical : .virtualMachine(low: result.first, high: result.second)
      guard supplied == observed, epoch() == observed,
        withUnsafeBytes(of: &seed, { state.replace(seed: $0, at: supplied) }),
        state.fill(output, current: observed)
      else {
        state.discard()
        return stale
      }
    }
    guard epoch() == observed else {
      state.discard()
      for i in output.indices { output[i] = 0 }
      return stale
    }
    return CallResult()
  }
}
