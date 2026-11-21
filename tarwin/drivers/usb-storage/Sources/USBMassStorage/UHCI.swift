/// DeviceKit adapter for a cold, exclusively assigned PCI UHCI function.
/// Firmware ownership is already released. The frame, schedule and bounce
/// pages are coherent and pinned in this function's isolated 32-bit domain.
/// All I/O on this worker is serialized. Reads acquire and writes release
/// device-visible changes; access failure, including hot removal, must throw.
public protocol UHCITransport: AnyObject {
  func read16(_ offset: UInt16) throws -> UInt16
  func write16(_ offset: UInt16, _ value: UInt16) throws
  func write32(_ offset: UInt16, _ value: UInt32) throws
  func loadDMA(_ address: UInt32, count: Int) throws -> [UInt8]
  /// Single aligned, coherent little-endian status word; never a torn byte snapshot.
  func loadStatus(_ address: UInt32) throws -> UInt32
  func storeDMA(_ address: UInt32, _ bytes: [UInt8]) throws
  func delay(milliseconds: Int) throws
}

public struct UHCIPages {
  let frames, schedule, bounce: UInt32
  public init?(frames: UInt32, schedule: UInt32, bounce: UInt32) {
    guard (frames | schedule | bounce) & 4095 == 0,
      frames != schedule, frames != bounce, schedule != bounce
    else { return nil }
    self.frames = frames
    self.schedule = schedule
    self.bounce = bounce
  }
}

/// Full-speed, polled, single-device root bus. Each packet has one TD; the
/// controller must acknowledge halt before its descriptors can be rewritten.
/// A failed halt does NOT release the domain or any page.
public final class UHCIStorageBus: USBStoragePipes {
  private enum Phase { case cold, enumerating, ready, stopped }
  private enum PipeError: Error { case stall }
  private let io: any UHCITransport, pages: UHCIPages, port: UInt16
  private var phase = Phase.cold, controlPacket = 8, address: UInt32 = 0
  private var selected: BulkInterface?
  private var inToggle = false, outToggle = false
  private var acceptedController = false

  /// Caller keeps the exclusive slot, domain and pages until it has stopped
  /// bus mastering and drained DMA, even if configure() or stop() fails.
  public init?(io: any UHCITransport, pages: UHCIPages, rootPort: Int) {
    guard (0...1).contains(rootPort) else { return nil }
    self.io = io
    self.pages = pages
    self.port = UInt16(0x10 + 2 * rootPort)
  }

  private func halt() throws {
    try io.write16(0, 0xc0)
    for _ in 0..<10 {
      let status = try io.read16(2)
      guard status & 0x18 == 0 else { throw StorageError.transport }
      if status & 0x20 != 0 { return }
      try io.delay(milliseconds: 1)
    }
    throw StorageError.transport
  }
  public func stop() throws {
    guard acceptedController else { throw StorageError.interface }
    phase = .stopped
    try halt()
  }

  public func configure(interface number: UInt8 = 0) throws -> BulkInterface {
    guard phase == .cold else { throw StorageError.interface }
    phase = .enumerating
    do {
      guard try io.read16(0) & 1 == 0, try io.read16(2) & 0x38 == 0x20,
        try io.read16(port) & 0x101 == 1,
        try io.read16(port == 0x10 ? 0x12 : 0x10) & 4 == 0
      else { throw StorageError.interface }
      acceptedController = true
      try io.write16(4, 0)
      try io.write16(port, 0xa)  // Ack connect and enable changes before debounce.
      try io.delay(milliseconds: 100)
      guard try io.read16(port) & 0x103 == 1 else { throw StorageError.detached }
      try io.write16(port, 0x200)
      try io.delay(milliseconds: 55)
      try io.write16(port, 0)
      try io.delay(milliseconds: 11)
      try io.write16(port, 4)
      try io.delay(milliseconds: 1)
      // Never acknowledge a connect change since the reset.
      try io.write16(port, 4 | 8)
      try connected()
      let link = Self.word(pages.schedule | 2)
      let table = Array(repeating: link, count: 1024).flatMap { $0 }
      try io.storeDMA(pages.frames, table)
      try io.storeDMA(pages.schedule, Self.word(1) + Self.word(1))
      try io.write32(8, pages.frames)
      try io.write16(6, 0)

      let device = try control([0x80, 6, 0, 1, 0, 0, 8, 0])
      guard device.count == 8, device[0] == 18, device[1] == 1,
        [8, 16, 32, 64].contains(device[7])
      else { throw StorageError.interface }
      controlPacket = Int(device[7])
      _ = try control([0, 5, 1, 0, 0, 0, 0, 0])
      try io.delay(milliseconds: 2)
      address = 1
      let hdr = try control([0x80, 6, 0, 2, 0, 0, 9, 0])
      guard hdr.count == 9, hdr[0] == 9, hdr[1] == 2, hdr[5] != 0,
        (9...4096).contains(Int(hdr[2]) | Int(hdr[3]) << 8)
      else { throw StorageError.interface }
      let d = try control([0x80, 6, 0, 2, 0, 0, hdr[2], hdr[3]])
      guard d.prefix(9).elementsEqual(hdr) else { throw StorageError.interface }
      let intf = try BulkInterface(configuration: d, number: number)
      guard intf.inputPacket <= 64, intf.outputPacket <= 64 else { throw StorageError.unsupported }
      _ = try control([0, 9, hdr[5], 0, 0, 0, 0, 0])
      selected = intf
      phase = .ready
      return intf
    } catch {
      // The function was cold or never ours to run. A packet failure has
      // already attempted to halt if it could have published a descriptor.
      phase = .stopped
      throw error
    }
  }

