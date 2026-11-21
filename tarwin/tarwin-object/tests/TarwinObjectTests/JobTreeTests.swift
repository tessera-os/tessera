import TarwinObject
import XCTest

private let ceiling = JobLimits(
  processes: 3, threadsPerProcess: 4, handlesPerProcess: 32,
  footprint: .max, cpuShare: 80, maxQos: 4, jetsamBand: 4, ioRank: 3, entitlements: 0b1111,
  denials: 0, killOnClose: false)

private func graph(_ body: (borrowing JobTree, borrowing KoidSource) -> Void) {
  let jobs = UnsafeMutableBufferPointer<JobNode>.allocate(capacity: 5)
  let members = UnsafeMutableBufferPointer<JobMember>.allocate(capacity: 5)
  jobs.initialize(repeating: JobNode())
  members.initialize(repeating: JobMember())
  defer {
    jobs.deinitialize()
    members.deinitialize()
    jobs.deallocate()
    members.deallocate()
  }
  let source = KoidSource()
  let root = ObjectHeader(source: source, ownerJob: 0, kind: TarwinKind.job, maximumRights: 0)!
  let tree = JobTree(jobs: jobs, members: members, root: root, limits: ceiling)!
  body(tree, source)
}
private func header(_ ids: borrowing KoidSource, _ owner: JobKey, _ kind: UInt32) -> ObjectHeader {
  ObjectHeader(source: ids, ownerJob: owner.id, kind: kind, maximumRights: 0)!
}

final class JobTreeTests: XCTestCase {
  func testAncestorProcessAndFootprintReservationsAreAtomic() {
    graph { tree, ids in
      let branch = tree.create(
        header(ids, tree.root, TarwinKind.job), under: tree.root, policy: ceiling)!
      let a = tree.attach(header(ids, branch, TarwinKind.process), to: branch)!
      let b = tree.attach(header(ids, tree.root, TarwinKind.process), to: tree.root)!
      XCTAssertTrue(tree.resizeFootprint(a, to: .max - 4))
      XCTAssertTrue(tree.resizeFootprint(b, to: 4))
      XCTAssertFalse(tree.resizeFootprint(a, to: .max - 3))
      XCTAssertEqual(tree.usage(tree.root)?.footprint, .max)
      XCTAssertEqual(tree.usage(branch)?.footprint, .max - 4)
      let c = tree.attach(header(ids, branch, TarwinKind.process), to: branch)!
      XCTAssertNil(tree.attach(header(ids, branch, TarwinKind.process), to: branch))
      XCTAssertEqual(tree.usage(branch)?.processes, 2)
      var lower = ceiling
      lower.footprint = 10
      lower.processes = 1
      XCTAssertTrue(tree.tighten(tree.root, to: lower))
      XCTAssertTrue(tree.resizeFootprint(a, to: 7))
      XCTAssertFalse(tree.resizeFootprint(b, to: 5))
      XCTAssertTrue(tree.detach(b))
      XCTAssertTrue(tree.resizeFootprint(a, to: 10))
      XCTAssertFalse(tree.detach(b))
      XCTAssertTrue(tree.detach(a))
      XCTAssertTrue(tree.detach(c))
      XCTAssertEqual(tree.usage(tree.root)?.processes, 0)
      XCTAssertEqual(tree.usage(tree.root)?.footprint, 0)
    }
  }

  func testInheritedCeilingsAndDenialsSurviveIndependentChildChanges() {
    graph { tree, ids in
      var lower = ceiling
      lower.ioRank = 2
      lower.jetsamBand = 2
      lower.entitlements = 3
      lower.killOnClose = true
      lower.denials = 2
      let child = tree.create(
        header(ids, tree.root, TarwinKind.job), under: tree.root, policy: lower)!
      let grand = tree.create(header(ids, child, TarwinKind.job), under: child, policy: lower)!
      for invalid in [
        { (p: inout JobLimits) in p.ioRank += 1 }, { $0.jetsamBand += 1 }, { $0.entitlements |= 4 },
        { $0.killOnClose = false }, { $0.denials = 0 }, { $0.threadsPerProcess += 1 },
        { $0.maxQos += 1 },
        { $0.handlesPerProcess += 1 }, { $0.cpuShare += 1 }, { $0.denials = 8 },
      ] {
        var policy = lower
        invalid(&policy)
        XCTAssertFalse(tree.tighten(child, to: policy))
        XCTAssertNil(tree.create(header(ids, child, TarwinKind.job), under: child, policy: policy))
      }
      var p = ceiling
      p.entitlements = 5
      p.cpuShare = 3
      p.denials = 1
      XCTAssertTrue(tree.tighten(tree.root, to: p))
      let effective = tree.policy(grand)!
      XCTAssertEqual(effective.entitlements, 1)
      XCTAssertEqual(effective.denials, 3)
      XCTAssertEqual(effective.cpuShare, 3)
      XCTAssertTrue(effective.killOnClose)
      XCTAssertNil(tree.attach(header(ids, grand, TarwinKind.process), to: grand))
    }
  }

