import Foundation
import TarwinBlock
import TarwinBlockWire
import TarwinIPC
import UFSDriver

private final class UFSModel: UFSAccess {
  let q: QTest, base: UInt64, barBytes: UInt64
  init(_ q: QTest, _ base: UInt64, _ size: UInt64) {
    self.q = q
    self.base = base
    barBytes = size
  }
  func register(_ offset: UInt32) -> UInt32 { UInt32(q.read("l", base + UInt64(offset))) }
  func setRegister(_ offset: UInt32, _ value: UInt32) { q.write("l", base + UInt64(offset), value) }
  func copyToDMA(_ a: UInt64, _ bytes: [UInt8]) -> Bool {
    _ = q.send("write \(a) \(bytes.count) 0x" + bytes.map { String(format: "%02x", $0) }.joined())
    return q.error == nil
  }
  func copyFromDMA(_ a: UInt64, count n: Int) -> [UInt8]? {
    let hex = q.send("read \(a) \(n)")
    guard hex.hasPrefix("0x"), hex.utf8.count == 2 + n * 2 else { return nil }
    var bytes = [UInt8]()
    var i = hex.index(hex.startIndex, offsetBy: 2)
    while i < hex.endIndex {
      let j = hex.index(i, offsetBy: 2)
      guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
      bytes.append(b)
      i = j
    }
    return bytes
  }
  func release() {}
  func acquire() {}  // synchronous qtest commands
  func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  func pause() { _ = q.send("clock_step 1000000") }
}
func testUFS(binary: String, disk: URL) throws {
  let data = (0..<4096).map { UInt8(truncatingIfNeeded: ($0 &* 13) ^ ($0 >> 5)) }
  do {
    let q = try QTest(
      binary: binary, machine: .x64, disk: disk, translated: false, neighbors: false, storage: .ufs)
    defer { q.close() }
    guard let node = q.pciNodes.first(where: { $0.device.deviceClass >> 8 == 0x0109 }),
      case .pci(0, let bdf) = node.device.location
    else { throw Failure("No UFS controller") }
    let (_, bars, sizes) = try assignTestBars(q, bdf: bdf, identity: UInt32(node.device.identity))
    let io = UFSModel(q, bars[0], sizes[0])
    let pages = UFSPages(transferList: 0x101000, command: 0x103000)!
    let disk = try UFSController.start(io, pages: pages, lun: 2, epoch: 1, timeoutNs: 2_000_000_000)
    try q.require(
      disk.limits.capacity == 256 && disk.limits.blockBytes == 4096, "Bad UFS unit geometry")
    let channel = BlockChannel(capacity: disk.limits.capacity, blockBytes: disk.limits.blockBytes)
    let table: UInt64 = 0x110000
    let spans: [(UInt64, Int)] = [(0x124ffc, 4), (0x120008, 2048), (0x12a2a0, 2044)]
    for (epoch, addr, writable) in [
      (UInt64(2), spans[0].0, true), (1, 0x103000, true), (1, spans[0].0, false),
    ] {
      let denied = BlockRequest(
        id: 8, epoch: epoch, lba: 0, blocks: 1, queue: 0, op: .read, qos: .standard,
        payload: BlockPayload(list: table, vectors: 1))!
      do {
        try disk.submit(
          denied.record(), allows: { a, _, w in a == table ? !w : writable && w },
          readVector: { _ in BlockDmaVector(address: addr, bytes: 4096) })
        throw Failure("Accepted stale or ungranted UFS transfer")
      } catch UFSError.configuration {}
    }
    var at = 0
    for (i, s) in spans.enumerated() {
      q.write("q", table + UInt64(i * 16), s.0)
      q.write("l", table + UInt64(i * 16 + 8), UInt32(s.1))
      q.write("b", s.0 - 1, UInt8(0xbc))
      q.write("b", s.0 + UInt64(s.1), UInt8(0xcb))
      try q.require(io.copyToDMA(s.0, Array(data[at..<at + s.1])), "UFS fixture DMA setup")
      at += s.1
    }
    try q.require(disk.limits.fua, "UFS logical unit did not advertise FUA")
    for (index, op) in [BlockOp.write, .fua, .flush, .read].enumerated() {
      let flush = op == .flush
      let key = UInt64(index + 1)
      if op == .read { for (a, n) in spans { _ = q.send("memset \(a) \(n) 0") } }
      var record = RingRecord()
      let id = try channel.request(
        BlockCommand(
          op: op, lba: flush ? 0 : op == .write ? 19 : 7, blocks: flush ? 0 : 1, qos: .interactive,
          queue: 0), key: key,
        payload: flush ? BlockPayload() : BlockPayload(list: table, vectors: 3), record: &record)
      try disk.submit(
        record,
        allows: { a, n, w in
          (a == table && !w && n == 48)
            || (w == (op == .read) && spans.contains { $0.0 == a && UInt64($0.1) == n })
        },
        readVector: { a in
          guard q.read("l", a + 12) == 0 else { return nil }
          return BlockDmaVector(address: q.read("q", a), bytes: UInt32(q.read("l", a + 8)))
        })
      do {
        try disk.stop()
        throw Failure("Stopped UFS before block completion")
      } catch UFSError.busy {}
      while true {
        if let done = try disk.poll() {
          try channel.finish(done, id: id, key: key, bytes: flush ? 0 : 4096) { $0 == id }
          break
        }
        io.pause()
      }
    }
    var out = [UInt8]()
    for (a, n) in spans {
      guard let b = io.copyFromDMA(a, count: n) else { throw Failure("Unreadable UFS data") }
      out += b
      try q.require(
        q.read("b", a - 1) == 0xbc && q.read("b", a + UInt64(n)) == 0xcb, "UFS DMA guard changed")
    }
    try q.require(out == data && channel.notifications == 4, "UFS data/port mismatch")
    try disk.stop()
    try q.require(io.register(0x34) & 1 == 0, "UFS still enabled")
  }
  var expected = Data(repeating: 0x6c, count: 1 << 20)
  expected.replaceSubrange(7 * 4096..<8 * 4096, with: data)
  expected.replaceSubrange(19 * 4096..<20 * 4096, with: data)
  guard try Data(contentsOf: disk) == expected else { throw Failure("UFS changed wrong blocks") }
}
