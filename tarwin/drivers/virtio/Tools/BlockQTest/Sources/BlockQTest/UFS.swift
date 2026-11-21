import Foundation
import TarwinBlock
import TarwinBlockWire
import TarwinIPC
import UFSDriver

private final class UFSModel: UFSAccess {
  let q: QTest, base: UInt64, barBytes: UInt64, bias: UInt64
  static let list: UInt64 = 0x101000, command: UInt64 = 0x103000
  init(_ q: QTest, _ base: UInt64, _ size: UInt64, bias: UInt64) {
    self.q = q
    self.base = base
    barBytes = size
    self.bias = bias
  }
  func register(_ offset: UInt32) -> UInt32 { UInt32(q.read("l", base + UInt64(offset))) }
  func setRegister(_ offset: UInt32, _ value: UInt32) { q.write("l", base + UInt64(offset), value) }
  private func privateFrame(_ iova: UInt64, _ count: Int) -> UInt64? {
    guard iova >= bias, count > 0 else { return nil }
    let a = iova - bias
    let page = a & ~UInt64(4095)
    guard page == Self.list || page == Self.command, count <= 4096 - Int(a - page) else {
      return nil
    }
    return a
  }
  func copyToDMA(_ iova: UInt64, _ bytes: [UInt8]) -> Bool {
    guard let a = privateFrame(iova, bytes.count) else { return false }
    _ = q.send("b64write \(a) \(bytes.count) " + Data(bytes).base64EncodedString())
    return q.error == nil
  }
  func copyFromDMA(_ iova: UInt64, count n: Int) -> [UInt8]? {
    guard let a = privateFrame(iova, n) else { return nil }
    guard let data = Data(base64Encoded: q.send("b64read \(a) \(n)")), data.count == n else {
      return nil
    }
    return Array(data)
  }
  func release() {}
  func acquire() {}  // synchronous qtest commands
  func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  func pause() { _ = q.send("clock_step 1000000") }
}
func testUFS(binary: String, disk: URL, translated: Bool) throws {
  let data = (0..<4096).map { UInt8(truncatingIfNeeded: ($0 &* 13) ^ ($0 >> 5)) }
  let other = disk.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".raw")
  let sentinel = Data(repeating: 0xa7, count: 1 << 19)
  try sentinel.write(to: other, options: .withoutOverwriting)
  defer { try? FileManager.default.removeItem(at: other) }
  do {
    let q = try QTest(
      binary: binary, machine: .x64, disk: disk, translated: translated, neighbors: false,
      extraDevices: [
        "-drive", "if=none,id=other,format=raw,file=" + other.path, "-device",
        "ufs-lu,bus=ufs0,lun=1,drive=other",
      ], storage: .ufs)
    defer { q.close() }
    guard let node = q.pciNodes.first(where: { $0.device.deviceClass >> 8 == 0x0109 }),
      case .pci(0, let bdf) = node.device.location
    else { throw Failure("No UFS controller") }
    let dma =
      translated
      ? try TranslatedDisk(
        q, requester: bdf,
        queues: [
          (UFSModel.list, .both), (UFSModel.command, .both),
        ]) : nil
    let bias = dma?.bias ?? 0
    let (_, bars, sizes) = try assignTestBars(q, bdf: bdf, identity: UInt32(node.device.identity))
    let io = UFSModel(q, bars[0], sizes[0], bias: bias)
    let pages = UFSPages(transferList: bias + UFSModel.list, command: bias + UFSModel.command)!
    var discovered = [UInt8]()
    do {
      _ = try UFSController.start(io, pages: pages, epoch: 1, timeoutNs: 2_000_000_000) { units in
        discovered = units
        return 99
      }
      throw Failure("Selected an unlisted logical unit")
    } catch UFSError.configuration {}
    try q.require(
      discovered.sorted() == [1, 2] && io.register(0x34) & 1 == 0,
      "Invalid LU selection did not stop controller")
    let disk = try UFSController.start(io, pages: pages, epoch: 1, timeoutNs: 2_000_000_000) {
      units in
      units.sorted() == [1, 2] ? units.max() : nil
    }
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
          readVector: { _ in BlockDmaVector(address: bias + addr, bytes: 4096) })
        throw Failure("Accepted stale or ungranted UFS transfer")
      } catch UFSError.configuration {}
    }
    var at = 0
    for (i, s) in spans.enumerated() {
      q.write("q", table + UInt64(i * 16), bias + s.0)
      q.write("l", table + UInt64(i * 16 + 8), UInt32(s.1))
      q.write("b", s.0 - 1, UInt8(0xbc))
      q.write("b", s.0 + UInt64(s.1), UInt8(0xcb))
      let input = Data(data[at..<at + s.1]).base64EncodedString()
      _ = q.send("b64write \(s.0) \(s.1) " + input)
      at += s.1
    }
    try q.require(disk.limits.fua, "UFS logical unit did not advertise FUA")
    for (index, op) in [BlockOp.write, .fua, .flush, .read].enumerated() {
      let flush = op == .flush
      let key = UInt64(index + 1)
      var record = RingRecord()
      let id = try channel.request(
        BlockCommand(
          op: op, lba: flush ? 0 : op == .write ? 19 : 7, blocks: flush ? 0 : 1, qos: .interactive,
          queue: 0), key: key,
        payload: flush ? BlockPayload() : BlockPayload(list: table, vectors: 3), record: &record)
      let readDelta: UInt64 = translated && op == .read ? 0x10000 : 0
      for (a, n) in spans where !flush {
        let page = a & ~UInt64(4095)
        if op == .read {
          if translated { _ = q.send("memset \(a) \(n) 0xa7") }
          _ = q.send("memset \(a+readDelta) \(n) 0")
          q.write("b", a + readDelta - 1, UInt8(0xbc))
          q.write("b", a + readDelta + UInt64(n), UInt8(0xcb))
        }
        try dma?.mapData(
          page: page, frame: page + readDelta, access: op == .read ? .deviceWrite : .deviceRead)
      }
      try disk.submit(
        record,
        allows: { a, n, w in
          (a == table && !w && n == 48)
            || (w == (op == .read) && spans.contains { $0.0 + bias == a && UInt64($0.1) == n })
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
          try channel.finish(done, id: id, key: key, bytes: flush ? 0 : 4096) { cookie in
            guard cookie == id else { return false }
            guard let dma, !flush else { return true }
            return spans.allSatisfy { a, _ in
              let page = a & ~UInt64(4095)
              return dma.retireData(page: page, frame: page + readDelta)
            }
          }
          break
        }
        io.pause()
      }
    }
    var out = [UInt8]()
    for (source, n) in spans {
      let a = translated ? source + 0x10000 : source
      if translated {
        try q.require(
          Data(base64Encoded: q.send("b64read \(source) \(n)")) == Data(repeating: 0xa7, count: n),
          "UFS DMA changed retired source frame")
      }
      guard let b = Data(base64Encoded: q.send("b64read \(a) \(n)")), b.count == n else {
        throw Failure("Unreadable UFS data")
      }
      out += b
      try q.require(
        q.read("b", a - 1) == 0xbc && q.read("b", a + UInt64(n)) == 0xcb, "UFS DMA guard changed")
    }
    try q.require(out == data && channel.notifications == 4, "UFS data/port mismatch")
    try disk.stop()
    try q.require(io.register(0x34) & 1 == 0, "UFS still enabled")
    if let dma {
      try q.require(
        dma.retired == 9 && q.read("l", 0xfed9_0034) == 0,
        "Missing data drains or UFS remapping fault")
      try dma.close(q)
    }
  }
  var expected = Data(repeating: 0x6c, count: 1 << 20)
  expected.replaceSubrange(7 * 4096..<8 * 4096, with: data)
  expected.replaceSubrange(19 * 4096..<20 * 4096, with: data)
  guard try Data(contentsOf: disk) == expected else { throw Failure("UFS changed wrong blocks") }
  guard try Data(contentsOf: other) == sentinel else {
    throw Failure("UFS changed the unselected LU")
  }
}
