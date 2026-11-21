import TarwinBlockWire
import TarwinIPC

func unitLimits(_ descriptor: [UInt8], _ lun: UInt8, mode: UInt8 = 0) throws -> BlockLimits {
  guard descriptor.count >= 19, Int(descriptor[0]) == descriptor.count, descriptor[1] == 2,
    descriptor[2] == lun, descriptor[3] == 1, (9...12).contains(descriptor[10]), descriptor[5] <= 2,
    let limits = BlockLimits(
      capacity: descriptor.be(11, 8), blockBytes: 1 << descriptor[10], maxVectors: 32,
      flush: true, fua: mode & 0x10 != 0, discard: false, zero: false,
      readOnly: descriptor[5] != 0 || mode & 0x80 != 0)
  else { throw UFSError.configuration }
  return limits
}

private func query(_ t: Transfer, op: UInt8, id: UInt8, index: UInt8 = 0) throws -> [UInt8] {
  var req = [UInt8](repeating: 0, count: 32)
  req[0] = 0x16
  req[5] = op == 6 ? 0x81 : 1
  req[12] = op
  req[13] = id
  req[14] = index
  if op == 1 { req[19] = 0xff }
  let r = try t.sync(req, expect: 0x36)
  guard r[6] == 0 else { throw UFSError.command }
  guard r[12..<16] == req[12..<16], r[5] == req[5], r.be(18, 2) == r.be(10, 2) else {
    throw UFSError.malformed
  }
  return r
}

private func descriptor(_ t: Transfer, id: UInt8, index: UInt8 = 0) throws -> [UInt8] {
  let r = try query(t, op: 1, id: id, index: index)
  let n = Int(r.be(10, 2))
  guard (2...255).contains(n), Int(r[32]) == n, r[33] == id else { throw UFSError.malformed }
  return Array(r[32..<32 + n])
}

func scsiRequest(lun: UInt8, cdb: [UInt8], bytes: UInt32 = 0, read: Bool = false) -> [UInt8] {
  precondition(cdb.count == 16)
  var req = [UInt8](repeating: 0, count: 32)
  req[0] = 1
  req[1] = bytes == 0 ? 0 : read ? 0x40 : 0x20
  req[2] = lun
  req.field(12, UInt64(bytes), 4, big: true)
  req.replaceSubrange(16..<32, with: cdb)
  return req
}
func diskCommand(_ r: BlockRequest) throws -> [UInt8] {
  var cdb = [UInt8](repeating: 0, count: 16)
  switch r.op {
  case .flush: cdb[0] = 0x35
  case .read, .write, .fua:
    if r.op == .fua { cdb[1] = 8 }
    guard r.blocks <= UInt32.max else { throw UFSError.configuration }
    if r.lba + (r.blocks - 1) <= UInt32.max, r.blocks <= UInt16.max {
      cdb[0] = r.op == .read ? 0x28 : 0x2a
      cdb.field(2, r.lba, 4, big: true)
      cdb.field(7, r.blocks, 2, big: true)
    } else {
      cdb[0] = r.op == .read ? 0x88 : 0x8a
      cdb.field(2, r.lba, 8, big: true)
      cdb.field(10, r.blocks, 4, big: true)
    }
  default: throw UFSError.configuration
  }
  return cdb
}

func exactSCSISuccess(_ r: [UInt8]) -> Bool {
  r[6] == 0 && r[7] == 0 && r[1] & 0x60 == 0 && r.be(12, 4) == 0
}
private func senseKey(_ r: [UInt8]) -> UInt8? {
  guard r[7] == 2, r.be(32, 2) >= 3, r.be(10, 2) == r.be(32, 2) + 2 else { return nil }
  switch r[34] & 0x7f {
  case 0x70, 0x71: return r[36] & 15
  case 0x72, 0x73: return r[35] & 15
  default: return nil
  }
}
func validateCapacity(_ limits: BlockLimits, _ data: [UInt8]) throws {
  guard data.count == 32, data.be(0, 8) == limits.capacity - 1,
    data.be(8, 4) == UInt64(limits.blockBytes), data[12] & 1 == 0
  else { throw UFSError.configuration }
}