  func testFreezeThawAndKillTraverseOnlyAffectedSubtrees() {
    graph { tree, ids in
      var p = ceiling
      p.killOnClose = true
      let child = tree.create(header(ids, tree.root, TarwinKind.job), under: tree.root, policy: p)!
      let grand = tree.create(header(ids, child, TarwinKind.job), under: child, policy: p)!
      let a = tree.attach(header(ids, grand, TarwinKind.process), to: grand)!
      let b = tree.attach(header(ids, tree.root, TarwinKind.process), to: tree.root)!
      XCTAssertTrue(tree.setFrozen(true, job: tree.root))
      XCTAssertTrue(tree.setFrozen(true, job: child))
      XCTAssertTrue(tree.setFrozen(false, job: tree.root))
      XCTAssertEqual(tree.returnGate(a), .frozen)
      XCTAssertEqual(tree.returnGate(b), .run)
      tree.lastHandleClosed(tree.root)
      XCTAssertEqual(tree.returnGate(b), .run)
      var visits: [ProcessKey] = []
      tree.visitMembers(of: child) { visits.append($0) }
      XCTAssertEqual(visits, [a])
      tree.lastHandleClosed(child)
      XCTAssertFalse(tree.setFrozen(false, job: grand))
      XCTAssertEqual(tree.returnGate(a), .terminate)
      XCTAssertEqual(tree.returnGate(b), .run)
      XCTAssertNil(tree.attach(header(ids, grand, TarwinKind.process), to: grand))
      XCTAssertNil(tree.create(header(ids, grand, TarwinKind.job), under: grand, policy: p))
      XCTAssertFalse(tree.resizeFootprint(a, to: 1))
      XCTAssertTrue(tree.detach(a))
      XCTAssertFalse(tree.remove(child))
      XCTAssertTrue(tree.remove(grand))
      XCTAssertTrue(tree.remove(child))
    }
  }

  func testStaleKeysAndWrongObjectOwnersCannotAffectReplacement() {
    graph { tree, ids in
      let h = header(ids, tree.root, TarwinKind.job)
      let child = tree.create(h, under: tree.root, policy: ceiling)!
      XCTAssertNil(tree.create(h, under: tree.root, policy: ceiling))
      XCTAssertNil(tree.attach(h, to: tree.root))
      XCTAssertNil(tree.attach(header(ids, tree.root, TarwinKind.process), to: child))
      let a = tree.attach(header(ids, child, TarwinKind.process), to: child)!
      XCTAssertFalse(tree.remove(child))
      XCTAssertTrue(tree.detach(a))
      XCTAssertTrue(tree.remove(child))
      let repl = tree.create(
        header(ids, tree.root, TarwinKind.job), under: tree.root, policy: ceiling)!
      let b = tree.attach(header(ids, repl, TarwinKind.process), to: repl)!
      XCTAssertNil(tree.policy(child))
      XCTAssertFalse(tree.kill(child))
      XCTAssertFalse(tree.detach(a))
      XCTAssertFalse(tree.resizeFootprint(a, to: 5))
      XCTAssertEqual(tree.returnGate(a), .terminate)
      XCTAssertEqual(tree.returnGate(b), .run)
      XCTAssertFalse(tree.remove(tree.root))
    }
  }

  func testLaunchRollbackDoesNotReviveOutstandingKeysToTheSameObject() {
    graph { tree, ids in
      let h = header(ids, tree.root, TarwinKind.job)
      let first = tree.create(h, under: tree.root, policy: ceiling)!
      let obj = header(ids, first, TarwinKind.process)
      let ticket = tree.attach(obj, to: first)!
      XCTAssertTrue(tree.detach(ticket))
      XCTAssertTrue(tree.remove(first))
      let second = tree.create(h, under: tree.root, policy: ceiling)!
      let retry = tree.attach(obj, to: second)!
      XCTAssertNotEqual(ticket, retry)
      XCTAssertNotEqual(first, second)
      XCTAssertFalse(tree.kill(first))
      XCTAssertFalse(tree.detach(ticket))
      XCTAssertEqual(tree.returnGate(retry), .run)
    }
  }
}
