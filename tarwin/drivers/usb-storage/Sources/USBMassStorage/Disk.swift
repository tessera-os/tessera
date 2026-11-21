/// Single serialized driver worker for one exclusively claimed bulk interface.
/// All buffers here are driver-private. Read bytes do not leave the driver until
/// the matching status wrapper and exact logical-block count have been checked.
public struct USBDisk: ~Copyable {
  public let blocks: UInt64, blockBytes: Int
  public let readOnly, forceUnitAccess: Bool
  public let maxDiscardBlocks: UInt32
  private var transport: BulkOnly
  private var offline = false

  public init(pipes: any USBStoragePipes, interface: BulkInterface, lun: UInt8) throws {
    var t = try BulkOnly(pipes, interface, lun: lun)
    let inquiry = try t.run([0x12, 0, 0, 0, 36, 0], .input(36))
    guard inquiry.count >= 36, inquiry[0] == 0, inquiry[4] >= 31 else {
      throw StorageError.unsupported
    }
    // A power-on unit attention is normal. Only retry a harmless readiness
    // check and only after the target has actually reported UNIT ATTENTION.
    do { _ = try t.run([0, 0, 0, 0, 0, 0], .none) } catch StorageError.commandFailed {
      guard try Self.sense(&t) == 6 else { throw StorageError.notReady }
      _ = try t.run([0, 0, 0, 0, 0, 0], .none)
    }
    let cap = try t.run([0x25] + [UInt8](repeating: 0, count: 9), .input(8))
    guard cap.count == 8 else { throw StorageError.shortTransfer }
    var last = big(cap.prefix(4))
    var size = big(cap.suffix(4))
    if last == UInt64(UInt32.max) {
      var cdb = [UInt8](repeating: 0, count: 16)
      cdb[0] = 0x9e
      cdb[1] = 0x10
      cdb[13] = 32
      let wide = try t.run(cdb, .input(32))
      guard wide.count == 32 else { throw StorageError.shortTransfer }
      last = big(wide[0..<8])
      size = big(wide[8..<12])
    }
    guard last != .max, (512...65536).contains(size), size.nonzeroBitCount == 1
    else { throw StorageError.unsupported }
    // DBD, all current mode pages; the four-byte header suffices for WP/DPOFUA.
    let mode = try t.run([0x1a, 8, 0x3f, 0, 4, 0], .input(4))
    guard mode.count == 4, mode[0] >= 3 else { throw StorageError.unsupported }
    let discard = mode[2] & 0x80 == 0 && inquiry[2] >= 5 ? try Self.discardLimit(&t) : 0
    self.blocks = last + 1
    self.blockBytes = Int(size)
    self.readOnly = mode[2] & 0x80 != 0
    self.forceUnitAccess = mode[2] & 0x10 != 0
    maxDiscardBlocks = discard
    self.transport = consume t
  }

  // Only enable UNMAP when both provisioning and block-limits pages say
  // that a single non-empty descriptor is supported. Never infer UNMAP or
  // read-zero-after-discard from a device's capacity or media type.
  private static func discardLimit(_ t: inout BulkOnly) throws -> UInt32 {
    func page(_ code: UInt8, _ t: inout BulkOnly) throws -> [UInt8]? {
      do {
        let data = try t.run([0x12, 1, code, 0, 255, 0], .input(255))
        guard data.count >= 4, data[0] == 0, data[1] == code else { return nil }
        let end = 4 + (Int(data[2]) << 8 | Int(data[3]))
        guard end <= data.count else { return nil }
        return Array(data.prefix(end))
      } catch StorageError.commandFailed {
        guard try Self.sense(&t) == 5 else { throw StorageError.commandFailed }
        return nil
      }
    }
    guard let supported = try page(0, &t)?.dropFirst(4),
      supported.contains(0xb0), supported.contains(0xb2),
      let provision = try page(0xb2, &t), provision.count >= 8, provision[5] & 0x80 != 0,
      let limits = try page(0xb0, &t), limits.count >= 28, big(limits[24..<28]) > 0
    else { return 0 }
    return UInt32(big(limits[20..<24]))
  }

