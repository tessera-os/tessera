import TarwinKernelRandom
import TarwinObject
import TarwinProcessKeys
import TarwinRandomCore
import XCTest

private func withChild(
  _ ids: borrowing KoidSource, _ tree: borrowing JobTree, _ root: UInt64,
  _ body: (inout ProcessExecution) -> Void
) {
  let h = ObjectHeader(
    source: ids, ownerJob: tree.root.id, kind: TarwinKind.process, maximumRights: 0)!
  var slots = [ThreadSlot(), ThreadSlot()]
  let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 1)
  defer {
    cells.deinitialize()
    cells.deallocate()
  }
  withUnsafePointer(to: h) { header in
    slots.withUnsafeMutableBufferPointer { storage in
      var child = ProcessExecution(
        header: header, job: tree.root, tree: tree, slots: storage, cells: cells, salt: 2,
        initialMap: root)!
      body(&child)
    }
  }
}

final class ProcessKeyTests: XCTestCase {
  func testRestoredVMCannotReviveAnIssuedBank() {
    let issued = RandomEpoch.virtualMachine(low: 4, high: 9)
    let invalid: [RandomEpoch?] = [
      nil, .physical, .virtualMachine(low: 0, high: 0),
      .virtualMachine(low: 5, high: 9), .virtualMachine(low: 4, high: 10),
    ]
    for observed in invalid {
      for retireBeforeStart in [true, false] {
        let ids = KoidSource()
        let job = ObjectHeader(source: ids, ownerJob: 0, kind: TarwinKind.job, maximumRights: 0)!
        var nodes = [JobNode()]
        var members = [JobMember()]
        let limits = JobLimits(
          processes: 1, threadsPerProcess: 2, handlesPerProcess: 4, footprint: 4096, cpuShare: 1,
          maxQos: 1, jetsamBand: 1, ioRank: 1, entitlements: 0, denials: 0, killOnClose: false)
        nodes.withUnsafeMutableBufferPointer { jobs in
          members.withUnsafeMutableBufferPointer { slots in
            let tree = JobTree(jobs: jobs, members: slots, root: job, limits: limits)!
            let root: UInt64 = 0x4000
            withChild(ids, tree, root) { child in
              var storage = [UInt64](repeating: 0, count: 10)
              storage.withUnsafeMutableBufferPointer { bank in
                [UInt8](0..<96).withUnsafeBytes { seed in
                  let sample = UnsafeRawBufferPointer(rebasing: seed[64...])
                  var rng = KernelRandom(
                    policy: .debugQEMU, bootSeed: .init(rebasing: seed[..<64]), hardware: sample,
                    source: .emulatedTPM, generation: issued)!
                  guard
                    let keys = ArmProcessKeys(
                      child: &child, root: root, tree: tree, storage: bank, random: &rng,
                      generation: issued)
                  else { return XCTFail() }
                  var borrows = 0
                  func sign(_ epoch: RandomEpoch?) -> UInt64? {
                    keys.withImportIA(child: child, root: root, tree: tree, current: { epoch }) {
                      _ in
                      borrows += 1
                      return 1
                    }
                  }
                  XCTAssertEqual(sign(issued), 1)
                  if retireBeforeStart {
                    XCTAssertNil(sign(observed))
                    XCTAssertNil(sign(issued))
                  }
                  let header = ObjectHeader(
                    source: ids, ownerJob: job.koid, kind: TarwinKind.thread, maximumRights: 0)!
                  withUnsafePointer(to: header) { h in
                    var t = ThreadExecution(header: h, process: child.member, job: tree.root)!
                    withUnsafeMutablePointer(to: &t) { th in
                      XCTAssertEqual(
                        child.join(th, qos: 0, realtimeEntitled: false, tree: tree), .added)
                      XCTAssertTrue(child.start(h.pointee.koid, tree: tree))
                      func install(_ epoch: RandomEpoch?) -> Bool {
                        keys.withThreadKeys(
                          child: child, thread: th.pointee, root: root,
                          tree: tree, current: { epoch }
                        ) { _ in
                          borrows += 1
                          return true
                        }
                      }
                      XCTAssertEqual(install(issued), !retireBeforeStart)
                      XCTAssertFalse(install(observed))
                      XCTAssertTrue(
                        rng.reseed(hardware: sample, source: .emulatedTPM, generation: issued))
                      XCTAssertFalse(install(issued))
                    }
                  }
                  XCTAssertEqual(borrows, retireBeforeStart ? 1 : 2)
                }
                XCTAssertTrue(bank.allSatisfy { $0 == 0 })
              }
            }
          }
        }
      }
    }
  }

