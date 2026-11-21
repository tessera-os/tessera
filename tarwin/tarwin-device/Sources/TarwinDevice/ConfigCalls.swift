import TarwinABI
import TarwinObject
import TarwinSyscall

/// Bounded config accesses for a single enumerated function. Policy is
/// supplied by the kernel, never by the driver. Reads must be zero-extended.
public protocol SlotConfigSpace {
  func policy(offset: UInt32, width: UInt32) -> ConfigPolicy
  mutating func read(offset: UInt32, width: UInt32) -> ConfigReply
  mutating func write(offset: UInt32, width: UInt32, value: UInt32) -> Bool
}

public protocol SlotConfigContext {
  associatedtype Space: SlotConfigSpace
  /// Visit the current process KOID and its table in a read-side epoch.
  func pinCaller(_ visit: (UInt64, HandleReadView) -> PinResult) -> PinResult
  mutating func retire(_ header: UnsafePointer<ObjectHeader>)
  /// Resolve this exact retained slot object. Keep the hotplug/config lock
  /// across the visit, supplying its immutable grant epoch, current group
  /// state and function-specific config space. A lost binding is a fault.
  mutating func withConfig(
    _ header: UnsafePointer<ObjectHeader>,
    _ visit: (UInt64, DeviceSlotState, inout Space) -> ConfigReply
  ) -> ConfigReply
}

/// Private register ABI: slot name, offset, width, then value for writes.
/// Only the generated two selectors are registered; neither takes user memory.
public struct DeviceConfigCalls<C: SlotConfigContext>: CallProvider {
  public var context: C
  public init(_ context: C) { self.context = context }
  public func argumentCount(for number: UInt64) -> UInt32? {
    if number == TarwinCall.deviceSlotConfigRead { return 3 }
    if number == TarwinCall.deviceSlotConfigWrite { return 4 }
    return nil
  }
  public mutating func copyUserWords(
    from address: UInt64,
    into destination: UnsafeMutableBufferPointer<UInt64>
  ) -> Bool { false }

  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    func error(_ code: UInt32) -> CallResult { CallResult(status: syscallStatus(code, 5)) }
    guard let n = argumentCount(for: number) else { return error(10) }
    guard words.count == Int(n) else { return error(1) }
    let reading = number == TarwinCall.deviceSlotConfigRead
    var process: UInt64 = 0
    let pin = context.pinCaller { koid, table in
      process = koid
      return table.pinWithinEpoch(words[0], kind: TarwinKind.deviceSlot, need: reading ? 4 : 512)
    }
    switch consume pin {
    case .invalidHandle: return error(2)
    case .wrongType: return error(3)
    case .accessDenied: return error(4)
    case .found(let grant):
      let header = grant.header
      let h = PinnedIoHandle(koid: header.pointee.koid, kind: .deviceSlot, rights: grant.rights)
      let reply = context.withConfig(header) { epoch, slot, space in
        slotConfigCall(
          reading ? .configRead : .configWrite, process, epoch, header.pointee.koid,
          h, slot, words[1], words[2], reading ? 0 : words[3],
          { space.policy(offset: $0, width: $1) },
          { space.read(offset: $0, width: $1) },
          { space.write(offset: $0, width: $1, value: $2) })
      }
      grant.drop { context.retire($0) }
      switch reply {
      case .value(let v): return CallResult(first: UInt64(v))
      case .denied: return error(4)
      case .fault: return error(70)
      case .invalid: return error(1)
      case .unsupported: return error(10)
      }
    }
  }
}
