import Foundation
import TarwinNet
import VirtioGuest

/// Libslirp supplies both gateways; it has no forwarding or host uplink in
/// this test. No reply bytes or peer MAC addresses are furnished by Swift.
func testNeighbors(_ q: QTest, _ machine: Machine) throws {
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
  let addresses: [[UInt8]] = [
    [10, 0, 2, 15], [0xfd, 0, 0, 0x23, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 15],
  ]
  for (index, ip) in addresses.enumerated() {
    let id = UInt64(index + 1)
    var gateway = ip
    gateway[gateway.count - 1] = 2
    guard let link = NeighborInterface(mac: mac, address: ip),
      var table = NeighborTable(interface: link, limit: 1, retryNs: 10, reachableNs: 20),
      case .send(let frame) = table.resolve(gateway, now: 0)
    else { throw Failure("Cannot form solicitation") }
    let packet = NetPacket(header: txHeader, frame: txHeader + 4096, bytes: UInt32(frame.count))
    _ = q.send(
      "write \(packet.frame) \(frame.count) 0x" + frame.map { String(format: "%02x", $0) }.joined())
    _ = q.send("memset \(inbound.frame) 1515 0xcd")
    try netSubmit(q, &rx, read, id, inbound, true)
    nic.notify(0)
    try netSubmit(q, &tx, write, id, packet, false)
    nic.notify(1)
    let sent = try netCompleted(q, &tx, write)
    try q.require(sent.cookie == id && sent.written == 0, "Unretired solicitation")
    for attempt in 0..<4 {
      let used = try netCompleted(q, &rx, read)
      guard used.cookie == id,
        case .received(let n) = frameResult(
          true, inbound.bytes, used.written, UInt8(q.read("b", rxHeader)),
          UInt8(q.read("b", rxHeader + 1)))
      else { throw Failure("Bad NIC receive") }
      let bytes = (0..<Int(n)).map { UInt8(q.read("b", inbound.frame + UInt64($0))) }
      try q.require(q.read("b", inbound.frame + UInt64(n)) == 0xcd, "Overwritten receive sentinel")
      if table.confirm(bytes, now: 1) { break }
      guard attempt < 3 else { throw Failure("Gateway did not confirm neighbor") }
      _ = q.send("memset \(inbound.frame) 1515 0xcd")
      try netSubmit(q, &rx, read, id, inbound, true)
      nic.notify(0)
    }
    guard case .resolved(let peer) = table.resolve(gateway, now: 2), peer != mac else {
      throw Failure("Missing learned next hop")
    }
    nic.acknowledge()
  }
}
