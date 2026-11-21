import KCore

/// One locality-zero TIS/FIFO window. The platform binds these operations
/// to ordered device accesses and serializes all commands, including across CPUs.
public protocol TPMFIFORegisters {
  mutating func access() -> UInt8
  mutating func setAccess(_ value: UInt8)
  mutating func status() -> UInt32
  mutating func setStatus(_ value: UInt8)
  mutating func receive() -> UInt8
  mutating func send(_ value: UInt8)
}

/// Early kernel transport; no EFI services, interrupts, DMA, locality seizure,
/// response retry or dynamic storage. A transport failure is terminal: even
/// a lost acknowledgement after GO may mean the PCR was extended.
public struct TPMFIFO<R: TPMFIFORegisters>: TpmPort {
  private var io: R
  private let bytes: UnsafeMutableRawBufferPointer
  private let polls: Int
  public private(set) var stopped = false

  /// The caller owns the register interface and pins the disjoint command
  /// scratch until the last transaction. The poll limit bounds one command.
  @unsafe public init?(registers: R, scratch: UnsafeMutableRawBufferPointer, pollLimit: Int) {
    guard (10...4096).contains(scratch.count), pollLimit > 0 else { return nil }
    self.io = registers
    self.bytes = scratch
    self.polls = pollLimit
  }

  public func byteCount() -> UInt64 { UInt64(bytes.count) }
  public func byteAt(_ offset: UInt64) -> UInt8 { bytes[Int(offset)] }
  public mutating func putByte(_ offset: UInt64, value: UInt8) { bytes[Int(offset)] = value }

  private mutating func wait(
    _ mask: UInt32, _ wanted: UInt32, burst: Bool = false,
    left: inout Int
  ) -> UInt32? {
    while left > 0 {
      left -= 1
      let s = io.status()
      if s == .max { return nil }
      if s & mask == wanted && (!burst || s & 0x00ff_ff00 != 0) { return s }
    }
    return nil
  }

  public mutating func submit(_ commandSize: UInt64) -> UInt64 {
    guard !stopped, commandSize >= 10, commandSize <= byteCount() else { return 0 }
    let length = Int(commandSize)
    func declared(_ b: UnsafeMutableRawBufferPointer) -> Int {
      (Int(b[2]) << 24) | (Int(b[3]) << 16) | (Int(b[4]) << 8) | Int(b[5])
    }
    guard declared(bytes) == length else { return 0 }
    stopped = true
    var left = polls
    var a = io.access()
    guard a != 0xff, a & 0x80 != 0 else { return 0 }
    if a & 0x20 == 0 {
      io.setAccess(2)
      repeat {
        guard left > 0 else { return 0 }
        left -= 1
        a = io.access()
        guard a != 0xff else { return 0 }
      } while a & 0xa0 != 0xa0
    }
    defer { io.setAccess(0x20) }
    io.setStatus(0x40)
    guard wait(0x40, 0x40, left: &left) != nil else { return 0 }
    var at = 0
    while at < length - 1 {
      guard let s = wait(0, 0, burst: true, left: &left) else { return 0 }
      let end = min(length - 1, at + Int((s >> 8) & 0xffff))
      while at < end {
        io.send(bytes[at])
        at += 1
      }
      guard let s = wait(0x80, 0x80, left: &left), s & 8 != 0 else { return 0 }
    }
    guard wait(0x88, 0x88, burst: true, left: &left) != nil else { return 0 }
    io.send(bytes[at])
    guard let final = wait(0x80, 0x80, left: &left), final & 8 == 0 else { return 0 }
    io.setStatus(0x20)  // Exactly one GO.
    var expected = 10
    at = 0
    while at < expected {
      guard let s = wait(0x90, 0x90, burst: true, left: &left) else { return 0 }
      let end = min(expected, at + Int((s >> 8) & 0xffff))
      while at < end {
        bytes[at] = io.receive()
        at += 1
      }
      if at == 10 {
        expected = declared(bytes)
        guard expected >= 10, expected <= bytes.count else { return 0 }
      }
    }
    guard let s = wait(0x80, 0x80, left: &left), s & 0x10 == 0 else { return 0 }
    io.setStatus(0x40)
    stopped = false
    return UInt64(at)
  }
}
