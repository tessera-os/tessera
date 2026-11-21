import Darwin
import Foundation
import VirtioGuest

/// Both modern NICs attach only to the same in-process QEMU hub.
func testNetwork(_ q: QTest, _ machine: Machine) throws {
  func ring(_ index: Int) -> QueueMemory {
    let base = machine.ram + 0x200000 + UInt64(index) * 0x10000
    return QueueMemory(count: 8, descriptors: base, available: base + 4096, used: base + 8192)
  }
  let left = try transport(
    q, machine, type: 1, instance: 0, supported: 32, queues: [ring(0), ring(1)])
  let right = try transport(
    q, machine, type: 1, instance: 1, supported: 32, queues: [ring(2), ring(3)])
  let macLeft = (0..<6).map(left.config)
  let macRight = (0..<6).map(right.config)
  try q.require(
    left.features & right.features & 32 != 0 && macLeft != macRight, "Missing independent MACs")

  func submit(
    _ queue: inout SplitQueue, _ memory: QueueMemory, _ packet: NetPacket, _ receive: Bool
  ) throws {
    try q.require(queue.initialize(Int(memory.count)), "Bad net queue size")
    try q.require(
      submitFrame(
        &queue, receive ? 7 : 8, packet, receive, 1514,
        { addr, size in _ = q.send("memset \(addr) \(size) 0") },
        { index, addr, length, flags, next in
          let slot = memory.descriptors + UInt64(index) * 16
          q.write("q", slot, addr)
          q.write("l", slot + 8, length)
          q.write("w", slot + 12, flags)
          q.write("w", slot + 14, next)
        },
        { i, head in q.write("w", memory.available + 4 + UInt64(i) * 2, head) },
        { idx in q.write("w", memory.available + 2, idx) }), "Frame was not submitted")
  }
  func completed(_ queue: inout SplitQueue, _ memory: QueueMemory) throws -> UsedBuffer {
    let end = ContinuousClock.now + .seconds(3)
    while q.read("w", memory.used + 2) == UInt64(queue.consumed) && q.error == nil && .now < end {
      _ = q.send("clock_step 1000000")
      usleep(500)
    }
    guard
      case .completed(let entry) = queue.consume(
        { UInt16(q.read("w", memory.used + 2)) },
        { UInt32(q.read("l", memory.used + 4 + UInt64($0) * 8)) },
        { UInt32(q.read("l", memory.used + 8 + UInt64($0) * 8)) })
    else { throw q.error ?? Failure("Missing network used entry at \(memory.used)") }
    return entry
  }
  let frame = macRight + macLeft + [0x88, 0xb5] + (0..<128).map { UInt8($0) }
  let hex = "0x" + frame.map { String(format: "%02x", $0) }.joined()
  let base = machine.ram + 0x300000
  let inbound = NetPacket(header: base, frame: base + 4096, bytes: 1514)
  let outbound = NetPacket(header: base + 8192, frame: base + 12288, bytes: UInt32(frame.count))
  var rx = SplitQueue()
  var tx = SplitQueue()
  _ = q.send("memset \(inbound.frame) 1514 0xac")
  try submit(&rx, ring(2), inbound, true)
  right.notify(0)
  _ = q.send("write \(outbound.frame) \(outbound.bytes) \(hex)")
  try submit(&tx, ring(1), outbound, false)
  left.notify(1)
  let sent = try completed(&tx, ring(1))
  let received = try completed(&rx, ring(2))
  try q.require(
    sent.cookie == 8 && frameResult(false, outbound.bytes, sent.written, 0, 0) == .sent,
    "Invalid transmit completion")
  let flags = UInt8(q.read("b", inbound.header))
  let gso = UInt8(q.read("b", inbound.header + 1))
  try q.require(
    received.cookie == 7
      && frameResult(true, inbound.bytes, received.written, flags, gso)
        == .received(outbound.bytes),
    "Invalid receive completion")
  try q.require(
    q.send("read \(inbound.frame) \(outbound.bytes)") == hex
      && q.read("b", inbound.frame + UInt64(outbound.bytes)) == 0xac,
    "Received Ethernet frame or adjacent sentinel mismatch")
  left.acknowledge()
  right.acknowledge()
}
