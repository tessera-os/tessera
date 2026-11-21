import TarwinBlockWire

/// DeviceKit supplies ordered BAR access and coherent, retained DMA mappings.
public protocol UFSAccess: AnyObject {
  var barBytes: UInt64 { get }
  func register(_ offset: UInt32) -> UInt32
  func setRegister(_ offset: UInt32, _ value: UInt32)
  func copyToDMA(_ address: UInt64, _ bytes: [UInt8]) -> Bool
  func copyFromDMA(_ address: UInt64, count: Int) -> [UInt8]?
  func acquire()
  func release()
  func nowNs() -> UInt64
  func pause()
}

public enum UFSError: Error, Equatable {
  case configuration, busy, timeout, device, malformed, command
}

public struct UFSPages {
  let list: UInt64, command: UInt64
  public init?(transferList: UInt64, command: UInt64) {
    guard transferList != command, transferList != 0, command != 0,
      (transferList | command) & 4095 == 0
    else { return nil }
    list = transferList
    self.command = command
  }
  func permits(_ a: UInt64, _ n: UInt64) -> Bool {
    guard a != 0, n != 0, n - 1 <= UInt64.max - a else { return false }
    return [list, command].allSatisfy { a >= $0 ? a - $0 >= 4096 : $0 - a >= n }
  }
}

extension Array where Element == UInt8 {
  func be(_ at: Int, _ count: Int) -> UInt64 {
    self[at..<at + count].reduce(0) { ($0 << 8) | UInt64($1) }
  }
  mutating func field(_ at: Int, _ value: UInt64, _ n: Int, big: Bool = false) {
    for i in 0..<n {
      self[at + (big ? n - 1 - i : i)] = UInt8(truncatingIfNeeded: value >> (8 * i))
    }
  }
}

enum Reg {
  static let cap: UInt32 = 0, version: UInt32 = 8, status: UInt32 = 0x20,
    interruptEnable: UInt32 = 0x24,
    host: UInt32 = 0x30, enable: UInt32 = 0x34, listBase: UInt32 = 0x50, bell: UInt32 = 0x58,
    run: UInt32 = 0x60,
    completed: UInt32 = 0x64, uic: UInt32 = 0x90
  // UIC error/link loss, device, UTP, controller, system bus or crypto fault.
  static let faults: UInt32 = 0x71884
}

