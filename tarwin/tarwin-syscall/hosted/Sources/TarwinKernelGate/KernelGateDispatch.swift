import Darwin
import Synchronization
import TarwinGateTransport
import TarwinHostedGate
import TarwindKernel

public enum KernelGateDisposition: Equatable {
  case rejected, replied, blocked, replyFailed
}

public final class KernelGateDispatch: Sendable {
  private struct AuthorizedCall: Sendable {
    let number: UInt64
    let arguments: InlineArray<8, UInt64>

    init(_ request: GateRequest) {
      number = request.number
      var words = InlineArray<8, UInt64>(repeating: 0)
      for i in 0..<8 { words[i] = request.arguments[i] }
      arguments = words
    }
  }

  private struct State {
    var closed = false
    var authorized: [UInt64: AuthorizedCall] = [:]
    var waiting: [TarwindContinuationID: PendingGateReply] = [:]
  }

  private let gate: KernelGate
  private let process: TarwindProcessID
  private let port: mach_port_t
  private let pid: pid_t
  private let state = Mutex(State())

  public init(gate: KernelGate, process: TarwindProcessID, port: mach_port_t, pid: pid_t) {
    self.gate = gate
    self.process = process
    self.port = port
    self.pid = pid
  }

  /// Called only with registers captured at a verified trap site by the host exception handler.
  public func authorizeTrap(_ request: GateRequest) -> Bool {
    let thread = request.threadID
    let call = AuthorizedCall(request)
    return state.withLock {
      guard !$0.closed, thread != 0, $0.authorized[thread] == nil else { return false }
      $0.authorized[thread] = call
      return true
    }
  }

  public func dispatch(_ call: ReceivedGateCall) -> KernelGateDisposition {
    state.withLock { state in
      let request = call.request
      guard !state.closed, call.gatePort == port, call.senderPID == pid,
        let authorized = state.authorized[request.threadID], authorized.number == request.number,
        (0..<8).allSatisfy({ authorized.arguments[$0] == request.arguments[$0] })
      else {
        call.reply.cancel()
        return .rejected
      }
      state.authorized.removeValue(forKey: request.threadID)
      var registers = TarwinCallRegisters(number: request.number, arguments: request.arguments)
      switch gate.call(process: process, registers: &registers) {
      case .completed(let result):
        if case .success = call.reply.send(GateReply(result: result)) { return .replied }
        return .replyFailed
      case .blocked(let continuation):
        state.waiting[continuation] = call.reply
        return .blocked
      }
    }
  }

  /// Nonblocking pump for the host event loop. Pending replies do not hold workers.
  @discardableResult public func completeReady() -> Int {
    state.withLock { state in
      var count = 0
      for (continuation, reply) in state.waiting {
        guard let result = gate.completion(continuation) else { continue }
        state.waiting.removeValue(forKey: continuation)
        if case .success = reply.send(GateReply(result: result)) { count += 1 }
      }
      return count
    }
  }

  public func close() {
    state.withLock { state in
      state.closed = true
      state.authorized.removeAll()
      for (continuation, reply) in state.waiting {
        _ = gate.cancel(continuation)
        _ = gate.completion(continuation)
        reply.cancel()
      }
      state.waiting.removeAll()
    }
  }

  deinit { close() }
}
