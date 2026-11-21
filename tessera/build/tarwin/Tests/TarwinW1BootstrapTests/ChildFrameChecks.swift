import TarwinIPCChannels
import TarwinObject
import Testing

@testable import TarwinW1Bootstrap

func withTestChild(
  root: UInt64, ids: borrowing KoidSource,
  _ run: (inout ProcessExecution, borrowing JobTree) throws -> Void
) throws {
  let heads = UnsafeMutableBufferPointer<ObjectHeader>.allocate(capacity: 2)
  let jobs = UnsafeMutableBufferPointer<JobNode>.allocate(capacity: 1)
  let members = UnsafeMutableBufferPointer<JobMember>.allocate(capacity: 1)
  let slots = UnsafeMutableBufferPointer<ThreadSlot>.allocate(capacity: 1)
  let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 2)
  defer {
    heads.deallocate()
    jobs.deallocate()
    members.deallocate()
    slots.deallocate()
    cells.deallocate()
  }
  jobs.initialize(repeating: JobNode())
  members.initialize(repeating: JobMember())
  slots.initialize(repeating: ThreadSlot())
  let h = heads.baseAddress!
  h.initialize(to: ObjectHeader(source: ids, ownerJob: 0, kind: TarwinKind.job, maximumRights: 0)!)
  (h + 1).initialize(
    to: ObjectHeader(
      source: ids, ownerJob: h.pointee.koid, kind: TarwinKind.process, maximumRights: 7)!)
  defer {
    for i in 0..<heads.count { _ = (h + i).pointee.release() }
    heads.deinitialize()
    slots.deinitialize()
    members.deinitialize()
    jobs.deinitialize()
  }
  let limits = JobLimits(
    processes: 1, threadsPerProcess: 1, handlesPerProcess: 2,
    footprint: 1 << 20, cpuShare: 1, maxQos: 1, jetsamBand: 0, ioRank: 0, entitlements: 0,
    denials: 0, killOnClose: false)
  guard let tree = JobTree(jobs: jobs, members: members, root: h.pointee, limits: limits) else {
    Issue.record("invalid tree")
    return
  }
  guard
    var child = ProcessExecution(
      header: .init(h + 1), job: tree.root, tree: tree, slots: slots,
      cells: cells, salt: 7, initialMap: root)
  else {
    Issue.record("invalid child setup")
    return
  }
  defer {
    _ = child.withHandles(tree: tree) { $0.drain { _ in } }
    cells.deinitialize()
  }
  try run(&child, tree)
}

// A real private endpoint and child table, but no launched process.
func checkStartupFrame(
  _ images: borrowing W1PrivateImages, child: inout ProcessExecution, tree: borrowing JobTree,
  ids: borrowing KoidSource, accepted: Bool, stack: UnsafeMutableRawBufferPointer
) throws {
  let heads = UnsafeMutableBufferPointer<ObjectHeader>.allocate(capacity: 3)
  let sizes = UnsafeMutableBufferPointer<ChannelSize>.allocate(capacity: 2)
  let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 192, alignment: 16)
  let grants = UnsafeMutableBufferPointer<ObjectGrant>.allocate(capacity: 128)
  let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 1)
  let h = heads.baseAddress!
  for (i, kind) in [TarwinKind.channel, TarwinKind.channel, TarwinKind.event].enumerated() {
    (h + i).initialize(
      to: ObjectHeader(
        source: ids, ownerJob: child.job.id, kind: kind, maximumRights: 7)!)
  }
  sizes.initialize(repeating: ChannelSize())
  var staging = HandleTable(storage: cells, salt: 1)!
  defer {
    staging.drain { _ in }
    _ = child.withHandles(tree: tree) { $0.drain { _ in } }
    cells.deinitialize()
    for i in heads.indices { _ = (h + i).pointee.release() }
    heads.deinitialize()
    sizes.deinitialize()
    heads.deallocate()
    sizes.deallocate()
    bytes.deallocate()
    grants.deallocate()
    cells.deallocate()
  }
  func queue(_ i: Int) -> ChannelQueue {
    ChannelQueue(
      lengths: .init(rebasing: sizes[i...i]), bytes: .init(rebasing: bytes[64 * i..<64 * (i + 1)]),
      grants: .init(start: grants.baseAddress! + 64 * i, count: 64))!
  }
  var pair = ChannelPair(a: .init(h), b: .init(h + 1), toA: queue(0), toB: queue(1))!
  defer { pair.close(.b) { _ in } }
  let scratch = UnsafeMutableRawBufferPointer(rebasing: bytes[128...])
  let none = UnsafeBufferPointer<UInt64>(start: nil, count: 0)
  guard case .installed(let event) = staging.install(.init(h + 2), rights: 2) else {
    Issue.record("missing transferable startup handle")
    return
  }
  let ticket = withUnsafePointer(to: event) { name in
    withUnsafePointer(to: UInt32(13)) { tag in
      images.preloadStartup(
        child: &child, tree: tree, channel: &pair, app: 1, flags: 0,
        tags: .init(start: tag, count: 1), names: .init(start: name, count: 1), staging: &staging,
        scratch: scratch,
        invalidate: { _ in }, retire: { _ in })
    }
  }
  #expect((ticket != nil) == accepted)
  let token: ChildBootstrap?
  if accepted {
    token = ticket
  } else {
    #expect(pair.peek(at: .b) == nil)
    #expect(child.withHandles(tree: tree) { $0.count } == 0)
    // A valid token for the other task/root still cannot build this frame.
    token = pair.preloadStartup(
      child: &child, tree: tree, app: 1, flags: 0,
      tags: .init(start: nil, count: 0), names: none, staging: &staging, scratch: scratch,
      invalidate: { _ in }, retire: { _ in })
  }
  let boot = try #require(token)
  let frame = images.initialFrame(boot, child: child, tree: tree, channel: pair)
  #expect((frame != nil) == accepted)
  guard accepted, let frame, let thread = images.initialThread else { return }
  #expect(
    frame.elr == images.processEntry && frame.tpidr == thread.tcb
      && frame.sp == thread.stack.upperBound)
  #expect(
    frame.gpr[0]
      == pair.entryName(boot, child: child, tree: tree, initialMap: images.tables.physicalRoot))
  try checkPinnedReceive(images, stack: stack, child: &child, pair: &pair, tree: tree)
  let consumed = images.initialFrame(boot, child: child, tree: tree, channel: pair)
  #expect(consumed == nil)
  try checkStopAcknowledgment(child: &child, tree: tree, ids: ids)
}