/// Exclusively owns slot zero in single-doorbell mode. A malformed completion
/// or timeout permanently stops reuse, including reuse of the command page.
final class Transfer {
  let io: any UFSAccess, pages: UFSPages, timeoutNs: UInt64
  private var active: (type: UInt8, lun: UInt8, start: UInt64)?
  private(set) var stopped = false
  init(_ io: any UFSAccess, _ pages: UFSPages, _ timeout: UInt64) {
    self.io = io
    self.pages = pages
    timeoutNs = timeout
  }
  func wait(_ probe: () -> Bool) throws {
    let start = io.nowNs()
    while !probe() {
      if io.register(Reg.status) & Reg.faults != 0 { throw UFSError.device }
      guard io.nowNs() &- start < timeoutNs else { throw UFSError.timeout }
      io.pause()
    }
  }
  func startLink() throws {
    guard timeoutNs > 0, io.barBytes >= 0xa0, io.register(Reg.version) >> 8 == 4,
      io.register(Reg.cap) & (1 << 29) == 0, io.register(Reg.enable) & 1 == 0
    else { throw UFSError.configuration }
    if io.register(Reg.cap) & (1 << 24) == 0 && max(pages.list, pages.command) > UInt32.max {
      throw UFSError.configuration
    }
    io.setRegister(Reg.enable, 1)
    try wait { io.register(Reg.enable) & 1 != 0 && io.register(Reg.host) & 8 != 0 }
    io.setRegister(Reg.interruptEnable, 0)
    io.setRegister(Reg.status, 1 << 10)
    for at: UInt32 in [0x94, 0x98, 0x9c] { io.setRegister(at, 0) }
    io.setRegister(Reg.uic, 0x16)
    try wait { io.register(Reg.status) & (1 << 10) != 0 }
    guard io.register(0x98) & 255 == 0, io.register(Reg.host) & 3 == 3, io.register(Reg.bell) == 0,
      io.register(Reg.run) & 1 == 0
    else { throw UFSError.device }
    io.setRegister(Reg.status, 1 << 10)
    io.setRegister(Reg.listBase, UInt32(truncatingIfNeeded: pages.list))
    io.setRegister(Reg.listBase + 4, UInt32(pages.list >> 32))
    io.setRegister(Reg.run, 1)
    try wait { io.register(Reg.run) & 1 == 1 }
  }
  func submit(_ req: [UInt8], expect: UInt8, spans: [BlockDmaVector] = []) throws {
    try post(req, expect: expect, spans: spans, control: false)
  }
  private func post(_ req: [UInt8], expect: UInt8, spans: [BlockDmaVector], control: Bool) throws {
    guard !stopped, active == nil else { throw stopped ? UFSError.device : .busy }
    guard req.count == 32, spans.count <= 32 else { throw UFSError.configuration }
    guard io.register(Reg.status) & Reg.faults == 0, io.register(Reg.bell) == 0,
      io.register(Reg.completed) == 0,
      io.register(Reg.run) & 1 == 1, io.register(Reg.host) & 3 == 3
    else {
      stopped = true
      throw UFSError.device
    }
    var desc = [UInt8](repeating: 0, count: 32)
    desc[3] = 0x11 | (req[1] & 0x60) >> 4  // command type, interrupt, data direction
    desc[8] = 15
    desc.field(16, pages.command, 8)
    desc.field(24, 128, 2)
    desc.field(26, 128, 2)  // 512-byte response at byte 512
    desc.field(28, UInt64(spans.count), 2)
    desc.field(30, 256, 2)
    var prdt = [UInt8](repeating: 0, count: 16 * spans.count)
    for (i, v) in spans.enumerated() {
      guard v.address & 3 == 0, v.bytes & 3 == 0, v.bytes > 0, v.bytes <= 262144,
        control
          ? spans.count == 1 && v.address == pages.command + 2048 && v.bytes <= 2048
          : pages.permits(v.address, UInt64(v.bytes)),
        io.register(Reg.cap) & (1 << 24) != 0 || v.address + UInt64(v.bytes - 1) <= UInt32.max
      else { throw UFSError.configuration }
      prdt.field(i * 16, v.address, 8)
      prdt.field(i * 16 + 12, UInt64(v.bytes - 1), 4)
    }
    guard io.copyToDMA(pages.command, req),
      io.copyToDMA(pages.command + 512, .init(repeating: 0, count: 512)),
      prdt.isEmpty || io.copyToDMA(pages.command + 1024, prdt), io.copyToDMA(pages.list, desc)
    else { throw UFSError.configuration }
    active = (expect, req[2], io.nowNs())
    io.release()
    io.setRegister(Reg.bell, 1)
  }
  func poll() throws -> [UInt8]? {
    guard !stopped else { throw UFSError.device }
    guard let a = active else { return nil }
    guard io.register(Reg.status) & Reg.faults == 0, io.register(Reg.host) & 3 == 3,
      io.register(Reg.run) & 1 == 1
    else {
      stopped = true
      throw UFSError.device
    }
    if io.register(Reg.bell) & 1 != 0 {
      guard io.nowNs() &- a.start < timeoutNs else {
        stopped = true
        throw UFSError.timeout
      }
      return nil
    }
    guard io.register(Reg.completed) == 1 else {
      stopped = true
      throw UFSError.malformed
    }
    io.acquire()
    guard let status = io.copyFromDMA(pages.list + 8, count: 4), status.count == 4,
      status[0] & 15 == 0,
      let r = io.copyFromDMA(pages.command + 512, count: 512), r.count == 512, r[0] == a.type,
      r[2] == a.lun, r[3] == 0,
      r[8] == 0, r.be(10, 2) <= 480,
      a.type != 0x21 || r.be(10, 2) == 0 || r.be(10, 2) >= 2 + r.be(32, 2)
    else {
      stopped = true
      throw UFSError.malformed
    }
    active = nil
    io.setRegister(Reg.completed, 1)
    io.setRegister(Reg.status, 1)
    return r
  }
  func sync(_ req: [UInt8], expect: UInt8) throws -> [UInt8] {
    try submit(req, expect: expect)
    return try collect()
  }
  private func collect() throws -> [UInt8] {
    while true {
      if let r = try poll() { return r }
      io.pause()
    }
  }
  // Controller discovery reads into an otherwise unused slice of the private
  // command page, after the response and every possible PRD entry.
  func readControl(lun: UInt8, cdb: [UInt8], bytes: UInt32) throws -> (
    response: [UInt8], data: [UInt8]
  ) {
    guard !stopped, active == nil else { throw UFSError.busy }
    guard bytes > 0, bytes <= 2048, bytes & 3 == 0 else { throw UFSError.configuration }
    let address = pages.command + 2048
    guard io.copyToDMA(address, .init(repeating: 0, count: Int(bytes))) else {
      throw UFSError.configuration
    }
    try post(
      scsiRequest(lun: lun, cdb: cdb, bytes: bytes, read: true), expect: 0x21,
      spans: [BlockDmaVector(address: address, bytes: bytes)], control: true)
    let response = try collect()
    guard let data = io.copyFromDMA(address, count: Int(bytes)), data.count == Int(bytes) else {
      throw UFSError.device
    }
    return (response, data)
  }
  func stop() throws {
    guard !stopped, active == nil else { throw UFSError.busy }
    stopped = true
    io.setRegister(Reg.run, 0)
    try wait { io.register(Reg.run) & 1 == 0 && io.register(Reg.bell) == 0 }
    io.setRegister(Reg.enable, 0)
    try wait { io.register(Reg.enable) & 1 == 0 }
  }
}
