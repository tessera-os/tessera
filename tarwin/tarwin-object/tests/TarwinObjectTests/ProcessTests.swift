import TarwinObject
import XCTest

extension ProcessExecution {
  fileprivate mutating func beginCleanup() -> Bool {
    beginCleanup(
      invalidate: { _ in XCTFail("unexpected handle") },
      retire: { _ in XCTFail("unexpected retire") })
  }
}

private func fixture(
  _ body: (
    inout ProcessExecution, borrowing JobTree, UnsafeMutablePointer<ThreadExecution>,
    UnsafeMutablePointer<ThreadExecution>
  ) -> Void
) {
  let jobs = UnsafeMutableBufferPointer<JobNode>.allocate(capacity: 1)
  let members = UnsafeMutableBufferPointer<JobMember>.allocate(capacity: 2)
  let slots = UnsafeMutableBufferPointer<ThreadSlot>.allocate(capacity: 2)
  let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 4)
  let headers = UnsafeMutableBufferPointer<ObjectHeader>.allocate(capacity: 4)
  let records = UnsafeMutableBufferPointer<ThreadExecution>.allocate(capacity: 2)
  jobs.initialize(repeating: JobNode())
  members.initialize(repeating: JobMember())
  slots.initialize(repeating: ThreadSlot())
  defer {
    cells.deinitialize()
    cells.deallocate()
    records.deinitialize()
    records.deallocate()
    headers.deinitialize()
    headers.deallocate()
    slots.deinitialize()
    slots.deallocate()
    members.deinitialize()
    members.deallocate()
    jobs.deinitialize()
    jobs.deallocate()
  }
  let ids = KoidSource()
  let root = headers.baseAddress!
  let parent = root + 1
  root.initialize(
    to: ObjectHeader(source: ids, ownerJob: 0, kind: TarwinKind.job, maximumRights: 0)!)
  let ceiling = JobLimits(
    processes: 2, threadsPerProcess: 2, handlesPerProcess: 32, footprint: 8192, cpuShare: 10,
    maxQos: 5, jetsamBand: 3, ioRank: 2, entitlements: 0, denials: 0, killOnClose: false)
  let tree = JobTree(jobs: jobs, members: members, root: root.pointee, limits: ceiling)!
  parent.initialize(
    to: ObjectHeader(
      source: ids, ownerJob: root.pointee.koid, kind: TarwinKind.process, maximumRights: 0x7ff)!)
  var p = ProcessExecution(
    header: .init(parent), job: tree.root, tree: tree, slots: slots, cells: cells, salt: 33)!
  for i in 0..<2 {
    let h = parent + 1 + i
    h.initialize(
      to: ObjectHeader(
        source: ids, ownerJob: root.pointee.koid, kind: TarwinKind.thread, maximumRights: 0)!)
    (records.baseAddress! + i).initialize(
      to: ThreadExecution(header: .init(h), process: p.member, job: tree.root)!)
  }
  body(&p, tree, records.baseAddress!, records.baseAddress! + 1)
}
final class ProcessTests: XCTestCase {
  func testCurrentHandleIsBorrowedAndNamesOnlyThisProcess() {
    fixture { process, tree, _, _ in
      guard case .installed(let name) = process.currentHandle(tree: tree),
        case .installed(let again) = process.currentHandle(tree: tree)
      else { return XCTFail() }
      XCTAssertEqual(name, again)
      guard
        case .found(let grant) = process.handleReader.pinWithinEpoch(
          name, kind: TarwinKind.process, need: 0)
      else { return XCTFail() }
      XCTAssertEqual(grant.rights, 0x500)
      XCTAssertEqual(grant.header, process.header)
      grant.drop { _ in XCTFail() }
      let closed = process.withHandles(tree: tree) { table in
        XCTAssertEqual(table.count, 1)
        return table.close(name) { _ in XCTFail() }
      }
      XCTAssertEqual(closed, true)
      guard case .installed(let fresh) = process.currentHandle(tree: tree) else { return XCTFail() }
      XCTAssertNotEqual(name, fresh)
      XCTAssertTrue(
        process.requestExit(TaskExit(.exited, code: 0), tree: tree, stop: { _ in XCTFail() }))
      guard case .invalidHandle = process.currentHandle(tree: tree) else { return XCTFail() }
      XCTAssertTrue(
        process.beginCleanup(invalidate: { XCTAssertEqual($0, fresh) }, retire: { _ in XCTFail() }))
      XCTAssertTrue(process.finishCleanup(tree: tree, notify: { _ in }))
    }
  }
  func testSuspendAndAncestorFreezeCannotWakeBlockedOrUnstartedThread() {
    fixture { p, tree, a, b in
      let id = a.pointee.header.pointee.koid
      let other = b.pointee.header.pointee.koid
      XCTAssertEqual(p.join(a, qos: 5, realtimeEntitled: false, tree: tree), .denied)
      XCTAssertEqual(p.join(a, qos: 5, realtimeEntitled: true, tree: tree), .added)
      XCTAssertEqual(p.join(a, qos: 5, realtimeEntitled: true, tree: tree), .invalid)
      XCTAssertEqual(a.pointee.requestedQos, 5)
      var policy = tree.policy(tree.root)!
      policy.threadsPerProcess = 1
      XCTAssertTrue(tree.tighten(tree.root, to: policy))
      XCTAssertEqual(p.join(b, qos: 2, realtimeEntitled: false, tree: tree), .quota)
      XCTAssertEqual(p.phase, .created)
      XCTAssertEqual(p.gate(id, tree: tree), .hold)
      XCTAssertTrue(p.setSuspended(true))
      XCTAssertTrue(p.start(id, tree: tree))
      XCTAssertFalse(p.start(id, tree: tree))
      XCTAssertEqual(p.phase, .suspended)
      XCTAssertEqual(p.gate(id, tree: tree), .hold)
      XCTAssertTrue(tree.setFrozen(true, job: tree.root))
      XCTAssertTrue(p.setSuspended(false))
      XCTAssertEqual(p.gate(id, tree: tree), .hold)
      XCTAssertTrue(p.setBlocked(true, id: id))
      XCTAssertTrue(tree.setFrozen(false, job: tree.root))
      XCTAssertEqual(p.gate(id, tree: tree), .hold)
      XCTAssertTrue(p.setBlocked(false, id: id))
      XCTAssertEqual(p.gate(id, tree: tree), .dispatch)
      XCTAssertEqual(p.gate(other, tree: tree), .stop)
      XCTAssertTrue(
        p.stopped(id, code: -7, tree: tree, notify: { _ in }, retire: { _ in XCTFail() }))
      XCTAssertEqual(p.exit, TaskExit(.exited, code: -7))
      XCTAssertTrue(p.beginCleanup())
      XCTAssertTrue(p.finishCleanup(tree: tree, notify: { _ in }))
    }
  }
  func testExitStopsEveryThreadAndSignalsOnlyAfterResourceTeardown() {
    fixture { p, tree, a, b in
      let h = a.pointee.header
      let id = h.pointee.koid
      let other = b.pointee.header.pointee.koid
      XCTAssertEqual(p.join(a, qos: 3, realtimeEntitled: false, tree: tree), .added)
      XCTAssertEqual(p.join(b, qos: 2, realtimeEntitled: false, tree: tree), .added)
      XCTAssertTrue(p.start(id, tree: tree))
      XCTAssertTrue(tree.resizeFootprint(p.member, to: 4096))
      XCTAssertEqual(h.pointee.release(), .stillLive)
      var kicks: [UInt64] = []
      var observed: [UInt64] = []
      var retired: [UInt64] = []
      let notice: (UnsafePointer<ObjectHeader>) -> Void = { h in
        XCTAssertEqual(h.pointee.signals & 16, 16)
        observed.append(h.pointee.koid)
      }
      let retire: (UnsafePointer<ObjectHeader>) -> Void = { h in retired.append(h.pointee.koid) }
      XCTAssertTrue(
        p.requestExit(TaskExit(.killed, code: 9), tree: tree, stop: { kicks.append($0) }))
      XCTAssertEqual(kicks, [id, other])
      XCTAssertEqual(p.gate(id, tree: tree), .stop)
      XCTAssertFalse(
        p.requestExit(TaskExit(.crashed, code: -1), tree: tree, stop: { _ in XCTFail() }))
      XCTAssertFalse(p.beginCleanup())
      XCTAssertFalse(p.setSuspended(false))
      XCTAssertTrue(p.stopped(id, code: 10, tree: tree, notify: notice, retire: retire))
      XCTAssertEqual(retired, [id])
      XCTAssertEqual(a.pointee.exitCode, 10)
      XCTAssertFalse(p.stopped(id, code: 3, tree: tree, notify: notice, retire: retire))
      XCTAssertFalse(p.beginCleanup())
      XCTAssertTrue(p.stopped(other, code: 11, tree: tree, notify: notice, retire: retire))
      XCTAssertEqual(p.exit, TaskExit(.killed, code: 9))
      XCTAssertTrue(p.beginCleanup())
      XCTAssertFalse(p.beginCleanup())
      XCTAssertEqual(tree.usage(tree.root)?.footprint, 4096)
      XCTAssertEqual(p.header.pointee.signals & 16, 0)
      XCTAssertEqual(observed, [id, other])
      XCTAssertTrue(p.finishCleanup(tree: tree, notify: notice))
      XCTAssertEqual(observed, [id, other, p.member.id])
      XCTAssertEqual(tree.usage(tree.root)?.processes, 0)
      XCTAssertEqual(tree.usage(tree.root)?.footprint, 0)
      XCTAssertEqual(p.phase, .terminated)
      XCTAssertFalse(p.finishCleanup(tree: tree, notify: notice))
      XCTAssertFalse(p.beginCleanup())
    }
  }
  func testJobKillWinsBeforeLastExitAndBeforeFirstStart() {
    fixture { p, tree, a, _ in
      XCTAssertEqual(p.join(a, qos: 0, realtimeEntitled: false, tree: tree), .added)
      XCTAssertTrue(tree.kill(tree.root))
      let id = a.pointee.header.pointee.koid
      XCTAssertFalse(p.start(id, tree: tree))
      XCTAssertEqual(p.gate(id, tree: tree), .stop)
      XCTAssertTrue(
        p.stopped(id, code: 14, tree: tree, notify: { _ in }, retire: { _ in XCTFail() }))
      XCTAssertEqual(p.exit, TaskExit(.jobKilled, code: 0))
      XCTAssertTrue(p.beginCleanup())
      XCTAssertTrue(p.finishCleanup(tree: tree, notify: { _ in }))
    }
  }
  func testTightenedHandleBudgetAndExitDrainInvalidateOutstandingNames() {
    fixture { p, tree, a, _ in
      let header = a.pointee.header
      guard
        case .installed(let first)? = p.withHandles(tree: tree, { $0.install(header, rights: 0) }),
        case .installed(let second)? = p.withHandles(tree: tree, { $0.install(header, rights: 0) })
      else { return XCTFail() }
      var policy = tree.policy(tree.root)!
      policy.handlesPerProcess = 1
      XCTAssertTrue(tree.tighten(tree.root, to: policy))
      guard case .limit? = p.withHandles(tree: tree, { $0.install(header, rights: 0) }),
        case .installed(let replacement)? = p.withHandles(
          tree: tree, { $0.derive(first, rights: 0, duplicate: false) })
      else { return XCTFail("narrowing must not consume headroom") }
      XCTAssertEqual(header.pointee.release(), .stillLive)
      XCTAssertTrue(
        p.requestExit(TaskExit(.outOfMemory, code: 0), tree: tree, stop: { _ in XCTFail() }))
      XCTAssertNil(p.withHandles(tree: tree, { $0.count }))
      var names: [UInt64] = []
      var final: [UInt64] = []
      XCTAssertTrue(
        p.beginCleanup(invalidate: { names.append($0) }, retire: { final.append($0.pointee.koid) }))
      XCTAssertEqual(Set(names), Set([replacement, second]))
      XCTAssertEqual(final, [header.pointee.koid])
      if case .invalidHandle = p.handleReader.pinWithinEpoch(second, kind: 0, need: 0) {
      } else {
        XCTFail("exited table is empty")
      }
      XCTAssertEqual(p.header.pointee.signals & 16, 0)
      XCTAssertTrue(p.finishCleanup(tree: tree, notify: { _ in }))
    }
  }
}
