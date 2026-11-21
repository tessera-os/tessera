import Foundation
import TarwinDevice

private struct Tables: VtdTableMemory {
  let q: QTest
  var next: UInt64 = 0x600000
  mutating func allocateTable() -> UInt64? {
    guard next < 0x610000 else { return nil }
    let p = next
    next += 4096
    _ = q.send("memset \(p) 4096 0")
    return q.error == nil ? p : nil
  }
  func word(_ p: UInt64) -> UInt64? {
    let value = q.read("q", p)
    return q.error == nil ? value : nil
  }
  func publish(_ p: UInt64, _ v: UInt64) -> Bool {
    q.write("q", p, v)
    return q.error == nil
  }
}
private struct Registers: VtdRegisters {
  let q: QTest
  var deadline = ContinuousClock.now + .seconds(3)
  func read32(_ n: UInt32) -> UInt32 { UInt32(q.read("l", 0xfed9_0000 + UInt64(n))) }
  func read64(_ n: UInt32) -> UInt64 { q.read("q", 0xfed9_0000 + UInt64(n)) }
  func write32(_ n: UInt32, _ v: UInt32) { q.write("l", 0xfed9_0000 + UInt64(n), v) }
  func write64(_ n: UInt32, _ v: UInt64) { q.write("q", 0xfed9_0000 + UInt64(n), v) }
  func expired() -> Bool { q.error != nil || .now >= deadline }
}

/// A private q35 test machine with bus mastering off, ATS off, no assigned
/// hardware. Only the disk function is bound; network functions remain inert.
final class TranslatedDisk {
  private let domain: VtdDomain, unit: VtdLegacyUnit
  private var tables: Tables, registers: Registers, binding: VtdBinding
  let bias: UInt64
  private(set) var retired = 0

  init(_ q: QTest) throws {
    for device in 4...6 {
      _ = q.send("outl 0xcf8 \(0x8000_0004 + device * 0x800)")
      let response = q.send("inw 0xcfc")
      guard response.hasPrefix("0x"), let command = UInt16(response.dropFirst(2), radix: 16),
        command & 4 == 0
      else { throw Failure("Requester already bus mastering") }
    }
    var mem = Tables(q: q)
    var reg = Registers(q: q)
    guard let unit = VtdLegacyUnit(registerBytes: 4096, registers: &reg), unit.maxDomain >= 1,
      let root = mem.allocateTable(), let d = VtdDomain(id: 1, physicalBits: 39, memory: &mem),
      let binding = d.bind(rootTable: root, requester: 4 << 3, unit: unit, memory: &mem)
    else { throw Failure("Missing legacy VT-d unit or private domain") }
    var selected: UInt64?
    var rng = SystemRandomNumberGenerator()
    while selected == nil {
      if case .selected(let b) = chooseDmaAddress(
        DeviceRange(base: 0x1000_0000, length: 0x1000_0000), 0x200000, 4096, rng.next(), [])
      {
        selected = b
      }
    }
    bias = selected!
    for (physical, access): (UInt64, DmaAccess) in [
      (0x100000, .deviceRead), (0x101000, .deviceRead), (0x102000, .both),
      (0x110000, .deviceRead), (0x112000, .deviceWrite),
    ] {
      guard d.mapPage(iova: bias + physical, frame: physical, access: access, memory: &mem) else {
        throw Failure("Cannot map disk queue")
      }
    }
    guard unit.start(root: root, allRequestersBlocked: true, atsDisabled: true, registers: &reg)
    else { throw Failure("Cannot activate VT-d") }
    tables = mem
    registers = reg
    self.binding = consume binding
    self.unit = unit
    domain = consume d
  }
  func close(_ q: QTest) throws {
    // No pending virtqueue chains; block new DMA before clearing the context.
    _ = q.send("outl 0xcf8 0x80002004")
    _ = q.send("outw 0xcfc 2")
    let value = q.send("inw 0xcfc")
    guard value.hasPrefix("0x"), let command = UInt16(value.dropFirst(2), radix: 16),
      command & 4 == 0
    else { throw Failure("Requester not stopped") }
    registers.deadline = .now + .seconds(3)
    guard
      binding.retire(
        requesterStoppedAndDrained: true, unit: unit, memory: &tables, registers: &registers)
    else { throw Failure("Requester context not drained") }
  }
  func mapData(frame: UInt64, access: DmaAccess) throws {
    registers.deadline = .now + .seconds(3)
    guard domain.mapPage(iova: bias + 0x111000, frame: frame, access: access, memory: &tables),
      unit.flushTranslations(registers: &registers)
    else { throw Failure("Data-map publication failed") }
  }
  func retireData(frame: UInt64) -> Bool {
    registers.deadline = .now + .seconds(3)
    var mapping = DmaRetirement(
      domain: 1, pin: frame, base: bias + 0x111000, bytes: 4096, phase: .mapped)
    return mapping.retire(
      { _, addr, _ in self.domain.detach(iova: addr, frame: frame, memory: &self.tables) },
      { _, addr, _ in
        self.domain.drainDetached(
          iova: addr, frame: frame, unit: self.unit, memory: &self.tables,
          registers: &self.registers)
      },
      { _, _, _ in true },  // No requester ATC exists on this machine.
      { _ in self.retired += 1 })
  }
}
