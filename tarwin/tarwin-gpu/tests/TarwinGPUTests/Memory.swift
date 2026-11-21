import TarwinGPU
import TarwinObject
import XCTest

private func accounting(
  _ body: (
    inout ProcessExecution, inout HandleTable, inout JobTree, JobKey, ProcessKey,
    UnsafePointer<ObjectHeader>
  ) -> Void
) {
  let ids = KoidSource()
  let policy = JobLimits(
    processes: 4, threadsPerProcess: 2, handlesPerProcess: 8,
    footprint: 16384, cpuShare: 50, maxQos: 3, jetsamBand: 3, ioRank: 2,
    entitlements: 0, denials: 0, killOnClose: false)
  let root = ObjectHeader(source: ids, ownerJob: 0, kind: TarwinKind.job, maximumRights: 0)!
  let jobs = UnsafeMutableBufferPointer<JobNode>.allocate(capacity: 2)
  let members = UnsafeMutableBufferPointer<JobMember>.allocate(capacity: 2)
  let threads = UnsafeMutableBufferPointer<ThreadSlot>.allocate(capacity: 1)
  jobs.initialize(repeating: JobNode())
  members.initialize(repeating: JobMember())
  threads.initialize(repeating: ThreadSlot())
  var tree = JobTree(jobs: jobs, members: members, root: root, limits: policy)!
  let child = tree.create(
    ObjectHeader(
      source: ids, ownerJob: tree.root.id, kind: TarwinKind.job,
      maximumRights: 0)!, under: tree.root, policy: policy)!
  func object(_ job: JobKey) -> UnsafeMutablePointer<ObjectHeader> {
    let h = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
    h.initialize(
      to: ObjectHeader(
        source: ids, ownerJob: job.id, kind: TarwinKind.process,
        maximumRights: 0x300)!)
    return h
  }
  let h = object(child)
  let sibling = object(tree.root)
  let c = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 1)
  let d = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 4)
  var client = ProcessExecution(
    header: h, job: child, tree: tree, slots: threads, cells: c, salt: 1)!
  let siblingKey = tree.attach(sibling.pointee, to: tree.root)!
  var driver = HandleTable(storage: d, salt: 2)!
  body(&client, &driver, &tree, child, siblingKey, UnsafePointer(sibling))
  driver.drain { _ in XCTFail("unexpected final reference") }
  _ = tree.detach(client.member)
  _ = tree.detach(siblingKey)
  for p in [h, sibling] {
    XCTAssertEqual(p.pointee.release(), .destroy)
    p.deinitialize(count: 1)
    p.deallocate()
  }
  c.deinitialize()
  c.deallocate()
  d.deinitialize()
  d.deallocate()
  jobs.deinitialize()
  jobs.deallocate()
  members.deinitialize()
  members.deallocate()
  threads.deinitialize()
  threads.deallocate()
}

