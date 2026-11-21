// The generated syscall dispatcher maps its call index to these operations.
// These are semantic tags, not wire numbers. The kernel object table supplies
// PinnedIoHandle after validating the name, process, generation and rights and
// pins the object for the duration of the operation; it is never user input.
public enum DeviceOperation {
  case configRead, configWrite, interrupts, mmioRanges, iommuDomain
  case allocateVectors, firmwareCall, reset, setPowerState
  case dmaBufferCreate, interruptComplete, map, grantDoorbell, fenceWait, fenceSignal
}
public enum IoObjectKind { case deviceSlot, memory, iommuDomain, interrupt, mmioRange, fence }

public struct PinnedIoHandle: ~Copyable {
  public let koid: UInt64
  public let kind: IoObjectKind
  public let rights: UInt64

  init(koid: UInt64, kind: IoObjectKind, rights: UInt64) {
    self.koid = koid
    self.kind = kind
    self.rights = rights
  }

  public func permits(_ op: DeviceOperation, _ resolvedKoid: UInt64) -> Bool {
    guard koid != 0, koid == resolvedKoid else { return false }
    let required: (IoObjectKind, UInt64) =
      switch op {
      case .configRead: (.deviceSlot, 4)
      case .configWrite, .interrupts, .mmioRanges, .iommuDomain, .allocateVectors,
        .firmwareCall, .reset, .setPowerState:
        (.deviceSlot, 512)
      case .dmaBufferCreate: (.iommuDomain, 512)
      case .interruptComplete: (.interrupt, 64)
      case .map: (.mmioRange, 16)
      case .grantDoorbell: (.mmioRange, 528)
      case .fenceWait: (.fence, 128)
      case .fenceSignal: (.fence, 64)
      }
    return kind == required.0 && rights & required.1 == required.1
  }
}
public enum ConfigReply: Equatable {
  case denied
  case invalid
  case unsupported
  case fault
  case value(UInt32)
}
public struct ConfigPolicy: Equatable {
  public let writable: UInt32
  public let plainReadWrite: Bool

  public init(writable: UInt32, plainReadWrite: Bool) {
    self.writable = writable
    self.plainReadWrite = plainReadWrite
  }
}

// Slot and config policy are kernel-owned. A single configuration lock spans
// read/modify/validate/write. Unknown or side-effect registers are not read
// in the write path. The platform returns a fault, not a fabricated all-ones
// success, on a device which disappeared.
public func slotConfigCall(
  _ op: DeviceOperation, _ caller: UInt64, _ epoch: UInt64, _ resolvedKoid: UInt64,
  _ grant: borrowing PinnedIoHandle, _ slot: DeviceSlotState, _ offset: UInt64, _ width: UInt64,
  _ value: UInt64, _ policy: (UInt32, UInt32) -> ConfigPolicy,
  _ read: (UInt32, UInt32) -> ConfigReply, _ write: (UInt32, UInt32, UInt32) -> Bool
) -> ConfigReply {
  if op != .configRead && op != .configWrite { return .unsupported }
  if !grant.permits(op, resolvedKoid) || !slot.owns(caller, epoch) { return .denied }
  if (width != 1 && width != 2 && width != 4) || offset >= 4096 || offset % width != 0 {
    return .invalid
  }
  let o = UInt32(offset)
  let w = UInt32(width)
  if op == .configRead { return read(o, w) }
  if value > 0xffff_ffff || o < 0x40 || o >= 0x100 { return .denied }
  let p = policy(o, w)
  if !p.plainReadWrite || p.writable == 0 { return .denied }
  switch read(o, w) {
  case .value(let old):
    if !pciConfigWriteAllowed(o, w, UInt32(value), p.writable, old, p.plainReadWrite) {
      return .denied
    }
    if !write(o, w, UInt32(value)) { return .fault }
    return .value(0)
  default: return .fault
  }
}
