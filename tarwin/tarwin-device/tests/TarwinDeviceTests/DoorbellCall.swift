import TarwinABI
import TarwinDevice
import TarwinObject
import TarwinSyscall
import XCTest

private struct TestVM: DoorbellVmLifetime {
  var pages: [UInt64] = [], unmapped: [UInt64] = []
  var ackLast = false
  var client: UnsafePointer<ObjectHeader>
  mutating func unmapAndSync(_ m: DoorbellMapping, in process: UnsafePointer<ObjectHeader>) -> Bool
  {
    XCTAssertEqual(process, client)
    unmapped.append(m.physical)
    return m.physical != 0x22000 || ackLast
  }
  func retire(_ header: UnsafePointer<ObjectHeader>) { XCTFail() }
  mutating func installWriteOnlyUcNx(_ m: DoorbellMapping, in process: UnsafePointer<ObjectHeader>)
    -> DoorbellInstall
  {
    XCTAssertEqual(process, client)
    XCTAssertEqual(m.process, client.pointee.koid)
    XCTAssertEqual(m.bytes, 4096)
    pages.append(m.physical)
    return .installed
  }
}

private struct OtherResources: GroupTeardown {
  var maps = 0, drains = 0
  func maskInterrupts(group: UInt64) -> Bool { true }
  func reset(group: UInt64) -> Bool { true }
  mutating func retireDma(group: UInt64) -> Bool {
    drains += 1
    return true
  }
  mutating func revokeMaps(group: UInt64) -> Bool {
    maps += 1
    return true
  }
}

private final class DoorbellCaller: DoorbellCallContext {
  var process: ProcessExecution, registry = HardwareRegistry(limit: 1)!
  let tree: JobTree
  var resources: DoorbellResources<OtherResources, TestVM>
  init(
    _ process: consuming ProcessExecution, tree: consuming JobTree,
    target: UnsafePointer<ObjectHeader>, entries: UnsafeMutableBufferPointer<DoorbellRangeEntry>
  ) {
    self.process = consume process
    self.tree = consume tree
    resources = DoorbellResources(
      base: OtherResources(), vm: TestVM(client: target), entries: entries)!
  }
  func withLockedCaller(_ query: DoorbellGrantQuery) -> CallResult {
    resources.issue(query, to: &process, tree: tree, registry: registry)
  }
}