  private static func sense(_ t: inout BulkOnly) throws -> UInt8? {
    let s = try t.run([3, 0, 0, 0, 18, 0], .input(18))
    guard s.count >= 8 else { return nil }
    switch s[0] & 0x7f {
    case 0x70, 0x71: return s[2] & 15
    case 0x72, 0x73: return s[1] & 15
    default: return nil
    }
  }

  private func prepare(_ lba: UInt64, _ count: UInt32, write: Bool, fua: Bool) throws -> (
    [UInt8], Int
  ) {
    guard !offline else { throw StorageError.detached }
    guard count > 0, lba < blocks, UInt64(count) <= blocks - lba,
      count <= BulkOnly.limit / blockBytes
    else { throw StorageError.bounds }
    guard !write || !readOnly else { throw StorageError.readOnly }
    guard !fua || forceUnitAccess else { throw StorageError.unsupported }
    let flags: UInt8 = fua ? 8 : 0
    let cmd: [UInt8]
    if lba + UInt64(count) - 1 <= UInt32.max, count <= UInt16.max {
      cmd = [write ? 0x2a : 0x28, flags] + bytes(lba, 4) + [0] + bytes(UInt64(count), 2) + [0]
    } else {
      cmd = [write ? 0x8a : 0x88, flags] + bytes(lba, 8) + bytes(UInt64(count), 4) + [0, 0]
    }
    return (cmd, Int(count) * blockBytes)
  }

  private mutating func issue(_ cmd: [UInt8], _ transfer: Transfer) throws -> [UInt8] {
    guard !offline else { throw StorageError.detached }
    do { return try transport.run(cmd, transfer) } catch StorageError.commandFailed {
      // A media change invalidates the cached capacity and write permissions.
      let key = try? Self.sense(&transport)
      if key == nil || key == 2 || key == 6 || key == 7 { offline = true }
      throw StorageError.commandFailed
    }
  }

  public mutating func read(lba: UInt64, blocks count: UInt32) throws -> [UInt8] {
    let (cmd, n) = try prepare(lba, count, write: false, fua: false)
    let data = try issue(cmd, .input(n))
    guard data.count == n else { throw StorageError.shortTransfer }
    return data
  }
  public mutating func write(lba: UInt64, blocks count: UInt32, data: [UInt8], fua: Bool = false)
    throws
  {
    let (cmd, n) = try prepare(lba, count, write: true, fua: fua)
    guard data.count == n else { throw StorageError.bounds }
    _ = try issue(cmd, .output(data))
  }
  public mutating func flush() throws {
    _ = try issue([0x35] + [UInt8](repeating: 0, count: 9), .none)
  }
  public mutating func discard(lba: UInt64, blocks count: UInt32) throws {
    guard !offline else { throw StorageError.detached }
    guard !readOnly else { throw StorageError.readOnly }
    guard maxDiscardBlocks != 0 else { throw StorageError.unsupported }
    guard count != 0, count <= maxDiscardBlocks, lba < blocks, UInt64(count) <= blocks - lba
    else { throw StorageError.bounds }
    let range = bytes(lba, 8) + bytes(UInt64(count), 4) + [0, 0, 0, 0]
    _ = try issue([0x42, 0, 0, 0, 0, 0, 0, 0, 24, 0], .output([0, 22, 0, 16, 0, 0, 0, 0] + range))
  }
}

private func big(_ a: ArraySlice<UInt8>) -> UInt64 { a.reduce(0) { $0 << 8 | UInt64($1) } }
private func bytes(_ x: UInt64, _ count: Int) -> [UInt8] {
  (0..<count).reversed().map { UInt8(truncatingIfNeeded: x >> ($0 * 8)) }
}
