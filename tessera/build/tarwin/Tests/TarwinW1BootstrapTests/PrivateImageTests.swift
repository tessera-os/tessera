import Foundation
import TarwinArchAarch64
import TarwinKernelRandom
import TarwinLoader
import TarwinObject
import TarwinProcessKeys
import Testing

@testable import TarwinW0Verify
@testable import TarwinW1Bootstrap

// Loader interoperability corpus only. No signing identity, enrollment,
// PCR, address-space switch, PAC instruction or user execution in this test.
@Test(arguments: [ArmPermissionLayout.direct, .guarded])
func stageBothInteropMembersOrEraseEveryPrivatePage(_ layout: ArmPermissionLayout) throws {
  let base: UInt64 = 0x100000
  let ids = KoidSource()
  try withTestChild(root: base, ids: ids) { child, tree in
    try stageImages(child: &child, tree: tree, ids: ids, base: base, layout: layout)
  }
}

private func stageImages(
  child: inout ProcessExecution, tree: borrowing JobTree, ids: borrowing KoidSource,
  base: UInt64, layout: ArmPermissionLayout
) throws {
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
  let hash = Data("function tessera_test_open() -> U32\n".utf8).withUnsafeBytes(measurementDigest)
  let digest = NSData(data: withUnsafeBytes(of: hash) { Data($0) })
  func raw(_ d: NSData) -> UnsafeRawBufferPointer { .init(start: d.bytes, count: d.length) }
  defer { withExtendedLifetime((inputs, symbol, uuid, digest)) {} }
  let z = BlakeCv(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0)
  let nodes = UnsafeMutableBufferPointer<BlakeCv>.allocate(capacity: 512)
  nodes.initialize(repeating: z)
  let poly = UnsafeMutableBufferPointer<Int32>.allocate(capacity: 2048)
  let temp = UnsafeMutableRawBufferPointer.allocate(byteCount: 16 * 54 * 32, alignment: 16)
  let page = 16384
  let slots = 24
  let tableBytes = 10 * 16384
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
  let bank = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: 10)
  defer { bank.deallocate() }
  let seed = UnsafeMutableRawBufferPointer.allocate(byteCount: 96, alignment: 8)
  defer { seed.deallocate() }
  seed.initializeMemory(as: UInt8.self, repeating: 0x68)
  let sample = UnsafeRawBufferPointer(seed)
  var rng = KernelRandom(
    policy: .debugQEMU, bootSeed: .init(rebasing: sample[..<64]),
    hardware: .init(rebasing: sample[64...]), source: .emulatedTPM,
    generation: .virtualMachine(low: 1, high: 2))!
  guard
    let keys = ArmProcessKeys(
      child: &child, root: base, tree: tree, storage: bank,
      random: &rng, generation: .virtualMachine(low: 1, high: 2))
  else {
    Issue.record("diagnostic key provision failed")
    return
  }
  var clean = true
  var sign = true
  var calls = 0
  var signedCalls = 0
  var generationLow: UInt64 = 1
  func signSlot(
    _ target: UInt64, _ modifier: UInt64, root: UInt64, child: borrowing ProcessExecution,
    tree: borrowing JobTree
  ) -> UInt64? {
    let host: UInt64 = 0x80000
    return signProcessImport(
      target, modifier, plan: plan, root: root, host: host, child: child,
      tree: tree, keys: keys, current: { .virtualMachine(low: generationLow, high: 2) }
    ) { addr, mod, p, ttbr1 in
      signedCalls += 1
      #expect(addr == plan.targetAddress && mod == plan.storageModifier && ttbr1 == host)
      #expect(p == UnsafePointer(bank.baseAddress!))
      return sign ? 0x1234_5678 : 0
    }
  }
  #expect(
    signSlot(plan.targetAddress + 4, plan.storageModifier, root: base, child: child, tree: tree)
      == nil)
  #expect(
    signSlot(plan.targetAddress, plan.storageModifier ^ 8, root: base, child: child, tree: tree)
      == nil)
  #expect(
    signSlot(plan.targetAddress, plan.storageModifier, root: base + 16384, child: child, tree: tree)
      == nil)
  #expect(signedCalls == 0)
  func build(_ size: Int) -> W1PrivateImages? {
    calls = 0
    let thread = W1ThreadPlacement(stackBytes: 81920, draw: { .max })
    return preparePrivateW1Images(
      set, plan: plan, archive: archive, storage: .init(rebasing: ram[..<size]),
      physical: base, tableBytes: tableBytes, nodes: nodes, witnesses: temp,
      cleanToPoU: { _ in
        calls += 1
        return clean
      },
      child: child, tree: tree, layout: layout,
      signImport: { target, modifier in
        signSlot(target, modifier, root: base, child: child, tree: tree)
      }, firstThread: consume thread)
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
  #expect(denied(tableBytes + 5 * page) && calls == 2)
  guard let images = build(ram.count) else {
    Issue.record("private image set rejected")
    return
  }
  #expect(
    calls == 2 && images.tables.physicalRoot == base && images.usedBytes == tableBytes + 10 * page)
  #expect(images.libraryCode == plan.libraryCode && images.processEntry == plan.processEntry)
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
      armUserPage(pa, write: false, execute: i != 1, lpa2: false)
      | (i == 1 ? (layout == .guarded ? 1 << 51 : 0) : 1 << 50)
    #expect(leaf(va) == expect)
  }
  let slot = tableBytes + page + Int(plan.slotAddress & 16383)
  #expect(ram.load(fromByteOffset: slot, as: UInt64.self) == 0x1234_5678)
  #expect(ram[slot + 8..<tableBytes + 2 * page].allSatisfy { $0 == 0 })
  let stagedThread = images.initialThread
  let thread = try #require(stagedThread)
  let start = tableBytes + 3 * page
  let tcb = start + 5 * page
  let expectedTCB: [UInt64] = [
    thread.tcb, .max, thread.stack.lowerBound, 0, 0, thread.shadow.lowerBound, 0, 0,
  ]
  #expect(ram[start..<tcb].allSatisfy { $0 == 0 })
  #expect(
    ram[tcb..<tcb + 64].withUnsafeBytes { Array($0.bindMemory(to: UInt64.self)) } == expectedTCB)
  #expect(ram[tcb + 64..<images.usedBytes].allSatisfy { $0 == 0 })
  #expect(thread.shadowPhysical == base + UInt64(tcb + page))
  #expect(leaf(thread.stack.lowerBound - 1) == 0 && leaf(thread.stack.upperBound) == 0)
  #expect(leaf(thread.shadow.lowerBound - 1) == 0 && leaf(thread.shadow.upperBound) == 0)
  #expect((leaf(thread.shadow.lowerBound) == 0) == (layout == .direct))
  let isControl = images.tables.mapsControlPage(
    thread.shadow.lowerBound, physical: thread.shadowPhysical)
  let isData = images.tables.mapsPrivateDataPage(
    thread.shadow.lowerBound, physical: thread.shadowPhysical)
  #expect(isControl == (layout == .guarded) && !isData)
  #expect(
    leaf(thread.tcb) == armUserPage(base + UInt64(tcb), write: true, execute: false, lpa2: false))
  let stack = UnsafeMutableRawBufferPointer(rebasing: ram[start..<tcb])
  for otherRoot in [base + 16384, base] {
    try withTestChild(root: otherRoot, ids: ids) { other, otherTree in
      let before = signedCalls
      let refused =
        signSlot(
          plan.targetAddress, plan.storageModifier, root: otherRoot, child: other, tree: otherTree)
        == nil
      #expect(refused && signedCalls == before)
      try checkStartupFrame(
        images, child: &other, tree: otherTree, ids: ids, accepted: false, stack: stack)
    }
  }
  let beforeRotation = signedCalls
  for id: UInt64 in [3, 1] {
    generationLow = id
    #expect(signSlot(plan.targetAddress, plan.storageModifier, root: base, child: child, tree: tree) == nil)
  }
  #expect(signedCalls == beforeRotation)
  try checkStartupFrame(images, child: &child, tree: tree, ids: ids, accepted: true, stack: stack)
}
