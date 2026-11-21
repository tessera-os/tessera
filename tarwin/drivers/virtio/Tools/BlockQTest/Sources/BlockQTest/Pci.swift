import Foundation
import TarwinDevice
import VirtioGuest

// QTest boots no firmware. Assign the scratch virtio function's memory BARs
// in the synthetic q35 PCI hole before handing the snapshot to the driver.
// This harness never opens a host device or maps host PCI configuration.
func pciTransport(
  _ q: QTest, type: UInt16, instance: Int, supported: UInt32,
  queues: [QueueMemory]
) throws -> DeviceTransport {
  let bdf = try q.requester(type: type, instance: instance)
  guard bdf < 256, bdf & 7 == 0 else { throw Failure("Unsupported synthetic BAR topology") }
  let barWindow = Int(bdf >> 3)
  func select(_ offset: Int) {
    _ = q.send("outl 0xcf8 \(0x8000_0000 + Int(bdf) * 0x100 + (offset & ~3))")
  }
  func cfg(_ offset: Int) throws -> UInt32 {
    select(offset)
    let result = q.send("inl 0xcfc")
    guard result.hasPrefix("0x"), let value = UInt32(result.dropFirst(2), radix: 16) else {
      throw q.error ?? Failure("PCI config read failed")
    }
    return value
  }
  func set(_ offset: Int, _ value: UInt32) {
    select(offset)
    _ = q.send("outl 0xcfc \(value)")
  }
  try q.require(try cfg(0) == (0x1040 + UInt32(type)) << 16 | 0x1af4, "Missing modern PCI function")
  select(4)
  _ = q.send("outw 0xcfc 0")
  var bars = [UInt64](repeating: 0, count: 6)
  var sizes = bars
  var next: UInt64 = 0xc000_0000 + UInt64(barWindow) * 0x1000000
  var i = 0
  while i < 6 {
    let off = 16 + i * 4
    let original = try cfg(off)
    if original & 1 != 0 {
      i += 1
      continue
    }
    let wide = (original & 6) == 4
    guard !wide || i < 5 else { throw Failure("Invalid 64-bit BAR") }
    set(off, .max)
    if wide { set(off + 4, .max) }
    let low = try cfg(off) & 0xffff_fff0
    let high: UInt32 = wide ? try cfg(off + 4) : .max
    if low != 0 || (wide && high != 0) {
      let mask = UInt64(high) << 32 | UInt64(low)
      let size = 0 &- mask
      guard size != 0, size.nonzeroBitCount == 1, size <= 1 << 27 else {
        throw Failure("Invalid BAR size")
      }
      next = (next + size - 1) & ~(size - 1)
      guard next + size <= 0xc000_0000 + UInt64(barWindow + 1) * 0x1000000 else {
        throw Failure("Synthetic BAR aperture exhausted")
      }
      bars[i] = next
      sizes[i] = size
      set(off, UInt32(next) | original & 15)
      if wide { set(off + 4, 0) }
      next += size
    } else {
      set(off, original)
      if wide { set(off + 4, 0) }
    }
    i += wide ? 2 : 1
  }
  select(4)
  _ = q.send("outw 0xcfc 6")
  var config = [UInt8]()
  for off in stride(from: 0, to: 256, by: 4) {
    let value = try cfg(off)
    for j in 0..<4 { config.append(UInt8(truncatingIfNeeded: value >> (j * 8))) }
  }
  guard case .found(let windows) = discoverVirtioPci(config, sizes, type),
    windows.config.length >= (type == 2 ? 8 : type == 1 ? 6 : 0)
  else { throw Failure("Invalid modern PCI capability list or device config") }
  let common = bars[Int(windows.common.bar)] + windows.common.offset
  func width(_ bytes: UInt32) -> String { bytes == 4 ? "l" : bytes == 2 ? "w" : "b" }
  let read: (UInt32, UInt32) -> UInt32 = { UInt32(q.read(width($1), common + UInt64($0))) }
  let write: (UInt32, UInt32, UInt32) -> Void = { q.write(width($1), common + UInt64($0), $2) }
  let end = ContinuousClock.now + .seconds(2)
  guard case .negotiated(let features) = negotiatePci(supported, read, write, { .now >= end })
  else { throw q.error ?? Failure("PCI negotiation failed") }
  var notifications = [UInt64]()
  for (i, memory) in queues.enumerated() {
    guard case .offset(let offset) = setupPciQueue(UInt16(i), memory, windows, read, write)
    else { throw q.error ?? Failure("PCI queue installation failed") }
    notifications.append(bars[Int(windows.notify.bar)] + offset)
  }
  write(20, 1, 15)
  try q.require(read(20, 1) == 15, "PCI driver not ready")
  let cfgBase = bars[Int(windows.config.bar)] + windows.config.offset
  let isr = bars[Int(windows.isr.bar)] + windows.isr.offset
  return DeviceTransport(
    features: features, configBytes: windows.config.length, generation: { read(21, 1) },
    config: { UInt8(q.read("b", cfgBase + UInt64($0))) },
    notify: { q.write("w", notifications[$0], UInt16($0)) },
    acknowledge: { _ = q.read("b", isr) })
}

// QTest grants no DeviceRoot to a guest. This read-only host-side enumeration
// uses q35 PCI mechanism #1 for the standard header fields that ECAM shares.
private struct InventoryOnly: GroupTeardown {
  func maskInterrupts(group: UInt64) -> Bool { false }
  func revokeMaps(group: UInt64) -> Bool { false }
  func retireDma(group: UInt64) -> Bool { false }
  func reset(group: UInt64) -> Bool { false }
}
func enumerateQ35(_ q: QTest) throws -> [RegistryNode] {
  var bad = false
  let functions = enumerateEcam(0, 255) { offset in
    let reg = offset & 4095
    guard reg < 256 else {
      bad = true
      return .max
    }
    _ = q.send("outl 0xcf8 \(0x8000_0000|(offset>>12)<<8|reg)")
    let word = q.send("inl 0xcfc")
    guard word.hasPrefix("0x"), let v = UInt32(word.dropFirst(2), radix: 16) else {
      bad = true
      return .max
    }
    return v
  }
  guard !bad else { throw q.error ?? Failure("Failed PCI enumeration") }
  func location(_ p: PciFunction) -> DeviceLocation {
    .pci(segment: 0, requester: UInt16(p.bus << 8 | p.device << 3 | p.functionNumber))
  }
  let devices = functions.map { p in
    HardwareDevice(
      location: location(p), parent: p.parent < 0 ? nil : location(functions[p.parent]),
      stable: StableDeviceID(high: 1, low: UInt64(p.bus << 8 | p.device << 3 | p.functionNumber)),
      identity: UInt64(p.identity), deviceClass: p.classRevision >> 8,
      group: nil, mmio: [], wiredInterrupts: 0, powerStates: 0, wakeCapable: false)
  }
  var r = HardwareRegistry(limit: 4096)!
  var provider = InventoryOnly()
  guard r.stage(devices, reason: .orderly), r.commit(&provider),
    case .snapshot(_, let nodes) = r.changes(deviceRoot: true, after: nil)
  else { throw Failure("Invalid PCI registry snapshot") }
  return nodes
}