final class MemoryTests: XCTestCase {
  func testChargesAccumulateAtAncestorsAndOutliveDriverHandles() {
    accounting { client, driver, tree, child, sibling, _ in
      guard case .installed(let name) = driver.install(client.header, rights: 0x200) else {
        return XCTFail()
      }
      let noRetire: (UnsafePointer<ObjectHeader>) -> Void = { _ in XCTFail() }
      var gpu = GpuFootprint(member: client.member, limit: .max, objectLimit: 2)
      var system = GpuAllocation(id: 7, bytes: 4096, backing: .system)!
      var local = GpuAllocation(id: 8, bytes: 8192, backing: .deviceLocal)!
      var extra = GpuAllocation(id: 9, bytes: 1, backing: .deviceLocal)!
      XCTAssertTrue(tree.resizeFootprint(client.member, to: 2048))
      XCTAssertTrue(tree.resizeFootprint(sibling, to: 8192))
      func charge(_ a: inout GpuAllocation) -> Bool {
        gpu.charge(
          &a, client: client, name: name, driver: driver.reader, nonGpu: 2048, tree: tree,
          retire: noRetire)
      }
      XCTAssertTrue(charge(&system))
      XCTAssertFalse(charge(&system))
      XCTAssertFalse(charge(&local))  // Sibling consumes room at root, but not at child.
      XCTAssertEqual(gpu.used, 4096)
      XCTAssertEqual(gpu.count, 1)
      XCTAssertEqual(tree.usage(child)?.footprint, 6144)
      XCTAssertEqual(tree.usage(tree.root)?.footprint, 14336)
      XCTAssertTrue(tree.resizeFootprint(sibling, to: 0))
      XCTAssertTrue(charge(&local))
      XCTAssertFalse(charge(&extra))
      XCTAssertTrue(driver.close(name, retire: noRetire))
      XCTAssertFalse(gpu.release(&system, nonGpu: 2048, tree: tree, isRetired: { _ in false }))
      XCTAssertEqual(tree.usage(child)?.footprint, 14336)
      // VM has since acquired more private memory; preserve that charge.
      XCTAssertTrue(tree.resizeFootprint(client.member, to: 15360))
      XCTAssertTrue(gpu.release(&system, nonGpu: 3072, tree: tree, isRetired: { $0 == 7 }))
      XCTAssertFalse(
        gpu.release(
          &system, nonGpu: 3072, tree: tree,
          isRetired: { _ in
            XCTFail()
            return true
          }))
      XCTAssertEqual(tree.usage(child)?.footprint, 11264)
      XCTAssertTrue(gpu.release(&local, nonGpu: 3072, tree: tree, isRetired: { $0 == 8 }))
      XCTAssertEqual(tree.usage(tree.root)?.footprint, 3072)
      XCTAssertEqual(gpu.used, 0)
    }
  }
  func testOnlyLiveManageHandleForLedgerOwnerCanCharge() {
    accounting { client, driver, tree, child, sibling, siblingHeader in
      guard case .installed(let wrong) = driver.install(siblingHeader, rights: 0x200),
        case .installed(let inspect) = driver.install(client.header, rights: 0x100),
        case .installed(let name) = driver.install(client.header, rights: 0x200)
      else { return XCTFail() }
      var gpu = GpuFootprint(member: client.member, limit: 100, objectLimit: 2)
      var other = GpuFootprint(member: sibling, limit: 100, objectLimit: 2)
      var a = GpuAllocation(id: 5, bytes: 100, backing: .deviceLocal)!
      var b = GpuAllocation(id: 6, bytes: 1, backing: .system)!
      let retire: (UnsafePointer<ObjectHeader>) -> Void = { _ in XCTFail() }
      func charge(_ n: UInt64, _ nonGpu: UInt64) -> Bool {
        gpu.charge(
          &a, client: client, name: n, driver: driver.reader, nonGpu: nonGpu, tree: tree,
          retire: retire)
      }
      XCTAssertFalse(charge(wrong, 0))
      XCTAssertFalse(charge(inspect, 0))
      XCTAssertFalse(charge(name, .max))
      XCTAssertEqual(tree.usage(child)?.footprint, 0)
      XCTAssertTrue(charge(name, 0))
      XCTAssertFalse(
        gpu.charge(
          &b, client: client, name: name, driver: driver.reader, nonGpu: 0, tree: tree,
          retire: retire))
      XCTAssertFalse(
        other.release(
          &a, nonGpu: 0, tree: tree,
          isRetired: { _ in
            XCTFail()
            return true
          }))
      XCTAssertTrue(gpu.release(&a, nonGpu: 0, tree: tree, isRetired: { _ in true }))
      XCTAssertFalse(charge(name, 0))  // Retired allocation cannot be resurrected.
      XCTAssertTrue(driver.close(name, retire: retire))
      guard case .installed(let live) = driver.install(client.header, rights: 0x200) else {
        return XCTFail()
      }
      XCTAssertNotEqual(live, name)
      XCTAssertFalse(
        gpu.charge(
          &b, client: client, name: name, driver: driver.reader, nonGpu: 0, tree: tree,
          retire: retire))
      XCTAssertTrue(tree.kill(child))
      XCTAssertFalse(
        gpu.charge(
          &b, client: client, name: live, driver: driver.reader, nonGpu: 0, tree: tree,
          retire: retire))
      XCTAssertEqual(gpu.count, 0)
      XCTAssertEqual(tree.usage(tree.root)?.footprint, 0)
    }
  }
}
