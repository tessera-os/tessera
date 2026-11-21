import XCTest

@testable import TarwinLoader

private func le(_ value: UInt64, _ n: Int) -> [UInt8] {
  (0..<n).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}

private func recordText(_ bytes: [UInt8]) -> [UInt8] {
  le(UInt64(bytes.count), 2) + bytes
}

private struct Records {
  var tables: [[UInt8]]
  var counts: [UInt32]

  init() {
    let slot = le(8, 8)
    let tag = le(0x1234_5678, 4)
    let text = recordText([0x41, 0xc3, 0xa9])
    let uuid = [UInt8](repeating: 1, count: 16)
    let candidate = le(32, 8) + le(2, 2) + recordText([0x61]) + recordText([0x62])
    tables = [
      slot + le(3, 8), slot + tag, slot + [0, 0] + uuid + tag + text + text,
      slot + le(0x0010, 2), slot + tag + le(1, 2) + candidate,
      slot + le(128, 8), le(0, 4), le(15, 8) + text,
    ]
    counts = [2, 1, 1, 1, 1, 1, 1, 1]
  }

  func serialized() -> [UInt8] {
    let total = 144 + tables.reduce(0) { $0 + $1.count }
    var b: [UInt8] = [84, 76, 68, 49, 1, 0, 8, 0] + le(UInt64(total), 4) + [0, 0, 0, 0]
    var pos = 144
    for (i, t) in tables.enumerated() {
      b += le(UInt64(pos), 4) + le(UInt64(t.count), 4) + le(UInt64(counts[i]), 4) + [0, 0, 0, 0]
      pos += t.count
    }
    for t in tables { b += t }
    return b
  }
}

private func readRecords(_ bytes: [UInt8]) -> LoaderDirectory? {
  bytes.withUnsafeBytes { inspectLoaderRecords($0, addressLimit: 4096) }
}

final class LoaderRecordTests: XCTestCase {
  func testImportsBindOnlyToCanonicalZeroSlotsAndTypedLocalEntries() {
    let tag: UInt64 = 0x1234_5678
    var records = Records()
    let meta = [UInt8](repeating: 1, count: 16) + le(tag, 4) + recordText([65]) + recordText([66])
    let fun = le(0x8010, 8) + [0, 0] + meta
    let data =
      le(0x8028, 8) + [1, 1] + [UInt8](repeating: 0, count: 20) + recordText([67])
      + recordText([68])
    records.tables = [
      [], [], fun + data, le(0x8018, 8) + le(1, 2),
      le(0x8020, 8) + le(tag, 4) + le(1, 2) + le(0x4010, 8) + le(0, 2), [], le(0, 4), [],
    ]
    records.counts = [0, 0, 2, 1, 1, 0, 1, 0]
    var file = [UInt8](repeating: 0, count: 1536)
    func set(_ at: Int, _ v: UInt64, _ n: Int) { file[at..<(at + n)] = le(v, n)[...] }
    set(40, 1024, 8)
    set(58, 64, 2)
    set(60, 3, 2)
    set(62, 1, 2)
    set(1092, 3, 4)
    set(1112, 1280, 8)
    set(1120, 12, 8)
    let names = Array("\0.tirimport\0".utf8)
    file[1280..<(1280 + names.count)] = names[...]
    set(1152, 1, 4)
    set(1156, 1, 4)
    set(1160, 3, 8)
    set(1168, 0x8000, 8)
    set(1176, 384, 8)
    set(1184, 48, 8)
    for (i, k, fl, o, v, n): (Int, UInt64, UInt64, UInt64, UInt64, UInt64) in [
      (0, 1, 5, 256, 0x4000, 32), (1, 1, 6, 384, 0x8000, 48), (2, 0x6474_e552, 4, 384, 0x8000, 48),
    ] {
      let h = 64 + i * 56
      set(h, k, 4)
      set(h + 4, fl, 4)
      set(h + 8, o, 8)
      set(h + 16, v, 8)
      set(h + 32, n, 8)
      set(h + 40, n, 8)
    }
    for i in 0..<4 { set(384 + i * 4, 1, 4) }
    set(267, 0xb8, 1)
    set(268, tag, 4)
    set(272, 0xd503_245f, 4)
    func check(_ m: UInt16 = ElfMachine.aarch64) -> Bool {
      let bytes = file + records.serialized()
      return bytes.withUnsafeBytes { b in
        let r = ELFReader(bytes: b)
        let s = file.count..<b.count
        guard let dir = inspectLoaderRecords(.init(rebasing: b[s]), addressLimit: 0x10000) else {
          return false
        }
        let i = InspectedImage(
          entry: 0, notes: ImageNotes(), programHeaders: 64..<232, loaderRecords: s)
        return r.validImportSlots(i, directory: dir, section: s, machine: m)
      }
    }
    XCTAssertTrue(check())
    for at in [68, 124, 176, 184, 268, 272, 384, 400, 1168, 1176, 1184] {
      let saved = file[at]
      file[at] ^= 1
      XCTAssertFalse(check(), "offset \(at)")
      file[at] = saved
    }
    set(208, 47, 8)
    XCTAssertFalse(check())
    set(208, 48, 8)
    set(1160, 7, 8)
    XCTAssertFalse(check())
    set(1160, 3, 8)
    records.tables[2] = data + fun
    XCTAssertFalse(check())
    records.tables[2] = fun + data
    records.tables[0] = le(0x8008, 8)
    records.counts[0] = 1
    XCTAssertFalse(check())
    records.tables[0] = []
    records.counts[0] = 0
    set(272, 0xfa1e_0ff3, 4)
    XCTAssertTrue(check(ElfMachine.x64))
    set(267, 0, 1)
    XCTAssertFalse(check(ElfMachine.x64))
    set(272, (tag << 12) & 0xffff_ffff | 0x17, 4)
    XCTAssertTrue(check(ElfMachine.rv64))
    set(272, 0x17, 4)
    XCTAssertFalse(check(ElfMachine.rv64))
  }
  func testAllEightTables() throws {
    let fixture = Records()
    let dir = try XCTUnwrap(readRecords(fixture.serialized()))
    XCTAssertEqual(dir[.relative].bytes, 144..<160)
    XCTAssertEqual(dir[.relative].count, 2)
    XCTAssertEqual(dir[.features].bytes.upperBound, fixture.serialized().count)
    var empty = fixture
    for i in 0..<8 where i != 6 {
      empty.tables[i] = []
      empty.counts[i] = 0
    }
    XCTAssertEqual(readRecords(empty.serialized())?[.gpu].bytes, 144..<148)
  }