  func testOwnerGatesFreshnessAndErase() {
    let ids = KoidSource()
    let j = ObjectHeader(source: ids, ownerJob: 0, kind: TarwinKind.job, maximumRights: 0)!
    var nodes = [JobNode()]
    var members = [JobMember(), JobMember()]
    let limits = JobLimits(
      processes: 2, threadsPerProcess: 2, handlesPerProcess: 4, footprint: 4096, cpuShare: 1,
      maxQos: 1, jetsamBand: 1, ioRank: 1, entitlements: 0, denials: 0, killOnClose: false)
    let bank = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: 10)
    let other = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: 10)
    bank.initialize(repeating: 0)
    other.initialize(repeating: 0)
    defer {
      bank.deinitialize()
      bank.deallocate()
      other.deinitialize()
      other.deallocate()
    }
    nodes.withUnsafeMutableBufferPointer { jobs in
      members.withUnsafeMutableBufferPointer { slots in
        let tree = JobTree(jobs: jobs, members: slots, root: j, limits: limits)!
        let root: UInt64 = 0x4000
        withChild(ids, tree, root) { child in
          withChild(ids, tree, root) { sibling in
            [UInt8](0..<96).withUnsafeBytes { seed in
              let sample = UnsafeRawBufferPointer(rebasing: seed[64...])
              var rng = KernelRandom(
                policy: .certified, bootSeed: .init(rebasing: seed[..<64]), hardware: sample,
                source: .physicalHardware, generation: .physical)!
              func issue(
                _ p: inout ProcessExecution, root r: UInt64,
                _ b: UnsafeMutableBufferPointer<UInt64>,
                _ epoch: RandomEpoch? = .physical
              ) -> ArmProcessKeys? {
                ArmProcessKeys(
                  child: &p, root: r, tree: tree, storage: b, random: &rng, generation: epoch)
              }
              XCTAssertTrue(issue(&child, root: root + 1, bank) == nil)
              XCTAssertTrue(
                issue(&child, root: root, .init(start: bank.baseAddress, count: 9)) == nil)
              XCTAssertTrue(issue(&child, root: root, bank, nil) == nil)
              XCTAssertTrue(bank.allSatisfy { $0 == 0 })
              XCTAssertTrue(
                rng.reseed(hardware: sample, source: .physicalHardware, generation: .physical))
              guard let keys = issue(&child, root: root, bank) else { return XCTFail() }
              let budget = rng.remainingBlocks
              XCTAssertTrue(issue(&child, root: root, other) == nil)
              XCTAssertEqual(rng.remainingBlocks, budget)
              guard let peer = issue(&sibling, root: root, other) else { return XCTFail() }
              XCTAssertTrue(
                (0..<5).allSatisfy {
                  bank[2 * $0] != other[2 * $0] || bank[2 * $0 + 1] != other[2 * $0 + 1]
                })
              XCTAssertNil(
                keys.withImportIA(child: sibling, root: root, tree: tree, current: { .physical }) {
                  _ in
                  XCTFail()
                  return 1
                })
              XCTAssertNil(
                keys.withImportIA(child: child, root: root + 1, tree: tree, current: { .physical })
                { _ in
                  XCTFail()
                  return 1
                })
              XCTAssertEqual(
                keys.withImportIA(child: child, root: root, tree: tree, current: { .physical }) {
                  $0.count == 2 && $0.baseAddress == UnsafePointer(bank.baseAddress) ? 7 : nil
                }, 7)
              XCTAssertNil(
                keys.withImportIA(child: child, root: root, tree: tree, current: { .physical }) {
                  _ in nil
                })
              XCTAssertTrue(tree.setFrozen(true, job: tree.root))
              XCTAssertNil(
                keys.withImportIA(child: child, root: root, tree: tree, current: { .physical }) {
                  _ in
                  XCTFail()
                  return 1
                })
              XCTAssertTrue(tree.setFrozen(false, job: tree.root))
              peer.retire()
              XCTAssertNil(
                peer.withImportIA(child: sibling, root: root, tree: tree, current: { .physical }) {
                  _ in
                  XCTFail("retired bank borrowed")
                  return 1
                })
              peer.erase()
              XCTAssertTrue(other.allSatisfy { $0 == 0 })
              XCTAssertTrue(issue(&sibling, root: root, other) == nil)
              let th = ObjectHeader(
                source: ids, ownerJob: j.koid, kind: TarwinKind.thread, maximumRights: 0)!
              withUnsafePointer(to: th) { h in
                var t = ThreadExecution(header: h, process: child.member, job: tree.root)!
                withUnsafeMutablePointer(to: &t) { thread in
                  func canInstall() -> Bool {
                    keys.withThreadKeys(
                      child: child, thread: thread.pointee, root: root, tree: tree,
                      current: { .physical }
                    ) {
                      $0.count == 10 && $0.baseAddress == UnsafePointer(bank.baseAddress)
                    }
                  }
                  XCTAssertFalse(canInstall())
                  XCTAssertEqual(
                    child.join(thread, qos: 0, realtimeEntitled: false, tree: tree), .added)
                  XCTAssertFalse(canInstall())
                  XCTAssertTrue(child.start(th.koid, tree: tree))
                  XCTAssertTrue(canInstall())
                  XCTAssertNil(
                    keys.withImportIA(child: child, root: root, tree: tree, current: { .physical })
                    { _ in
                      XCTFail()
                      return 1
                    })
                  XCTAssertTrue(child.setSuspended(true))
                  XCTAssertFalse(canInstall())
                  XCTAssertTrue(child.setSuspended(false))
                  XCTAssertTrue(child.requestExit(.init(.exited, code: 0), tree: tree) { _ in })
                  XCTAssertFalse(canInstall())
                  XCTAssertTrue(
                    child.stopped(th.koid, code: 0, tree: tree, notify: { _ in }, retire: { _ in }))
                }
              }
            }
            // Implicit destruction also scrubs the full bank.
            XCTAssertTrue(bank.allSatisfy { $0 == 0 })
          }
        }
      }
    }
  }
}