  private static func word(_ n: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: n >> (8 * $0)) }
  }
  private func connected() throws {
    // Connected, enabled, full speed; no new connection or enable change.
    guard try io.read16(port) & 0x10f == 5 else { throw StorageError.detached }
  }
  private func packet(_ pid: UInt32, _ ep: UInt8, _ toggle: Bool, _ n: Int, _ data: [UInt8])
    throws -> (Int, [UInt8])
  {
    guard phase == .ready || phase == .enumerating else { throw StorageError.detached }
    do {
      try connected()
      guard try io.read16(2) & 0x38 == 0x20 else { throw StorageError.transport }
      if !data.isEmpty { try io.storeDMA(pages.bounce, data) }
      let td = pages.schedule + 16
      let token =
        pid | address << 8 | UInt32(ep & 15) << 15 | (toggle ? 1 << 19 : 0)
        | UInt32((n - 1) & 2047) << 21
      try io.storeDMA(td, [1, 0x1880_07ff, token, pages.bounce].flatMap(Self.word))
      try io.storeDMA(pages.schedule + 4, Self.word(td))
      try io.write16(2, 3)
      try io.write16(0, 0xc1)
      for _ in 0..<250 {
        try io.delay(milliseconds: 1)
        guard try io.read16(2) & 0x18 == 0 else { throw StorageError.transport }
        let s = try io.loadStatus(td + 4)
        if s & 0x800000 != 0 { continue }
        try halt()
        try connected()
        if s & 0x400000 != 0 { throw PipeError.stall }
        let actual = Int((s + 1) & 0x7ff)
        guard s & 0x370000 == 0, actual <= n, pid == 0x69 || actual == n
        else { throw StorageError.transport }
        let input = (pid == 0x69 && actual > 0) ? try io.loadDMA(pages.bounce, count: actual) : []
        guard input.count == (pid == 0x69 ? actual : 0) else { throw StorageError.transport }
        return (actual, input)
      }
      throw StorageError.transport
    } catch PipeError.stall { throw PipeError.stall } catch {
      phase = .stopped
      try? halt()
      throw error
    }
  }
  private func control(_ setup: [UInt8]) throws -> [UInt8] {
    _ = try packet(0x2d, 0, false, 8, setup)
    let n = Int(setup[6]) | Int(setup[7]) << 8
    let input = setup[0] & 0x80 != 0
    var data: [UInt8] = []
    var odd = true
    while data.count < n {
      let want = min(controlPacket, n - data.count)
      let (got, part) = try packet(0x69, 0, odd, want, [])
      data += part
      odd.toggle()
      if got < want { break }
    }
    _ = try packet(input ? 0xe1 : 0x69, 0, true, 0, [])
    return data
  }
  private func claimed(_ number: UInt8) throws {
    guard phase == .ready, selected?.number == number else { throw StorageError.detached }
  }
  public func getMaxLUN(interface: UInt8) throws -> UInt8? {
    try claimed(interface)
    do {
      let r = try control([0xa1, 0xfe, 0, 0, interface, 0, 1, 0])
      guard r.count == 1 else { throw StorageError.transport }
      return r[0]
    } catch PipeError.stall { return nil }
  }
  public func massStorageReset(interface: UInt8) throws {
    try claimed(interface)
    _ = try control([0x21, 0xff, 0, 0, interface, 0, 0, 0])
  }
  public func clearHalt(_ ep: UInt8) throws {
    guard phase == .ready, let i = selected, ep == i.input || ep == i.output
    else { throw StorageError.interface }
    _ = try control([2, 1, 0, 0, ep, 0, 0, 0])
    if ep == i.input { inToggle = false } else { outToggle = false }
  }
  public func bulkIn(_ ep: UInt8, count: Int) throws -> (bytes: [UInt8], stalled: Bool) {
    guard phase == .ready, let i = selected, ep == i.input, (0...BulkOnly.limit).contains(count)
    else { throw StorageError.interface }
    var result: [UInt8] = []
    result.reserveCapacity(count)
    while result.count < count {
      let n = min(count - result.count, i.inputPacket)
      do {
        let (actual, b) = try packet(0x69, ep, inToggle, n, [])
        result += b
        inToggle.toggle()
        if actual < n { break }
      } catch PipeError.stall { return (result, true) }
    }
    return (result, false)
  }
  public func bulkOut(_ ep: UInt8, bytes: [UInt8]) throws -> (sent: Int, stalled: Bool) {
    guard phase == .ready, let i = selected, ep == i.output, bytes.count <= BulkOnly.limit
    else { throw StorageError.interface }
    var sent = 0
    while sent < bytes.count {
      let n = min(bytes.count - sent, i.outputPacket)
      do {
        _ = try packet(0xe1, ep, outToggle, n, Array(bytes[sent..<sent + n]))
        sent += n
        outToggle.toggle()
      } catch PipeError.stall { return (sent, true) }
    }
    return (sent, false)
  }
}
