import TarwinABI
import TarwinDevice
import TarwinObject
import TarwinSyscall
import XCTest

private final class Caller: SlotDomainCallContext {
  var process: ProcessExecution, registry = HardwareRegistry(limit: 1)!
  let tree: JobTree
  var record: SlotDomainBinding?
  init(_ process: consuming ProcessExecution, _ tree: consuming JobTree) {
    self.process = consume process
    self.tree = consume tree
  }
  func withLockedCaller(_ query: SlotDomainQuery) -> CallResult {
    query.issue(to: &process, tree: tree, registry: registry) { _ in record }
  }
}
private struct Teardown: GroupTeardown {
  mutating func maskInterrupts(group: UInt64) -> Bool { true }
  mutating func revokeMaps(group: UInt64) -> Bool { true }
  mutating func retireDma(group: UInt64) -> Bool { true }
  mutating func reset(group: UInt64) -> Bool { true }
}

final class DomainCallTests: XCTestCase {
  func testOnlyCurrentSlotGetsItsOwnManageOnlyDomain() {
    let jobs = UnsafeMutableBufferPointer<JobNode>.allocate(capacity: 1)
    let members = UnsafeMutableBufferPointer<JobMember>.allocate(capacity: 1)
    let slots = UnsafeMutableBufferPointer<ThreadSlot>.allocate(capacity: 1)
    let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 6)
    jobs.initialize(repeating: JobNode())
    members.initialize(repeating: JobMember())
    slots.initialize(repeating: ThreadSlot())
    let ids = KoidSource()
    let h = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 5)
    for (i, k) in [
      TarwinKind.job, TarwinKind.process, TarwinKind.deviceSlot,
      TarwinKind.iommuDomain, TarwinKind.deviceSlot,
    ].enumerated() {
      (h + i).initialize(
        to: ObjectHeader(
          source: ids, ownerJob: i == 0 ? 0 : h.pointee.koid,
          kind: k, maximumRights: 0x7ff)!)
    }
    defer {
      for i in 0..<5 { XCTAssertEqual((h + i).pointee.release(), .destroy) }
      h.deinitialize(count: 5)
      h.deallocate()
      cells.deinitialize()
      cells.deallocate()
      slots.deinitialize()
      slots.deallocate()
      members.deinitialize()
      members.deallocate()
      jobs.deinitialize()
      jobs.deallocate()
    }
    var limits = JobLimits(
      processes: 1, threadsPerProcess: 1, handlesPerProcess: 6,
      footprint: 8192, cpuShare: 1, maxQos: 5, jetsamBand: 1, ioRank: 1, entitlements: 0,
      denials: 0, killOnClose: false)
    let tree = JobTree(jobs: jobs, members: members, root: h.pointee, limits: limits)!
    let p = ProcessExecution(
      header: .init(h + 1), job: tree.root, tree: tree,
      slots: slots, cells: cells, salt: 93)!
    let caller = Caller(consume p, consume tree)
    var provider = SlotDomainCall(caller)
    func call(_ name: UInt64, isa: CallISA = .aarch64) -> CallResult {
      var scratch: UInt64 = 0
      return withUnsafeMutablePointer(to: &scratch) {
        switch dispatchCall(
          isa: isa, savedPC: isa == .rv64 ? 0x1000 : 0x1000 + isa.instructionWidth,
          libraryCode: 0x1000..<0x2000, userRange: 0..<0, number: TarwinCall.deviceSlotIommuDomain,
          registers: .init(name), scratch: .init(start: $0, count: 1), provider: &provider)
        {
        case .returned(let r): return r
        default:
          XCTFail()
          return CallResult(status: .max)
        }
      }
    }
    var teardown = Teardown()
    let device = HardwareDevice(
      location: .firmware(1), parent: nil, stable: .init(high: 0, low: 1),
      identity: 1, deviceClass: 0, group: 7, mmio: [], wiredInterrupts: 0, powerStates: 1,
      wakeCapable: false)
    XCTAssertTrue(caller.registry.stage([device], reason: .orderly))
    XCTAssertTrue(caller.registry.commit(&teardown))
    let lease = caller.registry.assign(deviceRoot: true, node: 1, process: caller.process.member.id)
    { _, _ in true }!
    func bind(_ i: Int, to grant: GroupLease, epoch: UInt64) -> SlotDomainBinding? {
      let domain = SlotDomain(
        group: 7, koid: (h + 3).pointee.koid, epoch: epoch,
        aperture: .init(base: 0x1000, length: 4096), page: 4096,
        storage: .init(start: nil, count: 0))
      return .init(slot: .init(h + i), domain: .init(h + 3), lease: grant, backing: domain)
    }
    func install(_ i: Int, _ rights: UInt64) -> UInt64 {
      guard
        case .installed(let n)? = caller.process.withHandles(
          tree: caller.tree, { $0.install(h + i, rights: rights) })
      else {
        XCTFail()
        return 0
      }
      return n
    }
    let slot = install(2, 512)
    let readOnly = install(2, 4)
    let wrongKind = install(1, 512)
    defer {
      _ = caller.process.requestExit(.init(.exited, code: 0), tree: caller.tree) { _ in XCTFail() }
      XCTAssertTrue(caller.process.beginCleanup(invalidate: { _ in }, retire: { _ in XCTFail() }))
      XCTAssertTrue(caller.process.finishCleanup(tree: caller.tree) { _ in })
    }
    XCTAssertEqual(call(0).code, 2)
    XCTAssertEqual(call(readOnly).code, 4)
    XCTAssertEqual(call(wrongKind).code, 3)
    XCTAssertNil(bind(1, to: lease, epoch: lease.epoch))
    XCTAssertNil(bind(2, to: lease, epoch: 0))
    caller.record = bind(4, to: lease, epoch: lease.epoch)
    XCTAssertEqual(call(slot).code, 70)
    caller.record = bind(2, to: lease, epoch: lease.epoch)
    limits.handlesPerProcess = 4
    XCTAssertTrue(caller.tree.tighten(caller.tree.root, to: limits))
    for arch: CallISA in [.x64, .aarch64, .rv64] {
      let r = call(slot, isa: arch)
      XCTAssertEqual(r.code, 0)
      guard
        case .found(let grant) = caller.process.handleReader.pinWithinEpoch(
          r.first, kind: TarwinKind.iommuDomain, need: 512)
      else { return XCTFail() }
      XCTAssertEqual(grant.header, UnsafePointer(h + 3))
      XCTAssertEqual(grant.rights, 512)
      grant.drop { _ in XCTFail() }
      XCTAssertEqual(call(slot).code, 33)
      XCTAssertEqual(
        caller.process.withHandles(tree: caller.tree) { $0.close(r.first) { _ in XCTFail() } }, true
      )
    }
    caller.registry.freeze()
    XCTAssertEqual(call(slot).code, 70)
    XCTAssertTrue(caller.registry.stage([device], replaced: [device.location], reason: .surprise))
    XCTAssertTrue(caller.registry.commit(&teardown))
    let newLease = caller.registry.assign(deviceRoot: true, node: 2, process: lease.process + 1) {
      _, _ in true
    }!
    XCTAssertEqual(call(slot).code, 70)
    caller.record = bind(4, to: newLease, epoch: newLease.epoch)
    XCTAssertEqual(call(install(4, 512)).code, 4)
    XCTAssertTrue(
      caller.process.requestExit(.init(.exited, code: 0), tree: caller.tree) { _ in XCTFail() })
    XCTAssertEqual(call(slot).code, 23)
  }
}