final class DoorbellCallTests: XCTestCase {
  func testRegisterGrantResolvesBothHandlesAndExactRangeBeforeCallingVM() {
    let ids = KoidSource()
    let h = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 5)
    for (i, k) in [
      TarwinKind.job, TarwinKind.process, TarwinKind.process, TarwinKind.mmioRange,
      TarwinKind.mmioRange,
    ].enumerated() {
      (h + i).initialize(
        to: ObjectHeader(
          source: ids, ownerJob: i == 0 ? 0 : h.pointee.koid, kind: k, maximumRights: 1023)!)
    }
    let jobs = UnsafeMutableBufferPointer<JobNode>.allocate(capacity: 1)
    let members = UnsafeMutableBufferPointer<JobMember>.allocate(capacity: 1)
    let slots = UnsafeMutableBufferPointer<ThreadSlot>.allocate(capacity: 1)
    let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 5)
    let pages = UnsafeMutableBufferPointer<DoorbellPage>.allocate(capacity: 3)
    let entries = UnsafeMutableBufferPointer<DoorbellRangeEntry>.allocate(capacity: 2)
    for i in entries.indices { (entries.baseAddress! + i).initialize(to: DoorbellRangeEntry()) }
    for i in pages.indices {
      (pages.baseAddress! + i).initialize(to: .init(offset: UInt64(i) * 4096))
    }
    jobs.initialize(repeating: JobNode())
    members.initialize(repeating: JobMember())
    slots.initialize(repeating: ThreadSlot())
    defer {
      for i in 0..<5 { XCTAssertEqual((h + i).pointee.release(), .destroy) }
      h.deinitialize(count: 5)
      h.deallocate()
      pages.deinitialize()
      pages.deallocate()
      entries.deinitialize()
      entries.deallocate()
      cells.deinitialize()
      cells.deallocate()
      slots.deinitialize()
      slots.deallocate()
      members.deinitialize()
      members.deallocate()
      jobs.deinitialize()
      jobs.deallocate()
    }
    let tree = JobTree(
      jobs: jobs, members: members, root: h.pointee,
      limits: .init(
        processes: 1, threadsPerProcess: 1, handlesPerProcess: 5, footprint: 65536, cpuShare: 1,
        maxQos: 5, jetsamBand: 1, ioRank: 1, entitlements: 0, denials: 0, killOnClose: false))!
    let process = ProcessExecution(
      header: .init(h + 1), job: tree.root, tree: tree, slots: slots, cells: cells, salt: 19)!
    let caller = DoorbellCaller(
      consume process, tree: consume tree, target: .init(h + 2), entries: entries)
    let gpu = HardwareDevice(
      location: .firmware(1), parent: nil, stable: .init(high: 1, low: 9),
      identity: 5, deviceClass: 0x030000, group: 7,
      mmio: [.init(range: .init(base: 0x20000, length: 12288), frameBuffer: false)],
      wiredInterrupts: 1, powerStates: 1, wakeCapable: false)
    XCTAssertTrue(caller.registry.stage([gpu], reason: .orderly))
    XCTAssertTrue(caller.registry.commit(&caller.resources))
    let lease = caller.registry.assign(deviceRoot: true, node: 1, process: caller.process.member.id)
    { _, _ in true }!
    func bind(_ i: Int) -> Bool {
      caller.resources.bind(
        .init(h + i), registry: caller.registry, lease: lease, node: 1,
        apertureIndex: 0, pageBytes: 4096, designated: pages)
    }
    XCTAssertTrue(bind(3))
    XCTAssertFalse(bind(3))
    XCTAssertFalse(bind(4))
    func name(_ i: Int, _ rights: UInt64) -> UInt64 {
      guard
        case .installed(let n)? = caller.process.withHandles(
          tree: caller.tree, { $0.install(.init(h + i), rights: rights) })
      else {
        XCTFail()
        return 0
      }
      return n
    }
    let range = name(3, 528)
    let target = name(2, 512)
    let weak = name(3, 16)
    let other = name(4, 528)
    var provider = DoorbellGrantCall(caller)
    func call(_ r: UInt64, _ t: UInt64, _ off: UInt64, _ isa: CallISA = .aarch64) -> UInt32 {
      var words = [UInt64](repeating: .max, count: 3)
      return words.withUnsafeMutableBufferPointer {
        guard
          case .returned(let result) = dispatchCall(
            isa: isa,
            savedPC: isa == .rv64 ? 0x1000 : 0x1000 + isa.instructionWidth,
            libraryCode: 0x1000..<0x2000,
            userRange: 0..<0, number: TarwinCall.mmioRangeGrantDoorbell,
            registers: .init(r, t, off), scratch: $0, provider: &provider)
        else {
          XCTFail()
          return .max
        }
        return result.code
      }
    }
    XCTAssertEqual(call(0, target, 0), 2)
    XCTAssertEqual(call(target, target, 0), 3)
    XCTAssertEqual(call(weak, target, 0), 4)
    XCTAssertEqual(call(other, target, 0), 70)
    XCTAssertEqual(call(range, range, 0), 3)
    XCTAssertEqual(call(range, target, 1), 4)
    XCTAssertTrue(caller.resources.vm.pages.isEmpty)
    for (i, isa) in [CallISA.aarch64, .rv64, .x64].enumerated() {
      XCTAssertEqual(call(range, target, UInt64(i) * 4096, isa), 0)
    }
    XCTAssertEqual(call(range, target, 0), 22)
    XCTAssertTrue(caller.registry.stage([gpu], replaced: [gpu.location], reason: .surprise))
    XCTAssertFalse(caller.registry.commit(&caller.resources))
    XCTAssertEqual(caller.resources.base.maps, 0)
    XCTAssertEqual(caller.resources.base.drains, 0)
    XCTAssertEqual(call(range, target, 0), 70)
    caller.resources.vm.ackLast = true
    XCTAssertTrue(caller.registry.commit(&caller.resources))
    XCTAssertEqual(caller.resources.vm.unmapped, [0x20000, 0x21000, 0x22000, 0x22000])
    XCTAssertEqual(caller.resources.base.maps, 1)
    XCTAssertEqual(caller.resources.base.drains, 1)
    XCTAssertEqual(call(range, target, 0), 70)
    _ = caller.process.requestExit(.init(.exited, code: 0), tree: caller.tree) { _ in XCTFail() }
    XCTAssertEqual(call(range, target, 0), 23)
    XCTAssertTrue(caller.process.beginCleanup(invalidate: { _ in }, retire: { _ in XCTFail() }))
    XCTAssertTrue(caller.process.finishCleanup(tree: caller.tree) { _ in })
    XCTAssertEqual(caller.resources.vm.pages, [0x20000, 0x21000, 0x22000])
  }
}
