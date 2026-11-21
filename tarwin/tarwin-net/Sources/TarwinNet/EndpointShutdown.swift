import TarwinABI
import TarwinObject
import TarwinSyscall

public enum StreamShutdown: UInt64 {
  case read = 0
  case write, both
}

/// The composition holds the caller's handle read epoch during pinning and
/// rejects exited callers. Resolve the retained object under the stream lock,
/// recheck network authority, then schedule its I/O and TCP workers on success.
public protocol StreamShutdownContext {
  func pinCaller(_ visit: (HandleReadView) -> PinResult) -> PinResult
  mutating func withStream(
    _ object: UnsafePointer<ObjectHeader>, _ visit: (TcpAcceptedStream) -> CallResult
  ) -> CallResult
  mutating func retire(_ object: UnsafePointer<ObjectHeader>)
}

/// Register arguments: endpoint name, ShutdownHow. No port or user memory.
public struct EndpointShutdown<C: StreamShutdownContext>: CallProvider {
  public var context: C
  public init(_ context: C) { self.context = context }
  public func argumentCount(for number: UInt64) -> UInt32? {
    number == TarwinCall.endpointShutdown ? 2 : nil
  }
  public mutating func copyUserWords(
    from address: UInt64, into words: UnsafeMutableBufferPointer<UInt64>
  ) -> Bool { false }
  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    func error(_ code: UInt32) -> CallResult { CallResult(status: syscallStatus(code, 6)) }
    guard number == TarwinCall.endpointShutdown else { return error(10) }
    guard words.count == 2, let how = StreamShutdown(rawValue: words[1]) else { return error(1) }
    let rights: UInt64 = how == .both ? 12 : (how == .write ? 8 : 4)
    switch context.pinCaller({
      $0.pinWithinEpoch(words[0], kind: TarwinKind.endpoint, need: rights)
    }) {
    case .invalidHandle: return error(2)
    case .wrongType: return error(3)
    case .accessDenied: return error(4)
    case .found(let grant):
      let result = context.withStream(grant.header) { stream in
        switch stream.connection.state {
        case .idle, .synSent, .synReceived, .closed: return error(23)
        case .reset: return error(61)
        case .timedOut: return error(25)
        default:
          stream.connection.shutdown(how)
          return CallResult()
        }
      }
      grant.drop { context.retire($0) }
      return result
    }
  }
}
