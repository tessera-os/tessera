import TarwinIPCChannels
import TarwinObject
import XCTest

final class StartupChannelTests: XCTestCase {
  func testEntryRequiresExactChildSoleHandleAndUndrainedMessage() {
    let ids = KoidSource()
    let heads = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 6)
    heads.initialize(
      to: ObjectHeader(source: ids, ownerJob: 0, kind: TarwinKind.job, maximumRights: 258)!)
    for (i, kind) in [
      TarwinKind.process, TarwinKind.process, TarwinKind.channel,
      TarwinKind.channel, TarwinKind.event,
    ].enumerated() {
      (heads + i + 1).initialize(
        to: ObjectHeader(
          source: ids, ownerJob: heads.pointee.koid,
          kind: kind, maximumRights: 7)!)
    }
    let jobs = UnsafeMutableBufferPointer<JobNode>.allocate(capacity: 1)
    let members = UnsafeMutableBufferPointer<JobMember>.allocate(capacity: 2)
    let slots = UnsafeMutableBufferPointer<ThreadSlot>.allocate(capacity: 2)
    let cells = UnsafeMutablePointer<HandleCell>.allocate(capacity: 8)
    let messages = UnsafeMutablePointer<ChannelSize>.allocate(capacity: 2)
    let grants = UnsafeMutablePointer<ObjectGrant>.allocate(capacity: 128)
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
    jobs.initialize(repeating: JobNode())
    members.initialize(repeating: JobMember())
    slots.initialize(repeating: ThreadSlot())
    messages.initialize(repeating: ChannelSize(), count: 2)
    let limits = JobLimits(
      processes: 2, threadsPerProcess: 1, handlesPerProcess: 3,
      footprint: 8192, cpuShare: 1, maxQos: 1, jetsamBand: 0, ioRank: 0, entitlements: 0,
      denials: 0, killOnClose: false)
    let tree = JobTree(jobs: jobs, members: members, root: heads.pointee, limits: limits)!
    func process(_ i: Int) -> ProcessExecution {
      ProcessExecution(
        header: .init(heads + 1 + i), job: tree.root, tree: tree,
        slots: .init(start: slots.baseAddress! + i, count: 1),
        cells: .init(start: cells + i * 3, count: 3), salt: 19)!
    }
    func queue(_ i: Int) -> ChannelQueue {
      ChannelQueue(
        lengths: .init(start: messages + i, count: 1),
        bytes: .init(start: bytes + 64 * i, count: 64),
        grants: .init(start: grants + 64 * i, count: 64))!
    }
    var p = process(0)
    var other = process(1)
    var staging = HandleTable(storage: .init(start: cells + 6, count: 2), salt: 3)!
    var pair = ChannelPair(a: .init(heads + 3), b: .init(heads + 4), toA: queue(0), toB: queue(1))!
    defer {
      pair.close(.a) { _ in XCTFail() }
      pair.close(.b) { _ in XCTFail() }
      staging.drain { _ in XCTFail() }
      _ = p.withHandles(tree: tree) { $0.drain { _ in XCTFail() } }
      _ = other.withHandles(tree: tree) { $0.drain { _ in XCTFail() } }
      for i in 0..<6 { XCTAssertEqual((heads + i).pointee.release(), .destroy) }
      heads.deinitialize(count: 6)
      heads.deallocate()
      jobs.deinitialize()
      jobs.deallocate()
      members.deinitialize()
      members.deallocate()
      slots.deinitialize()
      slots.deallocate()
      cells.deinitialize(count: 8)
      cells.deallocate()
      messages.deinitialize(count: 2)
      messages.deallocate()
      bytes.deallocate()
      grants.deallocate()
    }
    func install(_ tags: [UInt32], _ names: [UInt64]) -> ChildBootstrap? {
      var scratch = [UInt8](repeating: 0xaa, count: 64)
      return scratch.withUnsafeMutableBytes { s in
        tags.withUnsafeBufferPointer { t in
          names.withUnsafeBufferPointer { n in
            pair.preloadStartup(
              child: &p, tree: tree, app: 1, flags: 0, tags: t, names: n,
              staging: &staging, scratch: s, invalidate: { _ in }, retire: { _ in XCTFail() })
          }
        }
      }
    }
    guard case .installed(let denied) = staging.install(.init(heads), rights: 256),
      case .installed(let pass) = staging.install(.init(heads), rights: 258)
    else { return XCTFail() }
    XCTAssertNil(install([13], [denied]))
    XCTAssertEqual(p.withHandles(tree: tree) { $0.count }, 0)
    XCTAssertEqual(staging.count, 2)
    guard let token = install([13], [pass]),
      let name = pair.entryName(token, child: p, tree: tree)
    else { return XCTFail() }
    XCTAssertNil(install([], []))
    // Even an identical local integer bound to the same endpoint in a
    // sibling table cannot authorize a frame for that sibling.
    guard
      case .installed(let first)? = other.withHandles(
        tree: tree, { $0.install(.init(heads + 4), rights: 4) }),
      case .installed(let same)? = other.withHandles(
        tree: tree, { $0.derive(first, rights: 4, duplicate: false) })
    else { return XCTFail() }
    XCTAssertEqual(name, same)
    XCTAssertNil(pair.entryName(token, child: other, tree: tree))
    guard
      case .installed(let extra)? = p.withHandles(
        tree: tree, { $0.install(.init(heads + 5), rights: 0) })
    else { return XCTFail() }
    XCTAssertNil(pair.entryName(token, child: p, tree: tree))
    XCTAssertEqual(p.withHandles(tree: tree) { $0.close(extra) { _ in XCTFail() } }, true)
    XCTAssertEqual(pair.entryName(token, child: p, tree: tree), name)
    guard
      case .installed(let fresh)? = p.withHandles(
        tree: tree, { $0.derive(name, rights: 4, duplicate: false) })
    else { return XCTFail() }
    XCTAssertNotEqual(name, fresh)
    XCTAssertEqual(pair.peek(at: .b)?.handles, 1)
    XCTAssertNil(pair.entryName(token, child: p, tree: tree))
  }
}
