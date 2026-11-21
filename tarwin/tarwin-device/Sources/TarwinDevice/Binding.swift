import TarwinObject
import TarwinSyscall

extension DeviceOperation {
  public init?(callNumber: UInt64) {
    switch callNumber {
    case TarwinCall.deviceSlotConfigRead: self = .configRead
    case TarwinCall.deviceSlotConfigWrite: self = .configWrite
    case TarwinCall.deviceSlotInterrupts: self = .interrupts
    case TarwinCall.deviceSlotMmioRanges: self = .mmioRanges
    case TarwinCall.deviceSlotIommuDomain: self = .iommuDomain
    case TarwinCall.deviceSlotAllocateVectors: self = .allocateVectors
    case TarwinCall.deviceSlotFirmwareCall: self = .firmwareCall
    case TarwinCall.deviceSlotReset: self = .reset
    case TarwinCall.deviceSlotSetPowerState: self = .setPowerState
    case TarwinCall.dmaBufferCreate: self = .dmaBufferCreate
    case TarwinCall.interruptComplete: self = .interruptComplete
    case TarwinCall.mmioRangeMap: self = .map
    case TarwinCall.mmioRangeGrantDoorbell: self = .grantDoorbell
    case TarwinCall.fenceWait: self = .fenceWait
    case TarwinCall.fenceSignal: self = .fenceSignal
    default: return nil
    }
  }
}

// The table reader epoch spans the snapshot check and pin. The resolved index
// comes from that table, never from the caller. The borrowed grant cannot
// escape its pin or be constructed by external clients.
public func withPinnedIoHandle<Result>(
  _ value: UInt64, salt: UInt8, index: UInt32, snapshot: HandleSlot,
  pin: (UInt64) -> Bool, release: (UInt64) -> Void,
  perform: (borrowing PinnedIoHandle) -> Result
) -> Result? {
  guard snapshot.check(value, salt, index, 0, 0) == .allowed else { return nil }
  let kind: IoObjectKind
  switch snapshot.kind {
  case TarwinKind.deviceSlot: kind = .deviceSlot
  case TarwinKind.memory: kind = .memory
  case TarwinKind.iommuDomain: kind = .iommuDomain
  case TarwinKind.interrupt: kind = .interrupt
  case TarwinKind.mmioRange: kind = .mmioRange
  case TarwinKind.fence: kind = .fence
  default: return nil
  }
  guard pin(snapshot.koid) else { return nil }
  defer { release(snapshot.koid) }
  return perform(PinnedIoHandle(koid: snapshot.koid, kind: kind, rights: snapshot.rights))
}