/// One polled, serially owned block queue. Retain every DMA grant until
/// a matching completion or a positive controller and IOMMU drain.
public final class UFSController {
  public let limits: BlockLimits, epoch: UInt64, lun: UInt8
  private let transfer: Transfer
  private var token: UInt64?
  private init(_ transfer: Transfer, _ limits: BlockLimits, _ epoch: UInt64, _ lun: UInt8) {
    self.transfer = transfer
    self.limits = limits
    self.epoch = epoch
    self.lun = lun
  }
  public static func start(
    _ io: any UFSAccess, pages: UFSPages, lun: UInt8, epoch: UInt64, timeoutNs: UInt64
  ) throws -> UFSController {
    guard epoch != 0, lun < 0x80 else { throw UFSError.configuration }
    let t = Transfer(io, pages, timeoutNs)
    try t.startLink()
    let nop = try t.sync(.init(repeating: 0, count: 32), expect: 0x20)
    guard nop[6] == 0 else { throw UFSError.command }
    _ = try query(t, op: 6, id: 1)
    let start = io.nowNs()
    while try query(t, op: 5, id: 1).be(20, 4) != 0 {
      guard io.nowNs() &- start < timeoutNs else { throw UFSError.timeout }
      io.pause()
    }
    let device = try descriptor(t, id: 0)
    guard device.count >= 18, device[6] > 0, device.be(16, 2) >> 8 == 4 else {
      throw UFSError.configuration
    }
    let unit = try descriptor(t, id: 2, index: lun)
    let geometry = try unitLimits(unit, lun)
    // A fresh LU can report Unit Attention on the first TEST UNIT READY.
    let ready = scsiRequest(lun: lun, cdb: .init(repeating: 0, count: 16))
    var status = try t.sync(ready, expect: 0x21)
    if senseKey(status) == 6 {
      status = try t.sync(ready, expect: 0x21)
    }
    guard exactSCSISuccess(status) else { throw UFSError.command }
    var cdb = [UInt8](repeating: 0, count: 16)
    cdb[0] = 0x9e
    cdb[1] = 0x10
    cdb[13] = 32
    let capacity = try t.readControl(lun: lun, cdb: cdb, bytes: 32)
    guard exactSCSISuccess(capacity.response) else { throw UFSError.command }
    try validateCapacity(geometry, capacity.data)
    // MODE SENSE(10) caching page; only its eight-byte header is required.
    cdb = [UInt8](repeating: 0, count: 16)
    cdb[0] = 0x5a
    cdb[1] = 8
    cdb[2] = 8
    cdb[8] = 8
    let mode = try t.readControl(lun: lun, cdb: cdb, bytes: 8)
    let flags: UInt8
    if exactSCSISuccess(mode.response) {
      guard mode.data.be(0, 2) >= 6 else { throw UFSError.malformed }
      flags = mode.data[3]
    } else if senseKey(mode.response) == 5 {
      flags = 0
    } else {
      throw UFSError.command
    }
    return UFSController(t, try unitLimits(unit, lun, mode: flags), epoch, lun)
  }
  public func submit(
    _ record: borrowing RingRecord, allows: (UInt64, UInt64, Bool) -> Bool,
    readVector: (UInt64) -> BlockDmaVector?
  ) throws {
    guard token == nil else { throw UFSError.busy }
    guard let r = BlockRequest(record: record, epoch: epoch, queue: 0), limits.supports(r) else {
      throw UFSError.configuration
    }
    let bytes = r.blocks.multipliedReportingOverflow(by: UInt64(limits.blockBytes))
    guard !bytes.overflow, bytes.partialValue <= 32 * 262144 else { throw UFSError.configuration }
    let cdb = try diskCommand(r)
    var spans = [BlockDmaVector]()
    if r.payload.vectors > 0 {
      let length = UInt64(r.payload.vectors) * 16
      guard transfer.pages.permits(r.payload.list, length), allows(r.payload.list, length, false)
      else { throw UFSError.configuration }
      for i in 0..<r.payload.vectors {
        guard let v = readVector(r.payload.list + UInt64(i) * 16),
          spans.allSatisfy({ p in
            p.address <= v.address
              ? v.address - p.address >= UInt64(p.bytes) : p.address - v.address >= UInt64(v.bytes)
          })
        else { throw UFSError.configuration }
        spans.append(v)
      }
      guard
        spans.withUnsafeBufferPointer({ limits.checkVectors(r, snapshot: $0, validate: allows) })
      else { throw UFSError.configuration }
    }
    try transfer.submit(
      scsiRequest(lun: lun, cdb: cdb, bytes: UInt32(bytes.partialValue), read: r.op == .read),
      expect: 0x21, spans: spans)
    token = r.id
  }
  public func poll() throws -> BlockCompletion? {
    guard let id = token, let r = try transfer.poll() else { return nil }
    self.token = nil
    let ok = exactSCSISuccess(r)
    return BlockCompletion(id: id, epoch: epoch, queue: 0, status: ok ? .ok : .media)
  }
  public func stop() throws {
    guard token == nil else { throw UFSError.busy }
    try transfer.stop()
  }
}
