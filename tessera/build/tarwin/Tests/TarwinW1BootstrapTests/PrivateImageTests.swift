import CryptoKit
import Foundation
import TarwinArchAarch64
import TarwinLoader
import TarwinW1Bootstrap
import Testing

@testable import TarwinW0Verify

// Loader interoperability corpus only. No signing identity, enrollment,
// PCR, address-space switch, PAC instruction or user execution in this test.
@Test func stageBothInteropMembersOrEraseEveryPrivatePage() throws {
  let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
    "../../../../../tarwin/tarwin-loader/w0/Tests/TarwinW0Tests/InteropW1")
  let inputs = try ["TEST-ONLY.TIR", "TEST-ONLY.SIG", "test-boot.pub", "test-only.pub"].map {
    try NSData(contentsOf: dir.appendingPathComponent($0), options: [])
  }
  let symbol = NSData(data: Data("_RIDL110LibTessera17tessera_test_openF_vea5d84f932ca1647".utf8))
  let uuid = NSData(
    data: withUnsafeBytes(of: UUID(uuidString: "ea5d84f9-32ca-1647-888d-f1c1d07d950f")!.uuid) {
      Data($0)
    })
  let digest = NSData(
    data: Data(SHA256.hash(data: Data("function tessera_test_open() -> U32\n".utf8))))
  func raw(_ d: NSData) -> UnsafeRawBufferPointer { .init(start: d.bytes, count: d.length) }
  defer { withExtendedLifetime((inputs, symbol, uuid, digest)) {} }
  let z = BlakeCv(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0)
  let nodes = UnsafeMutableBufferPointer<BlakeCv>.allocate(capacity: 512)
  nodes.initialize(repeating: z)
  let poly = UnsafeMutableBufferPointer<Int32>.allocate(capacity: 2048)
  let temp = UnsafeMutableRawBufferPointer.allocate(byteCount: 16 * 54 * 32, alignment: 16)
  let page = 16384
  let slots = 12
  let tableBytes = 8 * 16384
  let ram = UnsafeMutableRawBufferPointer.allocate(byteCount: slots * page, alignment: page)
  defer {
    ram.deallocate()
    temp.deallocate()
    poly.deallocate()
    nodes.deallocate()
  }
  let archive = raw(inputs[0])
  let set = try #require(
    verifyStage1(
      archive: archive, signature: raw(inputs[1]), enrollment: raw(inputs[2]),
      systemEnrollment: raw(inputs[3]),
      policy: .init(
        machine: 183, baselineSupported: true, trustedUTC: 1_795_238_964,
        train: (26, 11, 1), tir: (26, 11, 2), addressLimit: 1 << 32, securityFloor: 1, slot: 0,
        debugEmulator: true),
      initEntryTag: 0x5e57_0001,
      contract: .init(
        uuid: raw(uuid), symbol: raw(symbol), textSHA256: raw(digest), typeTag: 0x5e57_0002),
      hashes: nodes, polynomials: poly, message: temp))
  let plan = try #require(
    set.addressPlan(occupied: .init(start: nil, count: 0), nextRandom: { UInt64.max }))
  let base: UInt64 = 0x100000
  var clean = true
  var sign = true
  var calls = 0
  func build(_ size: Int) -> W1PrivateImages? {
    calls = 0
    return preparePrivateW1Images(
      set, plan: plan, archive: archive, storage: .init(rebasing: ram[..<size]),
      physical: base, tableBytes: tableBytes, nodes: nodes, witnesses: temp,
      cleanToPoU: { _ in
        calls += 1
        return clean
      },
      signImport: { target, modifier in
        sign && target == plan.targetAddress && modifier == plan.storageModifier ? 0x1234_5678 : nil
      })
  }
  func denied(_ size: Int) -> Bool {
    ram.initializeMemory(as: UInt8.self, repeating: 0xaa)
    if build(size) != nil { return false }
    return ram.prefix(size).allSatisfy { $0 == 0 } && ram.dropFirst(size).allSatisfy { $0 == 0xaa }
  }
  clean = false
  #expect(denied(ram.count) && calls == 1)
  clean = true
  sign = false
  #expect(denied(ram.count) && calls == 2)
  sign = true
  #expect(denied(tableBytes + page) && calls == 1)
  guard let images = build(ram.count) else {
    Issue.record("private image set rejected")
    return
  }
  #expect(
    calls == 2 && images.tables.physicalRoot == base && images.usedBytes == tableBytes + 3 * page)
  #expect(images.libraryCode == plan.libraryCode && images.processCode.contains(plan.processEntry))
  // Walk the descriptors independently, including the image reservation holes.
  func leaf(_ va: UInt64) -> UInt64 {
    var index = 0
    for l in 0..<4 {
      let value = ram.load(
        fromByteOffset: index + Int(armWalkIndex(va, level: UInt8(l))) * 8, as: UInt64.self)
      if l == 3 || value == 0 { return value }
      guard value & 16383 == 3, value >= base + 3, value - 3 - base < UInt64(tableBytes) else {
        return 0
      }
      index = Int(value - 3 - base)
    }
    return 0
  }
  #expect(
    leaf(plan.processReservation.lowerBound) == 0 && leaf(plan.libraryReservation.lowerBound) == 0)
  for (i, va) in [plan.processEntry, plan.slotAddress, plan.targetAddress].enumerated() {
    let pa = base + UInt64(tableBytes + i * page)
    let expect =
      armUserPage(pa, write: false, execute: i != 1, lpa2: false) | (i == 1 ? 0 : 1 << 50)
    #expect(leaf(va) == expect)
  }
  let slot = tableBytes + page + Int(plan.slotAddress & 16383)
  #expect(ram.load(fromByteOffset: slot, as: UInt64.self) == 0x1234_5678)
  #expect(ram[slot + 8..<tableBytes + 2 * page].allSatisfy { $0 == 0 })
}
