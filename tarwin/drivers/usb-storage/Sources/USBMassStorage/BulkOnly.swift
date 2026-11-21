/// The USB bus owns endpoint claims, deadlines, DMA and cancellation. A transfer
/// result includes the prefix completed before a STALL. A thrown error means
/// the transfer has ended but its effects are not necessarily known.
public protocol USBStoragePipes: AnyObject {
  func getMaxLUN(interface: UInt8) throws -> UInt8?
  func bulkIn(_ endpoint: UInt8, count: Int) throws -> (bytes: [UInt8], stalled: Bool)
  func bulkOut(_ endpoint: UInt8, bytes: [UInt8]) throws -> (sent: Int, stalled: Bool)
  func massStorageReset(interface: UInt8) throws
  /// Clear ENDPOINT_HALT and restore the host data toggle to DATA0.
  func clearHalt(_ endpoint: UInt8) throws
}

public enum StorageError: Error, Equatable {
  case interface, lun, notReady, unsupported, bounds, readOnly, shortTransfer
  case commandFailed, invalidStatus, transport, detached
}

/// Parse the active alternate setting from the device's configuration descriptor.
public struct BulkInterface {
  public let number, input, output: UInt8
  public let inputPacket, outputPacket: Int

  public init(configuration d: [UInt8], number: UInt8, alternate: UInt8 = 0) throws {
    guard d.count >= 9, d[0] == 9, d[1] == 2,
      Int(d[2]) | (Int(d[3]) << 8) == d.count
    else { throw StorageError.interface }
    var found = false
    var selected = false
    var input: UInt8?
    var output: UInt8?
    var inSize = 0
    var outSize = 0
    var i = 9
    while i < d.count {
      guard d.count - i >= 2, d[i] >= 2, Int(d[i]) <= d.count - i
      else { throw StorageError.interface }
      let len = Int(d[i])
      switch d[i + 1] {
      case 4:
        guard len >= 9 else { throw StorageError.interface }
        selected = d[i + 2] == number && d[i + 3] == alternate
        if selected {
          guard !found, d[i + 4] == 2, d[i + 5] == 8, d[i + 6] == 6, d[i + 7] == 0x50
          else { throw StorageError.interface }
          found = true
        }
      case 5 where selected:
        guard len >= 7, d[i + 3] == 2, d[i + 2] & 0x70 == 0, d[i + 2] & 15 != 0,
          [8, 16, 32, 64, 512, 1024].contains(Int(d[i + 4]) | Int(d[i + 5]) << 8)
        else { throw StorageError.interface }
        let ep = d[i + 2]
        if ep & 0x80 != 0 {
          guard input == nil else { throw StorageError.interface }
          input = ep
          inSize = Int(d[i + 4]) | Int(d[i + 5]) << 8
        } else {
          guard output == nil else { throw StorageError.interface }
          output = ep
          outSize = Int(d[i + 4]) | Int(d[i + 5]) << 8
        }
      default: break
      }
      i += len
    }
    guard found, let input, let output else { throw StorageError.interface }
    self.number = number
    self.input = input
    self.output = output
    self.inputPacket = inSize
    self.outputPacket = outSize
  }
}

enum Transfer {
  case none
  case input(Int)
  case output([UInt8])
}

struct BulkOnly: ~Copyable {
  let pipes: any USBStoragePipes
  let interface: BulkInterface
  let lun: UInt8
  private var tag: UInt32 = 0
  private(set) var stopped = false
  static var limit: Int { 1024 * 1024 }

  init(_ pipes: any USBStoragePipes, _ interface: BulkInterface, lun: UInt8) throws {
    // nil denotes only a control STALL; a transport failure is not LUN zero.
    let maximum = try pipes.getMaxLUN(interface: interface.number) ?? 0
    guard maximum < 16, lun <= maximum else { throw StorageError.lun }
    self.pipes = pipes
    self.interface = interface
    self.lun = lun
  }

  mutating func run(_ cdb: [UInt8], _ transfer: Transfer) throws -> [UInt8] {
    guard !stopped else { throw StorageError.detached }
    let n: Int
    let direction: UInt8
    switch transfer {
    case .none:
      n = 0
      direction = 0
    case .input(let count):
      n = count
      direction = 0x80
    case .output(let bytes):
      n = bytes.count
      direction = 0
    }
    guard (1...16).contains(cdb.count), (0...Self.limit).contains(n)
    else { throw StorageError.bounds }
    tag &+= 1
    let cbw =
      [0x55, 0x53, 0x42, 0x43] + little(tag) + little(UInt32(n))
      + [direction, lun, UInt8(cdb.count)] + cdb + [UInt8](repeating: 0, count: 16 - cdb.count)
    do {
      let cb = try pipes.bulkOut(interface.output, bytes: cbw)
      guard !cb.stalled, cb.sent == 31 else { throw StorageError.transport }
      var data = [UInt8]()
      var transferred = 0
      switch transfer {
      case .none: break
      case .input:
        let r = try pipes.bulkIn(interface.input, count: n)
        data = r.bytes
        transferred = data.count
        if r.stalled { try pipes.clearHalt(interface.input) }
      case .output(let bytes):
        let r = try pipes.bulkOut(interface.output, bytes: bytes)
        transferred = r.sent
        if r.stalled { try pipes.clearHalt(interface.output) }
      }
      guard (0...n).contains(transferred) else { throw StorageError.transport }
      var csw = try pipes.bulkIn(interface.input, count: 13)
      if csw.stalled {
        try pipes.clearHalt(interface.input)
        csw = try pipes.bulkIn(interface.input, count: 13)
      }
      let s = csw.bytes
      guard !csw.stalled, s.count == 13, s[0..<4].elementsEqual([0x55, 0x53, 0x42, 0x53]),
        s[4..<8].elementsEqual(little(tag)), s[12] <= 1
      else { throw StorageError.invalidStatus }
      let residue = Int(
        UInt32(s[8]) | UInt32(s[9]) << 8 | UInt32(s[10]) << 16 | UInt32(s[11]) << 24)
      guard residue <= n else { throw StorageError.invalidStatus }
      if s[12] == 1 { throw StorageError.commandFailed }
      let relevant = n - residue
      guard relevant <= transferred else { throw StorageError.invalidStatus }
      if case .output = transfer, relevant != n { throw StorageError.shortTransfer }
      return Array(data.prefix(relevant))
    } catch StorageError.commandFailed { throw StorageError.commandFailed } catch StorageError
      .shortTransfer
    { throw StorageError.shortTransfer } catch {
      // Never replay a command, in particular a write with an unknown outcome.
      do {
        try pipes.massStorageReset(interface: interface.number)
        try pipes.clearHalt(interface.input)
        try pipes.clearHalt(interface.output)
      } catch {
        stopped = true
        throw StorageError.detached
      }
      throw error
    }
  }
}

private func little(_ x: UInt32) -> [UInt8] {
  (0..<4).map { UInt8(truncatingIfNeeded: x >> ($0 * 8)) }
}
