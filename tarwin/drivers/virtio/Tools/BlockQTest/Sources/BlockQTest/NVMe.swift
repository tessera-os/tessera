import Foundation
import NVMeDriver
import TarwinBlock
import TarwinBlockWire
import TarwinIPC

private final class NVMeModel: NVMeAccess {
  let q: QTest, base: UInt64, barBytes: UInt64
  init(_ q: QTest, base: UInt64, bytes: UInt64) {
    self.q = q
    self.base = base
    barBytes = bytes
  }
  func register(_ offset: UInt64) -> UInt32 { UInt32(q.read("l", base + offset)) }
  func setRegister(_ offset: UInt64, _ value: UInt32) { q.write("l", base + offset, value) }
  func load(_ addr: UInt64) -> UInt32 { UInt32(q.read("l", addr)) }
  func store(_ addr: UInt64, _ v: UInt32) { q.write("l", addr, v) }
  func acquire() {}
  func release() {}  // qtest commands complete in order
  func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  func pause() { _ = q.send("clock_step 1000000") }
}
func testNVMe(binary: String, disk: URL) throws {
  let pattern = (0..<4096).map { UInt8(truncatingIfNeeded: ($0 &* 37) ^ ($0 >> 8)) }
  do {
    let q = try QTest(
      binary: binary, machine: .x64, disk: disk, translated: false, neighbors: false, storage: .nvme
    )
    defer { q.close() }
    guard let node = q.pciNodes.first(where: { $0.device.deviceClass == 0x010802 }),
      case .pci(0, let bdf) = node.device.location
    else { throw Failure("No NVM Express function") }
    let (_, bars, sizes) = try assignTestBars(q, bdf: bdf, identity: UInt32(node.device.identity))
    let io = NVMeModel(q, base: bars[0], bytes: sizes[0])
    let pages = NVMePages(
      adminSubmission: 0x100000, adminCompletion: 0x101000, submission: 0x102000,
      completion: 0x103000, identify: 0x104000)!
    var dev = try NVMeController.start(io, pages: pages, depth: 2, epoch: 1) {
      $0.count == 1 ? $0[0] : nil
    }
    try q.require(
      dev.limits.capacity == 2048 && dev.limits.blockBytes == 512, "Bad Identify Namespace data")
    let channel = BlockChannel(capacity: dev.limits.capacity, blockBytes: dev.limits.blockBytes)
    let first: UInt64 = 0x111f00
    let second: UInt64 = 0x116000
    let list: UInt64 = 0x120000
    for (at, addr, n) in [(list, first, 256), (list + 16, second, 3840)] {
      q.write("q", at, addr)
      q.write("l", at + 8, UInt32(n))
      q.write("l", at + 12, 0)
    }
    let a = pattern.prefix(256).map { String(format: "%02x", $0) }.joined()
    let b = pattern.dropFirst(256).map { String(format: "%02x", $0) }.joined()
    let guardAddrs = [first - 1, first + 256, second - 1, second + 3840]
    for g in guardAddrs { q.write("b", g, 0xcd) }
    _ = q.send("write \(first) 256 0x\(a)")
    _ = q.send("write \(second) 3840 0x\(b)")
    for (stamp, vector, permission) in [
      (UInt64(2), first, true), (1, 0x100000, true), (1, first, false),
    ] {
      let req = BlockRequest(
        id: 9, epoch: stamp, lba: 0, blocks: 1, queue: 0, op: .read, qos: .standard,
        payload: BlockPayload(list: list, vectors: 1))!
      do {
        try dev.submit(
          req.record(), allows: { addr, _, _ in addr == list || permission },
          readVector: { _ in BlockDmaVector(address: vector, bytes: 512) })
        throw Failure("Accepted stale epoch, queue alias or denied DMA")
      } catch NVMeError.configuration {}
    }
    var key: UInt64 = 0
    for op: BlockOp in [.fua, .flush, .read] {
      key += 1
      let flush = op == .flush
      if op == .read {
        _ = q.send("memset \(first) 256 0")
        _ = q.send("memset \(second) 3840 0")
      }
      var record = RingRecord()
      let id = try channel.request(
        BlockCommand(
          op: op, lba: flush ? 0 : 23, blocks: flush ? 0 : 8, qos: .interactive, queue: 0),
        key: key,
        payload: flush ? BlockPayload() : BlockPayload(list: list, vectors: 2), record: &record)
      try dev.submit(
        record,
        allows: { a, n, w in
          (a == list && n == 32 && !w)
            || (w == (op == .read) && ((a == first && n == 256) || (a == second && n == 3840)))
        },
        readVector: { at in
          guard q.read("l", at + 12) == 0 else { return nil }
          return BlockDmaVector(address: q.read("q", at), bytes: UInt32(q.read("l", at + 8)))
        })
      let end = ContinuousClock.now + .seconds(3)
      while true {
        if let packet = try dev.poll() {
          try channel.finish(packet, id: id, key: key, bytes: flush ? 0 : 4096) { $0 == id }
          break
        }
        try q.require(.now < end, "NVMe I/O timed out")
        io.pause()
      }
    }
    try q.require(
      q.send("read \(first) 256") == "0x" + a && q.send("read \(second) 3840") == "0x" + b
        && channel.notifications == 3
        && guardAddrs.allSatisfy { q.read("b", $0) == 0xcd }, "NVMe DMA readback/guard mismatch")
    try dev.shutdown(timeoutNs: 2_000_000_000)
    try q.require(io.register(28) & 1 == 0, "NVMe still ready after shutdown")
  }
  var expected = Data(repeating: 0x6c, count: 1 << 20)
  expected.replaceSubrange(23 * 512..<31 * 512, with: pattern)
  guard try Data(contentsOf: disk) == expected else {
    throw Failure("NVMe persisted the wrong blocks")
  }
}
