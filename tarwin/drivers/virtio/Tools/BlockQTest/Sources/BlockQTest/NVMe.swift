import Foundation
import NVMeDriver
import TarwinBlock
import TarwinBlockWire
import TarwinDevice
import TarwinIPC

private final class NVMeModel: NVMeAccess {
  let q: QTest, base: UInt64, barBytes: UInt64, bias: UInt64
  init(_ q: QTest, base: UInt64, bytes: UInt64, bias: UInt64) {
    self.q = q
    self.base = base
    barBytes = bytes
    self.bias = bias
  }
  func register(_ offset: UInt64) -> UInt32 { UInt32(q.read("l", base + offset)) }
  func setRegister(_ offset: UInt64, _ value: UInt32) { q.write("l", base + offset, value) }
  private func privateFrame(_ addr: UInt64) -> UInt64 {
    precondition((bias + 0x100000..<bias + 0x106000).contains(addr) && addr % 4 == 0)
    return addr - bias
  }
  func load(_ addr: UInt64) -> UInt32 { UInt32(q.read("l", privateFrame(addr))) }
  func store(_ addr: UInt64, _ v: UInt32) { q.write("l", privateFrame(addr), v) }
  func acquire() {}
  func release() {}  // qtest commands complete in order
  func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  func pause() { _ = q.send("clock_step 1000000") }
}
func testNVMe(binary: String, disk: URL, translated: Bool, discard: Bool = false,
              volume: NVMeVolumeScenario? = nil) throws {
  let pattern = (0..<12288).map { UInt8(truncatingIfNeeded: ($0 &* 37) ^ ($0 >> 8)) }
  let trace = disk.appendingPathExtension("trace")
  defer { if discard { try? FileManager.default.removeItem(at: trace) } }
  do {
    let q = try QTest(
      binary: binary, machine: .x64, disk: disk, translated: translated, neighbors: false,
      extraDevices: discard ? ["-D", trace.path, "-trace", "pci_nvme_dsm*"] : volume?.devices ?? [],
      storage: .nvme, unmap: discard
    )
    defer { q.close() }
    guard let node = q.pciNodes.first(where: { $0.device.deviceClass == 0x010802 }),
      case .pci(0, let bdf) = node.device.location
    else { throw Failure("No NVM Express function") }
    let dma =
      translated
      ? try TranslatedDisk(
        q, requester: bdf,
        queues: [
          (0x100000, .deviceRead), (0x101000, .deviceWrite),
          (0x102000, .deviceRead), (0x103000, .deviceWrite),
          (0x104000, .deviceWrite), (0x105000, .deviceRead),
        ]) : nil
    let bias = dma?.bias ?? 0
    let (_, bars, sizes) = try assignTestBars(q, bdf: bdf, identity: UInt32(node.device.identity))
    let io = NVMeModel(q, base: bars[0], bytes: sizes[0], bias: bias)
    let pages = NVMePages(
      adminSubmission: bias + 0x100000, adminCompletion: bias + 0x101000,
      submission: bias + 0x102000, completion: bias + 0x103000,
      identify: bias + 0x104000, prpLists: [bias + 0x105000])!
    var dev = try NVMeController.start(io, pages: pages, depth: 2, epoch: 1) {
      $0.count == 1 ? $0[0] : nil
    }
    try q.require(
      dev.limits.capacity == 2048 && dev.limits.blockBytes == 512 && dev.limits.zero,
      "Missing expected namespace geometry or Write Zeroes support")
    let channel = BlockChannel(capacity: dev.limits.capacity, blockBytes: dev.limits.blockBytes)
    if let volume, let dma {
      try volume.run(q, controller: &dev, dma: dma, channel: channel)
      try dev.shutdown(timeoutNs: 2_000_000_000)
      try q.require(io.register(28) & 1 == 0, "NVMe still ready after volume stop")
      try dma.close(q)
      return
    }
    if discard {
      try q.require(dev.limits.discard && dev.maxDiscardBlocks >= 8,
        "No eight-LBA Dataset Management range: limit \(dev.maxDiscardBlocks)")
    }
    let first: UInt64 = 0x111f00
    let spans: [(UInt64, Int)] = [(first, 256), (0x116000, 8192), (0x10c000, 3840)]
    let dataPages: [UInt64] = [0x111000, 0x116000, 0x117000, 0x10c000]
    let readDelta: UInt64 = translated ? 0x40000 : 0
    let list: UInt64 = 0x120000
    var guardAddrs: [UInt64] = []
    var offset = 0
    for (i, span) in spans.enumerated() {
      let (addr, n) = span
      let at = list + UInt64(i * 16)
      q.write("q", at, bias + addr)
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
          readVector: { _ in BlockDmaVector(address: bias + vector, bytes: 512) })
        throw Failure("Accepted stale epoch, queue alias or denied DMA")
      } catch NVMeError.configuration {}
    }
    var key: UInt64 = 0
    for (lba, blocks): (UInt64, UInt64) in [(0, 9), (dev.limits.capacity - 1, 2)] {
      let request = BlockRequest(
        id: 10, epoch: 1, lba: lba, blocks: blocks, queue: 0,
        op: .zero, qos: .standard, payload: BlockPayload())!
      do {
        try dev.submit(request.record(), allows: { _, _, _ in false }, readVector: { _ in nil })
        throw Failure("Accepted out-of-range or oversize Write Zeroes")
      } catch NVMeError.configuration {}
    }
    let commands: [(BlockOp, UInt64, UInt64)] = [(.fua, 23, 24), (.zero, 25, 3)]
      + (discard ? [(.discard, 64, 8)] : []) + [(.flush, 0, 0), (.read, 23, 24)]
    for (op, lba, blocks) in commands {
      key += 1
      let data = op == .fua || op == .read
      if op == .read {
        for (addr, n) in spans {
          if translated { _ = q.send("memset \(addr) \(n) 0xa7") }
          _ = q.send("memset \(addr+readDelta) \(n) 0")
        }
        for addr in guardAddrs { q.write("b", addr + readDelta, 0xcd) }
      }
      if data, let dma {
        for page in dataPages {
          try dma.mapData(
            page: page, frame: page + (op == .read ? readDelta : 0),
            access: op == .read ? .deviceWrite : .deviceRead)
        }
      }
      var record = RingRecord()
      let id = try channel.request(
        BlockCommand(
          op: op, lba: lba, blocks: blocks, qos: .interactive, queue: 0),
        key: key,
        payload: data ? BlockPayload(list: list, vectors: 3) : BlockPayload(), record: &record)
      try dev.submit(
        record,
        allows: { a, n, w in
          data
            && ((a == list && n == 48 && !w)
              || (w == (op == .read) && spans.contains { a == bias + $0.0 && n == UInt64($0.1) }))
        },
        readVector: { at in
          guard q.read("l", at + 12) == 0 else { return nil }
          return BlockDmaVector(address: q.read("q", at), bytes: UInt32(q.read("l", at + 8)))
        })
      let end = ContinuousClock.now + .seconds(3)
      while true {
        if let packet = try dev.poll() {
          try channel.finish(packet, id: id, key: key, bytes: data ? UInt64(pattern.count) : 0) {
            guard $0 == id else { return false }
            guard let dma, data else { return true }
            return dataPages.allSatisfy { page in
              dma.retireData(page: page, frame: page + (op == .read ? readDelta : 0))
            }
          }
          break
        }
        try q.require(.now < end, "NVMe I/O timed out")
        io.pause()
      }
    }
    var readback = Data()
    for (addr, n) in spans {
      if translated {
        try q.require(
          Data(base64Encoded: q.send("b64read \(addr) \(n)")) == Data(repeating: 0xa7, count: n),
          "NVMe read touched retired source frame")
      }
      guard let chunk = Data(base64Encoded: q.send("b64read \(addr+readDelta) \(n)")),
        chunk.count == n
      else {
        throw Failure("Short NVMe DMA readback")
      }
      readback.append(chunk)
    }
    var afterZero = Data(pattern)
    afterZero.resetBytes(in: 2 * 512..<5 * 512)
    try q.require(
      readback == afterZero
        && channel.notifications == commands.count
        && guardAddrs.allSatisfy { q.read("b", $0) == 0xcd && q.read("b", $0 + readDelta) == 0xcd },
      "NVMe DMA readback/guard mismatch")
    try dev.shutdown(timeoutNs: 2_000_000_000)
    try q.require(io.register(28) & 1 == 0, "NVMe still ready after shutdown")
    if let dma {
      try q.require(
        dma.retired == 8 && q.read("l", 0xfed9_0034) == 0,
        "Missing NVMe mapping retirements or VT-d fault")
      try dma.close(q)
    }
  }
  var expected = Data(repeating: 0x6c, count: 1 << 20)
  expected.replaceSubrange(23 * 512..<47 * 512, with: pattern)
  expected.resetBytes(in: 25 * 512..<28 * 512)
  let result = try Data(contentsOf: disk)
  if discard {
    let events = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
    let deallocations = events.filter { $0.contains("pci_nvme_dsm_deallocate ") }
    guard deallocations.count == 1, deallocations[0].hasSuffix("slba 64 nlb 8"),
      events.contains(where: { $0.hasSuffix("pci_nvme_dsm nr 1 attr 0x4") }),
      !events.contains(where: { $0.contains("pci_nvme_dsm_single_range_limit_exceeded") }),
      result.count == expected.count,
      result.prefix(64 * 512) == expected.prefix(64 * 512),
      result[(72 * 512)...] == expected[(72 * 512)...]
    else { throw Failure("DSM trace, extent or adjacent backing bytes did not match") }
  } else if result != expected {
    throw Failure("NVMe persisted the wrong blocks")
  }
}
