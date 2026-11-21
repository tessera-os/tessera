import TarwinBlockWire
import XCTest

@testable import USBMassStorage

private let descriptor: [UInt8] = [
  9, 2, 32, 0, 1, 1, 0, 128, 50, 9, 4, 5, 0, 2, 8, 6, 80, 0,
  7, 5, 0x83, 2, 64, 0, 0, 7, 5, 5, 2, 64, 0, 0,
]

private final class Bus: USBStoragePipes {
  struct PipeFault: Error {}
  var actions: [String] = [], writes: [[UInt8]] = []
  var replies: [([UInt8], Bool)] = [], sent: [(Int, Bool)] = []
  var maxLUN: UInt8? = 1, failClear: UInt8?
  func getMaxLUN(interface: UInt8) throws -> UInt8? { maxLUN }
  func bulkIn(_ endpoint: UInt8, count: Int) throws -> (bytes: [UInt8], stalled: Bool) {
    actions.append("in:\(endpoint):\(count)")
    guard !replies.isEmpty else { throw PipeFault() }
    return replies.removeFirst()
  }
  func bulkOut(_ endpoint: UInt8, bytes: [UInt8]) throws -> (sent: Int, stalled: Bool) {
    actions.append("out:\(endpoint):\(bytes.count)")
    writes.append(bytes)
    return sent.isEmpty ? (bytes.count, false) : sent.removeFirst()
  }
  func massStorageReset(interface: UInt8) throws { actions.append("reset:\(interface)") }
  func clearHalt(_ endpoint: UInt8) throws {
    actions.append("clear:\(endpoint)")
    if endpoint == failClear { throw PipeFault() }
  }
  func csw(_ tag: UInt8, _ status: UInt8 = 0, residue: UInt8 = 0) {
    replies.append(([85, 83, 66, 83, tag, 0, 0, 0, residue, 0, 0, 0, status], false))
  }
  func data(_ data: [UInt8], tag: UInt8, residue: UInt8 = 0) {
    replies.append((data, false))
    csw(tag, residue: residue)
  }
  func discovery(wide: Bool, flags: UInt8 = 0, version: UInt8 = 0) {
    var inquiry = [UInt8](repeating: 0, count: 36)
    inquiry[4] = 31
    inquiry[2] = version
    data(inquiry, tag: 1)
    csw(2)
    data((wide ? [255, 255, 255, 255] : [0, 0, 0, 255]) + [0, 0, 2, 0], tag: 3)
    if wide {
      var c = [UInt8](repeating: 0, count: 32)
      c[3] = 2
      c[10] = 2
      data(c, tag: 4)
    }
    data([3, 0, flags, 0], tag: wide ? 5 : 4)
  }
  func vpd(_ bytes: [UInt8], tag: UInt8) {
    data(bytes, tag: tag, residue: UInt8(255 - bytes.count))
  }
}
final class BulkOnlyTests: XCTestCase {
  private func intf() throws -> BulkInterface {
    try BulkInterface(configuration: descriptor, number: 5)
  }
  func testConfigurationBoundariesAndClassMatch() throws {
    let i = try intf()
    XCTAssertEqual(i.input, 0x83)
    XCTAssertEqual(i.output, 5)
    for (at, value): (Int, UInt8) in [
      (2, 31), (9, 1), (9, 64), (11, 7), (12, 1), (13, 1), (14, 9),
      (15, 0), (16, 0x62), (18, 0), (20, 0x80), (20, 0x93), (21, 3), (22, 0), (27, 0x85),
    ] {
      var d = descriptor
      d[at] = value
      XCTAssertThrowsError(try BulkInterface(configuration: d, number: 5))
    }
    var two = descriptor
    two.append(contentsOf: descriptor.dropFirst(9))
    two[2] = UInt8(two.count)
    XCTAssertThrowsError(try BulkInterface(configuration: two, number: 5))
  }
  func testUnmapEncodesExactRangeAndRefusesOversizeWithoutIssuing() throws {
    let b = Bus()
    b.discovery(wide: true, version: 5)
    b.vpd([0, 0, 0, 3, 0, 0xb0, 0xb2], tag: 6)
    b.vpd([0, 0xb2, 0, 4, 0, 0x80, 0, 0], tag: 7)
    var limits = Array(repeating: UInt8(0), count: 28)
    limits[1] = 0xb0
    limits[3] = 24
    limits[23] = 8
    limits[27] = 1
    b.vpd(limits, tag: 8)
    var disk = try USBDisk(pipes: b, interface: intf(), lun: 0)
    XCTAssertEqual(disk.maxDiscardBlocks, 8)
    let start = b.writes.count
    for (l, n): (UInt64, UInt32) in [(0, 0), (0, 9), (.max, 1), (disk.blocks - 1, 2)] {
      XCTAssertThrowsError(try disk.discard(lba: l, blocks: n))
    }
    XCTAssertEqual(b.writes.count, start)
    b.csw(9)
    try disk.discard(lba: 0x1_0102_0304, blocks: 8)
    XCTAssertEqual(Array(b.writes[start][15..<25]), [0x42, 0, 0, 0, 0, 0, 0, 0, 24, 0])
    XCTAssertEqual(
      b.writes[start + 1],
      [0, 22, 0, 16, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 4, 0, 0, 0, 8, 0, 0, 0, 0])
  }
  func testMissingOrMalformedProvisioningNeverEnablesDiscard() throws {
    for fault in 0..<8 {
      let b = Bus()
      b.discovery(wide: false, version: 5)
      if fault == 0 {
        b.replies.append(([], false))
        b.csw(5, 1, residue: 255)
        b.data([0x72, 5, 0x24, 0, 0, 0, 0, 0], tag: 6, residue: 10)
      } else {
        b.vpd(fault == 1 ? [0, 0, 0, 1, 0xb2] : [0, 0, 0, 2, 0xb0, 0xb2], tag: 5)
        if fault > 1 {
          b.vpd(
            [0, fault == 2 ? 0 : 0xb2, 0, fault == 3 ? 5 : 4, 0, fault == 4 ? 0x40 : 0x80, 0, 0],
            tag: 6)
        }
        if fault > 4 {
          var limits = Array(repeating: UInt8(0), count: 28)
          limits[1] = 0xb0
          limits[3] = fault == 5 ? 12 : 24
          limits[23] = fault == 6 ? 0 : 8
          limits[27] = fault == 7 ? 0 : 1
          b.vpd(limits, tag: 7)
        }
      }
      var disk = try USBDisk(pipes: b, interface: intf(), lun: 0)
      XCTAssertEqual(disk.maxDiscardBlocks, 0)
      let n = b.writes.count
      XCTAssertThrowsError(try disk.discard(lba: 1, blocks: 1))
      XCTAssertEqual(b.writes.count, n)
    }
  }
  func testInterfaceAndLUNRefusalBeforeAnyBulkIO() throws {
    let b = Bus()
    for (max, lun): (UInt8?, UInt8) in [(nil, 1), (0, 15), (16, 0)] {
      b.maxLUN = max
      do {
        _ = try BulkOnly(b, intf(), lun: lun)
        XCTFail()
      } catch { XCTAssertEqual(error as? StorageError, .lun) }
    }
    XCTAssertTrue(b.actions.isEmpty)
  }
  func testDataAndStatusStallsRetainOnlyRelevantBytes() throws {
    let b = Bus()
    var t = try BulkOnly(b, intf(), lun: 1)
    b.replies = [([10, 20, 30], true), ([], true)]
    b.csw(1, residue: 2)
    XCTAssertEqual(try t.run([0x12, 0, 0, 0, 4, 0], .input(4)), [10, 20])
    XCTAssertEqual(
      b.actions, ["out:5:31", "in:131:4", "clear:131", "in:131:13", "clear:131", "in:131:13"])
    XCTAssertEqual(
      b.writes[0],
      [85, 83, 66, 67, 1, 0, 0, 0, 4, 0, 0, 0, 128, 1, 6, 18, 0, 0, 0, 4, 0]
        + Array(repeating: 0, count: 10))
  }
  func testMalformedStatusResetsBothPipesInOrderWithoutReplayingWrite() throws {
    for fault in 0..<7 {
      let b = Bus()
      var t = try BulkOnly(b, intf(), lun: 0)
      b.csw(1)
      switch fault {
      case 0: b.replies[0].0[0] = 0
      case 1: b.replies[0].0[4] = 2
      case 2: b.replies[0].0[8] = 5
      case 3: b.replies[0].0[12] = 2
      case 4: b.replies[0].0[12] = 3
      case 5: b.replies[0].0.removeLast()
      default: b.replies = [([], true), ([], true)]
      }
      XCTAssertThrowsError(try t.run([0x2a], .output([1, 2, 3, 4])))
      XCTAssertEqual(b.writes.count, 2)
      XCTAssertEqual(Array(b.actions.suffix(3)), ["reset:5", "clear:131", "clear:5"])
      b.csw(2)
      _ = try t.run([0], .none)
      XCTAssertEqual(b.writes.count, 3)
    }
  }
  func testResetFailurePermanentlyStopsPipe() throws {
    let b = Bus()
    var t = try BulkOnly(b, intf(), lun: 0)
    b.failClear = 131
    b.sent = [(12, false)]
    XCTAssertThrowsError(try t.run([0], .none)) { XCTAssertEqual($0 as? StorageError, .detached) }
    XCTAssertEqual(b.actions, ["out:5:31", "reset:5", "clear:131"])
    XCTAssertThrowsError(try t.run([0], .none))
    XCTAssertEqual(b.writes.count, 1)
  }
  func testWriteRefusesShortCompletionAndNeverReportsSuccess() throws {
    let b = Bus()
    var t = try BulkOnly(b, intf(), lun: 0)
    b.sent = [(31, false), (1, true)]
    b.csw(1, residue: 3)
    XCTAssertThrowsError(try t.run([0x2a], .output([1, 2, 3, 4]))) {
      XCTAssertEqual($0 as? StorageError, .shortTransfer)
    }
    XCTAssertEqual(b.actions, ["out:5:31", "out:5:4", "clear:5", "in:131:13"])
  }
  func testLargeCapacityCDBsAndReadOnlyBoundsAreCheckedBeforeIO() throws {
    let b = Bus()
    b.discovery(wide: true, flags: 0x90)
    var disk = try USBDisk(pipes: b, interface: intf(), lun: 1)
    XCTAssertEqual(disk.blocks, 0x2_0000_0001)
    XCTAssertTrue(disk.readOnly)
    let writes = b.writes.count
    XCTAssertThrowsError(try disk.write(lba: 1, blocks: 1, data: Array(repeating: 0, count: 512)))
    XCTAssertThrowsError(try disk.read(lba: UInt64.max, blocks: 2))
    XCTAssertThrowsError(try disk.read(lba: 0, blocks: UInt32.max))
    XCTAssertThrowsError(try disk.read(lba: disk.blocks - 1, blocks: 2))
    XCTAssertEqual(b.writes.count, writes)
    b.data(Array(repeating: 0xab, count: 1024), tag: 6)
    XCTAssertEqual(try disk.read(lba: 0xffff_ffff, blocks: 2).count, 1024)
    XCTAssertEqual(
      Array(b.writes.last![15..<31]), [0x88, 0, 0, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 2, 0, 0])
  }
  func testMediaChangeInvalidatesGeometryWithoutRetry() throws {
    let b = Bus()
    b.discovery(wide: false)
    var disk = try USBDisk(pipes: b, interface: intf(), lun: 0)
    let n = b.writes.count
    XCTAssertThrowsError(
      try disk.write(lba: 0, blocks: 1, data: Array(repeating: 0, count: 512), fua: true))
    XCTAssertThrowsError(try disk.write(lba: 0, blocks: 1, data: []))
    XCTAssertEqual(b.writes.count, n)
    b.replies.append(([], false))
    b.csw(5, 1)
    b.data([0x72, 6, 0x28, 0, 0, 0, 0, 0], tag: 6, residue: 10)
    XCTAssertThrowsError(try disk.read(lba: 0, blocks: 1))
    XCTAssertEqual(b.writes.last![15], 3)
    XCTAssertThrowsError(try disk.flush()) { XCTAssertEqual($0 as? StorageError, .detached) }
    XCTAssertEqual(b.writes.count, n + 2)
  }

