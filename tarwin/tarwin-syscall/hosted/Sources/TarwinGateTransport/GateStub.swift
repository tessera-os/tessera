import Darwin
import TarwinABI
import TarwinHostedGate

/// The AArch64 veneer passes saved x0–x7, then x16. Only x0–x3 are replaced.
/// The veneer must preserve the other registers across this native ABI call.
@_cdecl("tarwin_hosted_gate_call")
public func tarwinHostedGateCall(
  _ frame: UnsafeMutablePointer<UInt64>, _ threadID: UInt64,
  _ gate: mach_port_t, _ replyPort: mach_port_t
) -> kern_return_t {
  let request = GateRequest(
    threadID: threadID, number: frame[8],
    arguments: CallRegisters(frame[0], frame[1], frame[2], frame[3], frame[4], frame[5], frame[6], frame[7]))
  switch GateClient.call(request, on: gate, replyPort: replyPort) {
  case .success(let reply):
    frame[0] = reply.result.status
    frame[1] = reply.result.detail
    frame[2] = reply.result.first
    frame[3] = reply.result.second
    return KERN_SUCCESS
  case .failure(.mach(let status)): return status
  case .failure: return KERN_FAILURE
  }
}
