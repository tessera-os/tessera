import LibTesseraTarwin

public struct NativeDmaError: Error {
  public let status, detail: UInt64
}

/// A process-local domain handle, never a hardware domain ID. Close the
/// handle with LibTessera when it is no longer needed.
public struct NativeDmaDomain {
  public let handle: UInt64

  public static func acquire<G: NativeGate>(slot: UInt64, gate: inout G) throws(NativeDmaError)
    -> Self
  {
    let r = gate.enter(number: TarwinCall.deviceSlotIommuDomain, registers: .init(slot))
    guard r.status == 0 else { throw NativeDmaError(status: r.status, detail: r.detail) }
    guard r.first != 0 else { throw NativeDmaError(status: 90, detail: 0) }
    return Self(handle: r.first)
  }

  public func map<G: NativeGate>(
    memory: UInt64, offset: UInt64, bytes: UInt64,
    direction: DmaDirection, gate: inout G
  ) throws(NativeDmaError) -> NativeDmaBuffer {
    let access: UInt64 =
      switch direction {
      case .toDevice: 1
      case .fromDevice: 2
      case .bidirectional: 3
      }
    let r = gate.enter(
      number: TarwinCall.dmaBufferCreate,
      registers: .init(handle, memory, offset, bytes, access))
    guard r.status == 0 else { throw NativeDmaError(status: r.status, detail: r.detail) }
    guard r.first != 0 else { throw NativeDmaError(status: 90, detail: 0) }
    return NativeDmaBuffer(handle: r.first, iova: r.second, length: bytes, direction: direction)
  }
}
