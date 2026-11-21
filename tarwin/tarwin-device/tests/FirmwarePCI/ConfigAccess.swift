import TarwinABI
import TarwinDevice
import TarwinObject
import TarwinSyscall

typealias PciRead =
  @convention(c) (UnsafeRawPointer, UInt32, UInt64, UInt, UnsafeMutableRawPointer) -> UInt

private struct FirmwareConfig: SlotConfigSpace {
  let root: UnsafeRawPointer, readPci: PciRead, bdf: UInt64
  var reads = 0, unexpectedWrite = false
  func policy(offset: UInt32, width: UInt32) -> ConfigPolicy {
    .init(writable: 0, plainReadWrite: false)
  }
  mutating func read(offset: UInt32, width: UInt32) -> ConfigReply {
    // This diagnostic needs only the vendor/device ID. Never probe unrelated
    // registers or allow a firmware write, even if the tested provider fails.
    guard offset == 0, width == 4 else { return .unsupported }
    var id: UInt32 = 0
    reads += 1
    return readPci(root, 2, bdf, 1, &id) == 0 ? .value(id) : .fault
  }
  mutating func write(offset: UInt32, width: UInt32, value: UInt32) -> Bool {
    unexpectedWrite = true
    return false
  }
}

private struct GuestSlot: SlotConfigContext {
  let header: UnsafePointer<ObjectHeader>, handles: HandleReadView
  var state: DeviceSlotState, space: FirmwareConfig
  var retired = false
  func pinCaller(_ visit: (UInt64, HandleReadView) -> PinResult) -> PinResult {
    visit(11, handles)  // single CPU, no concurrent closure or retirement
  }
  mutating func withConfig(
    _ object: UnsafePointer<ObjectHeader>,
    _ visit: (UInt64, DeviceSlotState, inout FirmwareConfig) -> ConfigReply
  ) -> ConfigReply {
    guard object == header else { return .fault }
    return visit(1, state, &space)
  }
  mutating func retire(_ header: UnsafePointer<ObjectHeader>) { retired = true }
}

func checkConfig(root: UnsafeRawPointer, read: PciRead, function: PciFunction) -> Bool {
  withUnsafeTemporaryAllocation(
    byteCount: MemoryLayout<ObjectHeader>.stride,
    alignment: MemoryLayout<ObjectHeader>.alignment
  ) { rawHeader in
    withUnsafeTemporaryAllocation(
      byteCount: MemoryLayout<HandleCell>.stride,
      alignment: MemoryLayout<HandleCell>.alignment
    ) { rawCell in
      let h = rawHeader.baseAddress!.bindMemory(to: ObjectHeader.self, capacity: 1)
      guard
        let obj = ObjectHeader(
          source: KoidSource(), ownerJob: 1, kind: TarwinKind.deviceSlot,
          maximumRights: 516)
      else { return false }
      h.initialize(to: consume obj)
      defer { h.deinitialize(count: 1) }
      let cell = rawCell.baseAddress!.bindMemory(to: HandleCell.self, capacity: 1)
      guard var table = HandleTable(storage: .init(start: cell, count: 1), salt: 92) else {
        return false
      }
      defer { cell.deinitialize(count: 1) }
      guard case .installed(let name) = table.install(h, rights: 516) else { return false }
      let bdf = UInt64(function.bus << 24 | function.device << 16 | function.functionNumber << 8)
      var state = DeviceSlotState(group: 1)
      // Local bookkeeping only: this diagnostic creates no driver process,
      // exposes no BAR, requests no IOMMU group and does not enable bus mastering.
      guard state.assign(true, 11, { _, _ in true }) else { return false }
      var provider = DeviceConfigCalls(
        GuestSlot(
          header: .init(h), handles: table.reader, state: state,
          space: FirmwareConfig(root: root, readPci: read, bdf: bdf)))
      #if arch(arm64)
        let arch = CallISA.aarch64
      #elseif arch(x86_64)
        let arch = CallISA.x64
      #else
        let arch = CallISA.rv64
      #endif
      func call(_ nr: UInt64, _ args: CallRegisters) -> CallResult {
        var words = InlineArray<4, UInt64>(repeating: 0)
        return withUnsafeMutableBytes(of: &words) {
          switch dispatchCall(
            isa: arch, savedPC: arch == .rv64 ? 0x1000 : 0x1000 + arch.instructionWidth,
            libraryCode: 0x1000..<0x2000, userRange: 0..<0, number: nr, registers: args,
            scratch: $0.bindMemory(to: UInt64.self), provider: &provider)
          {
          case .returned(let r): return r
          default: return CallResult(status: .max)
          }
        }
      }
      let identity = call(TarwinCall.deviceSlotConfigRead, .init(name, 0, 4))
      let denied = call(TarwinCall.deviceSlotConfigWrite, .init(name, 0x10, 4, 0))
      let closed = table.close(name) { _ in provider.context.retired = true }
      let stale = call(TarwinCall.deviceSlotConfigRead, .init(name, 0, 4))
      return h.pointee.release() == .destroy && identity.code == 0
        && identity.first == UInt64(function.identity)
        && denied.code == 4 && closed && stale.code == 2 && !provider.context.retired
        && provider.context.space.reads == 1 && !provider.context.space.unexpectedWrite
    }
  }
}