  func testServiceRejectsBadRecordsAndInvalidGrantsBeforeUSB() throws {
    let b = Bus()
    b.discovery(wide: false)
    var service = try USBBlockService(USBDisk(pipes: b, interface: intf(), lun: 0), epoch: 4)
    let grants = Grants()
    let count = b.writes.count
    let payload = grants.prepare(512, write: false)
    func request(_ epoch: UInt64 = 4, _ op: BlockOp = .read, _ n: UInt64 = 1) -> BlockRequest {
      BlockRequest(
        id: 11, epoch: epoch, lba: 1, blocks: n, queue: 0, op: op, qos: .utility,
        payload: payload)!
    }
    XCTAssertNil(service.execute(request(3).record(), grants: grants))
    var malformed = request().record()
    malformed.words[17] = 1
    XCTAssertNil(service.execute(malformed, grants: grants))
    XCTAssertEqual(service.execute(request(4, .fua).record(), grants: grants)?.status, .unsupported)
    XCTAssertEqual(
      service.execute(request(4, .read, 300).record(), grants: grants)?.status, .unsupported)
    for (offset, value): (Int, UInt32) in [
      (12, 1), (16, 0x2002), (16, 0x1000), (16, 0x1234), (24, 194), (24, 196),
    ] {
      _ = grants.prepare(512, write: false)
      grants.list.storeBytes(of: value, toByteOffset: offset, as: UInt32.self)
      XCTAssertEqual(service.execute(request().record(), grants: grants)?.status, .media)
      grants.list.storeBytes(of: UInt32(0), toByteOffset: 12, as: UInt32.self)
    }
    XCTAssertTrue(grants.data.allSatisfy { $0 == 0x6b })
    XCTAssertEqual(b.writes.count, count)
  }

  func testFailedUSBReadDoesNotScatterPartialBytes() throws {
    let b = Bus()
    b.discovery(wide: false)
    var service = try USBBlockService(USBDisk(pipes: b, interface: intf(), lun: 0), epoch: 2)
    let grants = Grants()
    let r = BlockRequest(
      id: 9, epoch: 2, lba: 0, blocks: 1, queue: 0, op: .read, qos: .standard,
      payload: grants.prepare(512, write: false))!
    b.data(Array(repeating: 1, count: 511), tag: 5, residue: 1)
    let result = service.execute(r.record(), grants: grants)
    XCTAssertEqual(result?.id, 9)
    XCTAssertEqual(result?.status, .media)
    XCTAssertTrue(grants.data.allSatisfy { $0 == 0x6b })
  }
}
