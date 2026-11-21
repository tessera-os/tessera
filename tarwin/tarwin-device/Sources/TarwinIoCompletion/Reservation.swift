import TarwinIPC

/// The kernel resolves a PORT KOID (never a user handle) in its object
/// table. A retained port survives close. withLockedPort visits that exact
/// object, under its port lock; its callback may not re-enter the port.
public protocol IoPorts: ~Copyable {
  mutating func retainPort(_ port: UInt64) -> Bool
  mutating func withLockedPort(_ port: UInt64, _ visit: (inout CompletionPort) -> Void)
  mutating func wakePort(_ port: UInt64, count: Int)
  mutating func releasePort(_ port: UInt64)
}

public struct IoReservation: ~Copyable {
  private let port: UInt64, operation: PortOperation
  public init?<P: IoPorts & ~Copyable>(
    port: UInt64, object: UInt64, key: UInt64, kind: UInt32, ports: inout P
  ) {
    guard port != 0, ports.retainPort(port) else { return nil }
    var token: PortOperation?
    ports.withLockedPort(port) { token = $0.reserve(object: object, key: key, kind: kind) }
    guard let token else {
      ports.releasePort(port)
      return nil
    }
    self.port = port
    operation = token
  }
  public func matches(port: UInt64, operation: PortOperation) -> Bool {
    self.port == port && self.operation == operation
  }
  /// Consume exactly once, only after the backend's last buffer access.
  /// The result closure is never run for a cancelled operation or closed port.
  public consuming func finish<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, result: () -> PortPacket
  ) {
    var wake = 0
    ports.withLockedPort(port) { wake = $0.finish(operation, at: now, result: result) }
    if wake != 0 { ports.wakePort(port, count: wake) }
    ports.releasePort(port)
  }
}
