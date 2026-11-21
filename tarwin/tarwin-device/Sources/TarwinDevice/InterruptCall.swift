import TarwinABI
import TarwinIPC
import TarwinIoCompletion
import TarwinObject
import TarwinSyscall

/// A kernel-owned immutable slot/vector/port association. The composition
/// holds the slot lock before the IRQ lock, and serializes controller access.
public struct BoundDriverInterrupt: ~Copyable {
  public let object: UInt64, group: UInt64, epoch: UInt64
  private let owner: UInt64, port: UInt64, key: UInt64
  private var irq: PortInterrupt
  public init?(object: UInt64, slot: DeviceSlotState, vector: UInt32, port: UInt64, key: UInt64) {
    guard object != 0, port != 0, slot.phase == .active, slot.epoch != 0 else { return nil }
    self.object = object
    group = slot.group
    epoch = slot.epoch
    owner = slot.owner
    self.port = port
    self.key = key
    irq = PortInterrupt(object: object, epoch: slot.epoch, vector: vector)
  }
  /// Starts masked. Reserve completion space before making delivery possible.
  public mutating func activate<P: IoPorts & ~Copyable>(
    slot: DeviceSlotState, ports: inout P, unmask: () -> Void
  ) -> Bool {
    guard slot.group == group, slot.phase == .active, slot.epoch == epoch, irq.line.state == .armed
    else { return false }
    return irq.arm(epoch: epoch, port: port, key: key, ports: &ports, unmask: unmask)
  }
  public mutating func interrupt<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, acknowledgeAndMask: () -> Void
  ) -> Bool {
    irq.interrupt(at: now, ports: &ports, acknowledgeAndMask: acknowledgeAndMask)
  }
  public func matches(port: UInt64, operation: PortOperation) -> Bool {
    irq.matches(port: port, operation: operation)
  }
  public mutating func revoke<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, maskAndDrain: () -> Bool
  ) -> Bool {
    irq.revoke(at: now, ports: &ports, maskAndDrain: maskAndDrain)
  }
  fileprivate mutating func complete<P: IoPorts & ~Copyable>(
    object: UInt64, process: UInt64, slot: DeviceSlotState, ports: inout P, unmask: () -> Void
  ) -> UInt32 {
    guard self.object == object, owner == process, group == slot.group, epoch == slot.epoch else {
      return 4
    }
    guard !slot.vanished, irq.line.state != .revoked else { return 70 }
    guard slot.owns(process, epoch) else { return 4 }
    guard !irq.revoking, irq.line.state == .delivered else { return 23 }
    return irq.arm(epoch: epoch, port: port, key: key, ports: &ports, unmask: unmask) ? 0 : 24
  }
}
public struct InterruptRearm: ~Copyable {
  fileprivate let object: UInt64, process: UInt64
  public func apply<P: IoPorts & ~Copyable>(
    to line: inout BoundDriverInterrupt,
    slot: DeviceSlotState, ports: inout P, unmask: () -> Void
  ) -> UInt32 {
    line.complete(object: object, process: process, slot: slot, ports: &ports, unmask: unmask)
  }
}
public protocol InterruptCallContext {
  func pinCaller(_ visit: (UInt64, HandleReadView) -> PinResult) -> PinResult
  mutating func retire(_ header: UnsafePointer<ObjectHeader>)
  /// Resolve exactly the retained header and registered slot. A removed device
  /// returns DeviceLost without visiting. Keep the port registry and route
  /// alive across rearm; the driver cannot substitute a port, key or vector.
  mutating func withLockedLine(
    _ object: UnsafePointer<ObjectHeader>,
    rearm: borrowing InterruptRearm
  ) -> UInt32
}
/// Private Interrupt.complete(irq); no user-memory or controller arguments.
public struct InterruptCompleteCall<C: InterruptCallContext>: CallProvider {
  public var context: C
  public init(_ context: C) { self.context = context }
  public func argumentCount(for number: UInt64) -> UInt32? {
    number == TarwinCall.interruptComplete ? 1 : nil
  }
  public mutating func copyUserWords(
    from address: UInt64, into words: UnsafeMutableBufferPointer<UInt64>
  ) -> Bool { false }
  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    func result(_ code: UInt32) -> CallResult {
      code == 0 ? CallResult() : CallResult(status: syscallStatus(code, 5))
    }
    guard number == TarwinCall.interruptComplete else { return result(10) }
    guard words.count == 1 else { return result(1) }
    var process: UInt64 = 0
    let pin = context.pinCaller { owner, table in
      process = owner
      return table.pinWithinEpoch(words[0], kind: TarwinKind.interrupt, need: 64)
    }
    switch consume pin {
    case .invalidHandle: return result(2)
    case .wrongType: return result(3)
    case .accessDenied: return result(4)
    case .found(let grant):
      let h = grant.header
      let code = context.withLockedLine(
        h, rearm: InterruptRearm(object: h.pointee.koid, process: process))
      grant.drop { context.retire($0) }
      return result(code)
    }
  }
}
