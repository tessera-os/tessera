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
  let pattern = (0..<12288).map { UInt8(truncatingIfNeeded: ($0 &* 37) ^ ($0 >> 8)) }
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
      completion: 0x103000, identify: 0x104000, prpLists: [0x105000])!
    var dev = try NVMeController.start(io, pages: pages, depth: 2, epoch: 1) {
      $0.count == 1 ? $0[0] : nil
    }
    try q.require(
      dev.limits.capacity == 2048 && dev.limits.blockBytes == 512, "Bad Identify Namespace data")
    let channel = BlockChannel(capacity: dev.limits.capacity, blockBytes: dev.limits.blockBytes)
    let first: UInt64 = 0x111f00
    let spans: [(UInt64, Int)] = [(first, 256), (0x116000, 8192), (0x10c000, 3840)]
    let list: UInt64 = 0x120000
    var guardAddrs: [UInt64] = []
    var offset = 0
    for (i, span) in spans.enumerated() {
      let (addr, n) = span
      let at = list + UInt64(i * 16)
      q.write("q", at, addr)
      q.write("l", at + 8, UInt32(n))
      q.write("l", at + 12, 0)
      guardAddrs += [addr - 1, addr + UInt64(n)]
      _ = q.send(
        "b64write \(addr) \(n) " + Data(pattern[offset..<offset + n]).base64EncodedString())
      offset += n
    }
    for g in guardAddrs { q.write("b", g, 0xcd) }
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
        for (addr, n) in spans { _ = q.send("memset \(addr) \(n) 0") }
      }
      var record = RingRecord()
      let id = try channel.request(
        BlockCommand(
          op: op, lba: flush ? 0 : 23, blocks: flush ? 0 : 24, qos: .interactive, queue: 0),
        key: key,
        payload: flush ? BlockPayload() : BlockPayload(list: list, vectors: 3), record: &record)
      try dev.submit(
        record,
        allows: { a, n, w in
          (a == list && n == 48 && !w)
            || (w == (op == .read) && spans.contains { a == $0.0 && n == UInt64($0.1) })
        },
        readVector: { at in
          guard q.read("l", at + 12) == 0 else { return nil }
          return BlockDmaVector(address: q.read("q", at), bytes: UInt32(q.read("l", at + 8)))
        })
      let end = ContinuousClock.now + .seconds(3)
      while true {
        if let packet = try dev.poll() {
          try channel.finish(packet, id: id, key: key, bytes: flush ? 0 : UInt64(pattern.count)) {
            $0 == id
          }
          break
        }
        try q.require(.now < end, "NVMe I/O timed out")
        io.pause()
      }
    }
    var readback = Data()
    for (addr, n) in spans {
      guard let chunk = Data(base64Encoded: q.send("b64read \(addr) \(n)")), chunk.count == n else {
        throw Failure("Short NVMe DMA readback")
      }
      readback.append(chunk)
    }
    try q.require(
      readback == Data(pattern)
        && channel.notifications == 3
        && guardAddrs.allSatisfy { q.read("b", $0) == 0xcd }, "NVMe DMA readback/guard mismatch")
    try dev.shutdown(timeoutNs: 2_000_000_000)
    try q.require(io.register(28) & 1 == 0, "NVMe still ready after shutdown")
  }
  var expected = Data(repeating: 0x6c, count: 1 << 20)
  expected.replaceSubrange(23 * 512..<47 * 512, with: pattern)
  guard try Data(contentsOf: disk) == expected else {
    throw Failure("NVMe persisted the wrong blocks")
  }
}
