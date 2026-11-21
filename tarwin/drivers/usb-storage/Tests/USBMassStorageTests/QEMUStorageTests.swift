import Foundation
import TarwinBlockWire
import USBMassStorage
import XCTest

final class QEMUStorageTests: XCTestCase {
  func testEnumerateWriteFlushReadAndPreserveNeighbors() throws {
    guard let binary = ProcessInfo.processInfo.environment["TARWIN_QEMU_X64"] else {
      throw XCTSkip("Set TARWIN_QEMU_X64 to the qemu-system-x86_64 executable")
    }
    let image = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var expected = Data((0..<(512 * 128)).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 9)) })
    try expected.write(to: image)
    defer { try? FileManager.default.removeItem(at: image) }
    let bus = try QEMUBus(binary: binary, image: image)
    defer { bus.stop() }
    try bus.assign()
    let host = UHCIStorageBus(
      io: bus, pages: UHCIPages(frames: 0x10000, schedule: 0x12000, bounce: 0x14000)!, rootPort: 0)!
    let interface = try host.configure()
    var disk = try USBDisk(pipes: host, interface: interface, lun: 0)
    XCTAssertEqual(disk.blocks, 128)
    XCTAssertEqual(disk.blockBytes, 512)
    XCTAssertFalse(disk.readOnly)
    let start = 17 * 512
    let end = 20 * 512
    XCTAssertEqual(try disk.read(lba: 17, blocks: 3), Array(expected[start..<end]))
    let payload = (0..<(end - start)).map { UInt8(truncatingIfNeeded: 217 + $0 * 37) }
    try disk.write(lba: 17, blocks: 3, data: payload, fua: disk.forceUnitAccess)
    XCTAssertThrowsError(try disk.write(lba: 127, blocks: 3, data: payload))
    try disk.flush()
    expected.replaceSubrange(start..<end, with: payload)
    XCTAssertEqual(try disk.read(lba: 16, blocks: 5), Array(expected[(start - 512)..<(end + 512)]))
    let channel = try BlockChannel(consume disk)
    let grants = Grants()
    let size = 1536
    let wire = grants.prepare(size, write: true)
    for (i, b) in grants.buffers.enumerated() {
      for k in b.indices { b[k] = UInt8(truncatingIfNeeded: k * 3 + i) }
    }
    let scattered = grants.buffers.flatMap { Array($0) }
    let op: BlockOp = channel.service.limits.fua ? .fua : .write
    let write = try channel.run(op, 83, 3, grants: grants, payload: wire)
    XCTAssertEqual(write.error, 0)
    XCTAssertEqual(write.result0, UInt64(size))
    let flush = try channel.run(.flush, 0, 0, grants: grants, payload: .init())
    XCTAssertEqual(flush.error, 0)
    XCTAssertEqual(flush.result0, 0)
    expected.replaceSubrange(83 * 512..<86 * 512, with: scattered)
    let wrongDirection = try channel.run(.read, 83, 3, grants: grants, payload: wire)
    XCTAssertEqual(wrongDirection.error, 90)
    _ = grants.prepare(size, write: false)
    grants.data.initializeMemory(as: UInt8.self, repeating: 0x6b)
    let read = try channel.run(.read, 83, 3, grants: grants, payload: wire)
    XCTAssertEqual(read.error, 0)
    XCTAssertEqual(read.result0, UInt64(size))
    XCTAssertEqual(grants.buffers.flatMap { Array($0) }, scattered)
    for slice in [0..<11, 328..<501, (501 + size - 317)..<grants.data.count] {
      XCTAssertTrue(grants.data[slice].allSatisfy { $0 == 0x6b })
    }
    let discard = try channel.run(.discard, 40, 8, grants: grants, payload: .init())
    XCTAssertEqual(discard.error, 0)
    XCTAssertEqual(discard.result0, 0)
    // Disable the root port between commands. This controller generation
    // must never submit to a newly connected device using old grants.
    try bus.write16(0x10, 0)
    let removed = try channel.run(.flush, 0, 0, grants: grants, payload: .init())
    XCTAssertEqual(removed.error, 70)
    XCTAssertThrowsError(try host.getMaxLUN(interface: interface.number))
    try host.stop()
    bus.stop()
    let final = try Data(contentsOf: image)
    XCTAssertEqual(final.count, expected.count)
    XCTAssertEqual(final.prefix(40 * 512), expected.prefix(40 * 512))
    XCTAssertEqual(final.dropFirst(48 * 512), expected.dropFirst(48 * 512))
  }
}
