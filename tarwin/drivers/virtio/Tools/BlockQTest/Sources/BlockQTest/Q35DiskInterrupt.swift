import TarwinABI
import TarwinDevice
import TarwinIPC
import TarwinObject
import TarwinSyscall

/// QTest observes a live IOAPIC input without running a CPU. The first
/// completion discovers the line in this isolated fixture, not a native route.
final class Q35DiskInterrupt: InterruptCallContext {
  let q: QTest, pin: UInt32, slot: DeviceSlotState
  private let header = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
  private let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 1)
  private let packets = UnsafeMutableBufferPointer<PortSlot>.allocate(capacity: 1)
  private var table: HandleTable, line: BoundDriverInterrupt, ports: TestClient
  private let handle: UInt64
  private var started = false, delivered = 0, original: UInt32 = 0
  init(_ q: QTest, pin: UInt32) {
    self.q = q
    self.pin = pin
    var slot = DeviceSlotState(group: 1)
    precondition(slot.assign(true, 2) { _, _ in true })
    self.slot = slot
    header.initialize(
      to: ObjectHeader(
        source: KoidSource(), ownerJob: 1, kind: TarwinKind.interrupt, maximumRights: 64)!)
    var table = HandleTable(storage: cells, salt: 5)!
    guard case .installed(let h) = table.install(header, rights: 64) else { preconditionFailure() }
    handle = h
    self.table = consume table
    packets.initialize(repeating: PortSlot())
    ports = TestClient(port: CompletionPort(storage: packets)!)
    line = BoundDriverInterrupt(
      object: header.pointee.koid, slot: slot, vector: 0x51, port: 1, key: 22)!
    original = entry()
  }
  private func entry() -> UInt32 {
    q.write("l", 0xfec0_0000, 0x10 + 2 * pin)
    return UInt32(q.read("l", 0xfec0_0010))
  }
  private func masked(_ yes: Bool) {
    q.write("l", 0xfec0_0000, 0x10 + 2 * pin)
    q.write("l", 0xfec0_0010, UInt32(0x8051) | (yes ? 1 << 16 : 0))
  }
  func pinCaller(_ visit: (UInt64, HandleReadView) -> PinResult) -> PinResult {
    visit(2, table.reader)
  }
  func retire(_ object: UnsafePointer<ObjectHeader>) { preconditionFailure() }
  func withLockedLine(_ object: UnsafePointer<ObjectHeader>, rearm: borrowing InterruptRearm)
    -> UInt32
  {
    guard object == UnsafePointer(header) else { return 70 }
    return rearm.apply(to: &line, slot: slot, ports: &ports) { self.masked(false) }
  }
  private func complete() -> UInt32 {
    var provider = InterruptCompleteCall(self)
    return [handle].withUnsafeBufferPointer {
      provider.invoke(number: TarwinCall.interruptComplete, words: $0).code
    }
  }
  func deliver(_ observed: UInt32) throws {
    let route = entry()
    try q.require(
      started && observed == pin && route & 0x1c0ff == 0xc051,
      "Expected unmasked level-triggered disk interrupt with remote IRR")
    try q.require(
      line.interrupt(at: UInt64(delivered + 1), ports: &ports) {
        self.masked(true)
        self.q.write("l", 0xfec0_0040, 0x51)  // q35 IOAPIC v0x20 directed EOI
      } && entry() & 0x1c0ff == 0x18051, "INTx did not mask and acknowledge before publishing")
    try q.require(complete() == 24 && entry() & (1 << 16) != 0, "Full interrupt port allowed rearm")
    guard let p = ports.port.take(), p.kind == 11, p.result0 == 0x51, p.key == 22, p.error == 0
    else { throw Failure("Wrong driver notification") }
    delivered += 1
  }
  func afterDeviceAck() throws {
    _ = q.send("inb 0x80")
    try q.require(!q.pciInterrupts.contains(pin), "Virtio ISR read did not lower INTx")
    if started {
      try q.require(
        complete() == 0 && complete() == 23, "Interrupt.complete failed or accepted duplicate")
    } else {
      masked(true)
      try q.require(
        line.activate(slot: slot, ports: &ports) { self.masked(false) },
        "Cannot bind disk interrupt")
      started = true
    }
    let bits = entry()
    try q.require(
      bits & 0x1ffff == 0x8051 && ports.references == 1,
      "Disk interrupt rearm: pin \(pin), entry \(String(bits,radix:16)), refs \(ports.references), delivered \(delivered)"
    )
  }
  func finish(expected: Int) throws {
    try q.require(delivered == expected && delivered > 1, "Missing disk interrupt deliveries")
    try q.require(
      line.revoke(at: 100, ports: &ports) {
        self.masked(true)
        return true
      }, "Failed to drain interrupt")
    try q.require(
      ports.port.take()?.error == 70 && ports.references == 0 && entry() & (1 << 16) != 0,
      "Stale interrupt after revoke")
  }
  deinit {
    _ = line.revoke(at: 101, ports: &ports) {
      self.masked(true)
      return true
    }
    q.write("l", 0xfec0_0000, 0x10 + 2 * pin)
    q.write("l", 0xfec0_0010, original)
    table.drain { _ in preconditionFailure() }
    precondition(header.pointee.release() == .destroy)
    header.deinitialize(count: 1)
    header.deallocate()
    cells.deinitialize()
    cells.deallocate()
    packets.deinitialize()
    packets.deallocate()
  }
}
