import TarwinBlockWire
import TarwinIPC

/// NVM command set, polling, one admin and one I/O queue. Caller serializes
/// all methods; after timeout/fault keep every pin until the slot drains DMA.
public struct NVMeController: ~Copyable {
  private let io: any NVMeAccess, pages: NVMePages
  private var queue: Queue
  public let namespace: UInt32, limits: BlockLimits, epoch: UInt64
  private var stopped = false
  private init(
    io: any NVMeAccess, pages: NVMePages, queue: consuming Queue, namespace: UInt32,
    limits: BlockLimits, epoch: UInt64
  ) {
    self.io = io
    self.pages = pages
    self.queue = consume queue
    self.namespace = namespace
    self.limits = limits
    self.epoch = epoch
  }
  /// Cold start only; no implicit reset of an enabled or shared controller.
  /// The caller selects one active namespace returned by Identify (first
  /// page of the active list). Fail rather than silently bind a different ID.
  public static func start(
    _ io: any NVMeAccess, pages: NVMePages, depth: Int, epoch: UInt64,
    select: ([UInt32]) -> UInt32?
  ) throws -> NVMeController {
    guard epoch != 0, (2...64).contains(depth), io.barBytes >= 0x1010 else {
      throw NVMeError.configuration
    }
    let cap = UInt64(io.register(0)) | UInt64(io.register(4)) << 32
    let stride = UInt64(4) << ((cap >> 32) & 15)
    guard cap & (1 << 37) != 0, cap >> 48 & 15 == 0, UInt64(depth - 1) <= cap & 65535,
      0x1000 + 3 * stride + 4 <= io.barBytes, io.register(8) >= 0x10100,
      io.register(20) & 1 == 0, io.register(28) & 3 == 0
    else { throw NVMeError.configuration }
    let timeout = max(UInt64(1), (cap >> 24) & 255) * 500_000_000
    for base in pages.pages { for at in strideWords { io.store(base + at, 0) } }
    io.release()
    io.setRegister(12, .max)  // mask all vectors for polled queues
    io.setRegister(36, UInt32(depth - 1) * 0x10001)
    for (reg, addr) in [(UInt64(40), pages.aSQ), (48, pages.aCQ)] {
      io.setRegister(reg, UInt32(truncatingIfNeeded: addr))
      io.setRegister(reg + 4, UInt32(addr >> 32))
    }
    io.setRegister(20, 0x0046_0001)
    let then = io.nowNs()
    while true {
      let status = io.register(28)
      guard status & 2 == 0 else { throw NVMeError.device }
      if status & 1 != 0 { break }
      guard io.nowNs() &- then < timeout else { throw NVMeError.timeout }
      io.pause()
    }
    var admin = Queue(id: 0, depth: depth, sq: pages.aSQ, cq: pages.aCQ, stride: stride)
    func execute(_ cmd: Command) throws {
      try admin.submit(cmd, 1, io)
      let then = io.nowNs()
      while true {
        guard io.register(28) & 3 == 1 else { throw NVMeError.device }
        if let done = try admin.poll(io) {
          guard done.status == 0 else { throw NVMeError.command(done.status) }
          return
        }
        guard io.nowNs() &- then < 5_000_000_000 else { throw NVMeError.timeout }
        io.pause()
      }
    }
    func identify(_ cns: UInt32, _ ns: UInt32) throws {
      var cmd = Command(6)
      cmd.ns = ns
      cmd.prp1 = pages.scratch
      cmd.d10 = cns
      try execute(cmd)
    }
    try identify(1, 0)
    let sizes = io.load(pages.scratch + 512)
    guard sizes & 15 <= 6, (sizes >> 4) & 15 >= 6, (sizes >> 8) & 15 <= 4, (sizes >> 12) & 15 >= 4,
      io.load(pages.scratch + 516) > 0
    else { throw NVMeError.configuration }
    try identify(2, 0)
    var ids = [UInt32]()
    for at in strideWords {
      let n = io.load(pages.scratch + at)
      if n == 0 { break }
      guard n != .max, n > (ids.last ?? 0) else { throw NVMeError.protocolFault }
      ids.append(n)
    }
    guard let ns = select(ids), ids.contains(ns) else { throw NVMeError.configuration }
    try identify(0, ns)
    let blocks = UInt64(io.load(pages.scratch)) | UInt64(io.load(pages.scratch + 4)) << 32
    let capacity = UInt64(io.load(pages.scratch + 8)) | UInt64(io.load(pages.scratch + 12)) << 32
    let caps = io.load(pages.scratch + 24)
    let fmt = (caps >> 16) & 255
    guard capacity != 0, capacity <= blocks, fmt < 16, fmt <= (caps >> 8) & 255,
      io.load(pages.scratch + 28) & 0x0700 == 0
    else {
      throw NVMeError.configuration
    }
    let format = io.load(pages.scratch + 128 + UInt64(fmt) * 4)
    let shift = (format >> 16) & 255
    guard (9...12).contains(shift), format & 65535 == 0,
      let limits = BlockLimits(
        capacity: blocks, blockBytes: 1 << shift, maxVectors: 2, flush: true, fua: true,
        discard: false, zero: false, readOnly: (io.load(pages.scratch + 96) >> 24) & 1 != 0)
    else { throw NVMeError.configuration }
    var number = Command(9)
    number.d10 = 7
    try execute(number)  // request a single pair (zero based)
    var create = Command(5)
    create.prp1 = pages.cq
    create.d10 = UInt32(depth - 1) << 16 | 1
    create.d11 = 1
    try execute(create)
    create = Command(1)
    create.prp1 = pages.sq
    create.d10 = UInt32(depth - 1) << 16 | 1
    create.d11 = 0x1_0001
    try execute(create)
    return NVMeController(
      io: io, pages: pages,
      queue: Queue(id: 1, depth: depth, sq: pages.sq, cq: pages.cq, stride: stride), namespace: ns,
      limits: limits, epoch: epoch)
  }
  /// Caller resolves the validated read-only vector table once, pinning all
  /// granted ranges until completion or positive reset/domain-drain.
  public mutating func submit(
    _ record: borrowing RingRecord, allows: (UInt64, UInt64, Bool) -> Bool,
    readVector: (UInt64) -> BlockDmaVector?
  ) throws {
    guard !stopped, io.register(28) & 3 == 1 else {
      stopped = true
      throw NVMeError.device
    }
    guard let r = BlockRequest(record: record, epoch: epoch, queue: 0), limits.supports(r) else {
      throw NVMeError.configuration
    }
    var cmd = Command(r.op == .read ? 2 : r.op == .flush ? 0 : 1)
    cmd.ns = namespace
    if r.op != .flush {
      let listBytes = UInt64(r.payload.vectors) * 16
      guard r.blocks <= 8192 / UInt64(limits.blockBytes), pages.disjoint(r.payload.list, listBytes),
        allows(r.payload.list, listBytes, false)
      else { throw NVMeError.configuration }
      var spans: [BlockDmaVector] = []
      for i in 0..<r.payload.vectors {
        guard let v = readVector(r.payload.list + UInt64(i) * 16),
          pages.disjoint(v.address, UInt64(v.bytes))
        else { throw NVMeError.configuration }
        spans.append(v)
      }
      guard
        spans.withUnsafeBufferPointer({ limits.checkVectors(r, snapshot: $0, validate: allows) }),
        let prps = pagePointers(spans)
      else { throw NVMeError.configuration }
      cmd.prp1 = prps.0
      cmd.prp2 = prps.1
      cmd.d10 = UInt32(truncatingIfNeeded: r.lba)
      cmd.d11 = UInt32(r.lba >> 32)
      cmd.d12 = UInt32(r.blocks - 1) | (r.op == .fua ? 1 << 30 : 0)
    }
    try queue.submit(cmd, r.id, io)
  }
  public mutating func poll() throws -> BlockCompletion? {
    guard !stopped, io.register(28) & 3 == 1 else {
      stopped = true
      throw NVMeError.device
    }
    guard let done = try queue.poll(io) else { return nil }
    return BlockCompletion(
      id: done.token, epoch: epoch, queue: 0, status: done.status == 0 ? .ok : .media)
  }
  public mutating func shutdown(timeoutNs: UInt64) throws {
    guard !stopped, queue.idle, !queue.poisoned, timeoutNs > 0 else { throw NVMeError.busy }
    stopped = true
    let start = io.nowNs()
    let cc = io.register(20)
    io.setRegister(20, cc | 0x4000)
    while io.register(28) & 12 != 8 {
      guard io.nowNs() &- start < timeoutNs else { throw NVMeError.timeout }
      io.pause()
    }
    io.setRegister(20, 0)
    while io.register(28) & 1 != 0 {
      guard io.nowNs() &- start < timeoutNs else { throw NVMeError.timeout }
      io.pause()
    }
  }
}
private let strideWords = Swift.stride(from: UInt64(0), to: 4096, by: 4)
/// PRP1 may have a dword-aligned offset; PRP2 names a complete second
/// page base, never a PRP list. Two distinct grants may meet at a page edge.
func pagePointers(_ spans: [BlockDmaVector]) -> (UInt64, UInt64)? {
  guard (1...2).contains(spans.count) else { return nil }
  let a = spans[0].address
  let n = UInt64(spans[0].bytes)
  let first = 4096 - (a & 4095)
  guard a != 0, a & 3 == 0, n > 0, n - 1 <= UInt64.max - a else { return nil }
  if spans.count == 1 {
    guard n <= first + 4096 else { return nil }
    return (a, n > first ? a + first : 0)
  }
  let b = spans[1].address
  let m = UInt64(spans[1].bytes)
  guard n == first, b != 0, b & 4095 == 0, b >> 12 != a >> 12, m > 0, m <= 4096 else { return nil }
  return (a, b)
}