  func testTruncatedOrExtendedRecords() {
    for i in 0..<8 {
      let original = Records()
      for n in 0..<original.tables[i].count {
        var damaged = original
        damaged.tables[i] = Array(damaged.tables[i].prefix(n))
        XCTAssertNil(readRecords(damaged.serialized()), "table \(i), prefix \(n)")
      }
      var extra = original
      extra.tables[i].append(0)
      XCTAssertNil(readRecords(extra.serialized()))
      extra = original
      extra.counts[i] = .max
      XCTAssertNil(readRecords(extra.serialized()))
    }
  }

  func testDirectoryAndFieldRules() {
    let original = Records()
    for at in [0, 4, 6, 8, 12, 16, 20, 28, 32, 48, 64, 80, 96, 112, 128, 140] {
      var b = original.serialized()
      b[at] ^= 0xff
      XCTAssertNil(readRecords(b))
    }
    for (table, at, value): (Int, Int, UInt8) in [
      (0, 0, 1), (0, 0, 2), (1, 0, 7), (2, 8, 3), (2, 9, 1), (3, 1, 16),
      (4, 12, 0), (4, 14, 2), (4, 29, 97), (5, 0, 255), (7, 1, 16),
    ] {
      var f = original
      f.tables[table][at] = value
      XCTAssertNil(readRecords(f.serialized()), "table \(table) at \(at)")
    }
    for tag in [0, 0x100000, 0x1234_5017, 0xfa1e_0ff3, 0xd503_245f] as [UInt64] {
      var f = original
      f.tables[1].replaceSubrange(8..<12, with: le(tag, 4))
      XCTAssertNil(readRecords(f.serialized()))
    }
    for invalid in [
      [0], [], [0xc0, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80],
      [0xe2, 0x82], [0x80], [0xf0, 0x80, 0x80, 0x80], [0xc2, 0x20],
    ] as [[UInt8]] {
      var f = original
      f.tables[7] = le(0, 8) + recordText(invalid)
      XCTAssertNil(readRecords(f.serialized()))
    }
  }
}
