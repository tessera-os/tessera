import Darwin
import Foundation
import TarwinDevice
import TarwinIPC
import TarwinNet
import TarwinNetWire
import VirtioGuest
import VirtioNetService

func netSubmit(
  _ q: QTest, _ queue: inout SplitQueue, _ memory: QueueMemory, _ id: UInt64, _ packet: NetPacket,
  _ receive: Bool
) throws {
  if queue.size == 0 { try q.require(queue.initialize(Int(memory.count)), "Bad net queue size") }
  try q.require(
    submitFrame(
      &queue, id, packet, receive, 1514,
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
func netCompleted(_ q: QTest, _ queue: inout SplitQueue, _ memory: QueueMemory) throws -> UsedBuffer
{
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

  let payload = (0..<127).map { UInt8($0) }
  let route = UdpRoute(
    family: .v4, source: [192, 0, 2, 1], destination: [192, 0, 2, 2], sourcePort: 10001,
    destinationPort: 10002, hops: 64, mtu: 1500)
  let ip = try sendDatagram(route: route, payload: payload)
  let frame = macRight + macLeft + [0x08, 0x00] + ip
  let hex = "0x" + frame.map { String(format: "%02x", $0) }.joined()
  let base = machine.ram + 0x300000
  let rxFrame = base + 4096
  let txFrame = base + 12288
  let count = UInt32(frame.count)
  let txChannel = try NetworkChannel()
  let rxChannel = try NetworkChannel()
  let rxSlots = UnsafeMutableBufferPointer<RxSlot>.allocate(capacity: 1)
  let txSlots = UnsafeMutableBufferPointer<TxSlot>.allocate(capacity: 1)
  let flows = UnsafeMutableBufferPointer<TxFlow>.allocate(capacity: 1)
  rxSlots.initialize(repeating: RxSlot())
  txSlots.initialize(repeating: TxSlot())
  flows.initialize(repeating: TxFlow())
  defer {
    rxSlots.deinitialize()
    rxSlots.deallocate()
    txSlots.deinitialize()
    txSlots.deallocate()
    flows.deinitialize()
    flows.deallocate()
  }
  var inbound = InterfaceRxQueue(queue: 0, maximum: 1514, slots: rxSlots)!
  var outbound = InterfaceTxQueue(packets: txSlots, flows: flows)
  var endpoint = UdpEndpoint(process: 91, family: .v4, port: route.destinationPort, limit: 1)
  endpoint.local = route.destination
  endpoint.peer = route.source
  endpoint.peerPort = route.sourcePort
  endpoint.interfaceId = 3
  let dst = RegisteredReceive(process: 91, key: 23, memory: 92, offset: 0, length: 256)
  try q.require(
    endpoint.post(dst) { $0 == 91 && $1 == 92 && $2 == 0 && $3 == 256 },
    "Client receive pin rejected")
  _ = q.send("memset \(rxFrame) 1514 0xac")
  var record = RingRecord()
  guard case .transferred = inbound.post(pin: 71, iova: rxFrame, ring: &rxChannel.requests),
    case .transferred = rxChannel.service.pop(into: &record),
    let read = prepareNetFrame(
      record, epoch: inbound.epoch, queue: 0, direction: .receive, maximum: 1514, header: base,
      grant: { $0 == rxFrame && $1 == 1514 && $2 })
  else { throw Failure("Receive credit did not reach driver") }
  var rx = SplitQueue()
  var tx = SplitQueue()
  try netSubmit(q, &rx, ring(2), read.request.id, read.packet, true)
  right.notify(0)
  _ = q.send("write \(txFrame) \(count) \(hex)")
  let packet = TxPacket(
    process: 81, flow: 82, memory: 83, offset: 0, bytes: count, notBefore: 100, background: false)
  let key = outbound.enqueue(
    packet, allowed: { $0 == 81 && $1 == 82 },
    pin: { p, m, o, n in p == 81 && m == 83 && o == 0 && n == count ? 84 : 0 })
  let map: (UInt64, UInt64, UInt64, UInt32) -> UInt64? = { e, k, p, n in
    e == 1 && k == key && p == 84 && n == count ? txFrame : nil
  }
  guard key != 0,
    outbound.publish(queue: 1, now: 99, congested: false, iova: map, ring: &txChannel.requests)
      == nil,
    case .transferred = outbound.publish(
      queue: 1, now: 100, congested: false, iova: map, ring: &txChannel.requests),
    case .transferred = txChannel.service.pop(into: &record),
    let write = prepareNetFrame(
      record, epoch: outbound.epoch, queue: 1, direction: .transmit, maximum: 1514,
      header: base + 8192, grant: { $0 == txFrame && $1 == count && !$2 })
  else { throw Failure("Paced transmit did not reach driver") }
  try netSubmit(q, &tx, ring(1), write.request.id, write.packet, false)
  left.notify(1)
  let sent = try netCompleted(q, &tx, ring(1))
  let received = try netCompleted(q, &rx, ring(2))
  guard let txDone = write.complete(cookie: sent.cookie, written: sent.written, flags: 0, gso: 0),
    case .transferred = txChannel.replies.push(txDone.record()),
    case .transferred = txChannel.client.pop(into: &record)
  else { throw Failure("Invalid TX completion") }
  var sentToClient = false
  try q.require(
    outbound.finish(
      queue: 1, record: record, retireMapping: { $0 == 84 },
      done: { sentToClient = $0 == key && $1 == 84 && $2 == .transmitted }) && sentToClient,
    "TX pin did not retire")
  guard
    let rxDone = read.complete(
      cookie: received.cookie, written: received.written, flags: UInt8(q.read("b", base)),
      gso: UInt8(q.read("b", base + 1))),
    rxDone.bytes == count, case .transferred = rxChannel.replies.push(rxDone.record()),
    case .transferred = rxChannel.client.pop(into: &record),
    let id = inbound.receive(record)
  else { throw Failure("Invalid RX completion") }
  var copied: [UInt8] = []
  var receivedIp: [UInt8] = []
  var done = false
  let ok = inbound.deliver(id: id, sync: { $0 == 71 }) { pin, n in
    guard pin == 71, n == count else { return }
    let bytes = (0..<Int(n)).map { UInt8(q.read("b", rxFrame + UInt64($0))) }
    guard bytes.prefix(14).elementsEqual(frame.prefix(14)) else { return }
    receivedIp = Array(bytes.dropFirst(14))
    let delivered = endpoint.deliver(
      receivedIp, 3, { p, iface, _ in p == 91 && iface == 3 },
      { r, b, off, len in
        guard r == dst else { return false }
        copied = Array(b[off..<off + len])
        return true
      }, { r, len, success in done = r == dst && success && len == UInt32(payload.count) })
    done = done && delivered == .delivered(UInt32(payload.count))
  }
  try q.require(
    ok && done && copied == payload && q.read("b", rxFrame + UInt64(count)) == 0xac,
    "UDP payload, completion or sentinel mismatch")
  try checkDatagramEndpoint(receivedIp, route: route, expected: payload)
  left.acknowledge()
  right.acknowledge()
}
private final class NetworkChannel {
  let memory: UnsafeMutableRawBufferPointer
  var requests: RingEndpoint, service: RingEndpoint, replies: RingEndpoint, client: RingEndpoint
  init() throws {
    let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 12288, alignment: 4096)
    guard let m = IoRingMapping(initializing: buf, count: 64, stride: 64),
      let a = m.endpoint(completion: false, producer: true),
      let b = m.endpoint(completion: false, producer: false),
      let c = m.endpoint(completion: true, producer: true),
      let d = m.endpoint(completion: true, producer: false)
    else {
      buf.deallocate()
      throw Failure("Invalid network A.4 mapping")
    }
    memory = buf
    requests = a
    service = b
    replies = c
    client = d
  }
  deinit { memory.deallocate() }
}
