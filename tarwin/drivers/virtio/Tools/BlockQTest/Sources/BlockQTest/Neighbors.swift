import Foundation
import TarwinNet
import VirtioGuest

/// Libslirp supplies both gateways; it has no forwarding or host uplink in
/// this test. No reply bytes or peer MAC addresses are furnished by Swift.
func testNeighbors(_ q: QTest, _ machine: Machine, tcpPipes: (FileHandle, FileHandle)? = nil) throws
{
  let base = machine.ram + 0x400000
  func ring(_ at: UInt64) -> QueueMemory {
    QueueMemory(count: 8, descriptors: at, available: at + 4096, used: at + 8192)
  }
  let read = ring(base)
  let write = ring(base + 0x10000)
  let nic = try transport(q, machine, type: 1, supported: 32, queues: [read, write])
  let mac = (0..<6).map(nic.config)
  try q.require(nic.features & 32 != 0, "Missing NIC MAC")
  let rxHeader = base + 0x20000
  let txHeader = base + 0x30000
  let inbound = NetPacket(header: rxHeader, frame: rxHeader + 4096, bytes: 1514)
  var rx = SplitQueue()
  var tx = SplitQueue()
  var serial: UInt64 = 0
  func send(_ frame: [UInt8]) throws {
    serial += 1
    let packet = NetPacket(header: txHeader, frame: txHeader + 4096, bytes: UInt32(frame.count))
    _ = q.send(
      "write \(packet.frame) \(frame.count) 0x" + frame.map { String(format: "%02x", $0) }.joined())
    try netSubmit(q, &tx, write, serial, packet, false)
    nic.notify(1)
    let done = try netCompleted(q, &tx, write)
    try q.require(done.cookie == serial && done.written == 0, "Unretired transmit")
  }
  func post() throws {
    _ = q.send("memset \(inbound.frame) 1515 0xcd")
    try netSubmit(q, &rx, read, 42, inbound, true)
    nic.notify(0)
  }
  func take() throws -> [UInt8] {
    let used = try netCompleted(q, &rx, read)
    guard used.cookie == 42,
      case .received(let n) = frameResult(
        true, inbound.bytes, used.written, UInt8(q.read("b", rxHeader)),
        UInt8(q.read("b", rxHeader + 1)))
    else { throw Failure("Bad NIC receive") }
    let bytes = (0..<Int(n)).map { UInt8(q.read("b", inbound.frame + UInt64($0))) }
    try q.require(q.read("b", inbound.frame + UInt64(n)) == 0xcd, "Overwritten receive sentinel")
    return bytes
  }
  func until(_ match: ([UInt8]) -> Bool) throws {
    for attempt in 0..<4 {
      let b = try take()
      if match(b) { return }
      if attempt != 3 { try post() }
    }
    throw Failure("No matching libslirp response")
  }
  if let tcpPipes {
    try tcpInterop(
      mac: mac, input: tcpPipes.0, output: tcpPipes.1, post: post, send: send, take: take)
    return
  }
  let local: [UInt8] = [0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 15]
  guard let link = NeighborInterface(mac: mac, address: local),
    var discovery = RouterDiscovery(link: link, identifier: [0, 0, 0, 0, 0, 0, 2, 15])
  else { throw Failure("Invalid link") }
  try post()
  try send(discovery.routerSolicitation())
  try until { frame in discovery.receiveAdvertisement(frame, at: 0, allowRouter: { _, _ in true }) }
  let leases = discovery.addresses(at: 0)
  try q.require(
    discovery.defaultRouters(at: 0).count == 1 && leases.count == 1 && leases[0].1 == .tentative,
    "No router or tentative address")
  try post()
  var txError: Error?
  let sent = discovery.probeTentative(at: 0) { frame in
    do {
      try send(frame)
      return true
    } catch {
      txError = error
      return false
    }
  }
  if let txError { throw txError }
  try q.require(sent, "DAD not started")
  _ = q.send("clock_step 1000000000")
  while q.read("w", read.used + 2) != UInt64(rx.consumed) {
    let frame = try take()
    try q.require(!discovery.observeConflict(frame, at: 0), "Duplicate SLAAC address")
    try post()
  }
  try q.require(discovery.addresses(at: 1).first?.1 == .preferred, "Address not ready after DAD")
  let target6: [UInt8] = [0xfd, 0, 0, 0x23, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]
  try q.require(leases[0].0.prefix(8) == target6.prefix(8), "Unexpected advertised prefix")
  for (index, pair) in [
    ([UInt8]([10, 0, 2, 15]), [UInt8]([10, 0, 2, 2])), (leases[0].0, target6),
  ].enumerated() {
    guard let addr = NeighborInterface(mac: mac, address: pair.0),
      var table = NeighborTable(interface: addr, limit: 1, retryNs: 10, reachableNs: 20),
      case .send(let frame) = table.resolve(pair.1, now: 0)
    else { throw Failure("Cannot form solicitation") }
    if index > 0 { try post() }
    try send(frame)
    try until { table.confirm($0, now: 1) }
    guard case .resolved(let peer) = table.resolve(pair.1, now: 2), peer != mac else {
      throw Failure("Missing learned next hop")
    }
    nic.acknowledge()
  }
}
