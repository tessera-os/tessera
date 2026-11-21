import TarwinIPCChannels
import TarwinObject
import Testing

@testable import TarwinW1Bootstrap

// A real private endpoint and a fresh child table, but no launched process.
func checkStartupFrame(
  _ images: borrowing W1PrivateImages, root: UInt64, accepted: Bool,
  stack: UnsafeMutableRawBufferPointer
) throws {
  let src = KoidSource()
  let heads = UnsafeMutableBufferPointer<ObjectHeader>.allocate(capacity: 5)
  let jobs = UnsafeMutableBufferPointer<JobNode>.allocate(capacity: 1)
  let members = UnsafeMutableBufferPointer<JobMember>.allocate(capacity: 1)
  let slots = UnsafeMutableBufferPointer<ThreadSlot>.allocate(capacity: 1)
  let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 3)
  let sizes = UnsafeMutableBufferPointer<ChannelSize>.allocate(capacity: 2)
  let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 192, alignment: 16)
  let grants = UnsafeMutableBufferPointer<ObjectGrant>.allocate(capacity: 128)
  defer {
    heads.deallocate()
    jobs.deallocate()
    members.deallocate()
    slots.deallocate()
    cells.deallocate()
    sizes.deallocate()
    bytes.deallocate()
    grants.deallocate()
  }
  jobs.initialize(repeating: JobNode())
  members.initialize(repeating: JobMember())
  slots.initialize(repeating: ThreadSlot())
  sizes.initialize(repeating: ChannelSize())
  let h = heads.baseAddress!
  h.initialize(to: ObjectHeader(source: src, ownerJob: 0, kind: TarwinKind.job, maximumRights: 0)!)
  for (i, k) in [TarwinKind.process, TarwinKind.channel, TarwinKind.channel, TarwinKind.event]
    .enumerated()
  {
    (h + i + 1).initialize(
      to: ObjectHeader(source: src, ownerJob: h.pointee.koid, kind: k, maximumRights: 7)!)
  }
  defer {
    for i in 0..<heads.count { _ = (h + i).pointee.release() }
    heads.deinitialize()
    sizes.deinitialize()
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
  let tableCells = UnsafeMutableBufferPointer(start: cells.baseAddress, count: 2)
  let process =
    accepted
    ? images.createChild(
      header: .init(h + 1), job: tree.root, tree: tree, slots: slots,
      cells: tableCells, salt: 7)
    : ProcessExecution(
      header: .init(h + 1), job: tree.root, tree: tree, slots: slots,
      cells: tableCells, salt: 7, initialMap: root)
  guard var child = consume process,
    var staging = HandleTable(storage: .init(start: cells.baseAddress! + 2, count: 1), salt: 1)
  else {
    Issue.record("invalid child setup")
    return
  }
  defer {
    staging.drain { _ in }
    _ = child.withHandles(tree: tree) { $0.drain { _ in } }
    cells.deinitialize()
  }
  func queue(_ i: Int) -> ChannelQueue {
    ChannelQueue(
      lengths: .init(rebasing: sizes[i...i]), bytes: .init(rebasing: bytes[64 * i..<64 * (i + 1)]),
      grants: .init(start: grants.baseAddress! + 64 * i, count: 64))!
  }
  var pair = ChannelPair(a: .init(h + 2), b: .init(h + 3), toA: queue(0), toB: queue(1))!
  defer { pair.close(.b) { _ in } }
  let scratch = UnsafeMutableRawBufferPointer(rebasing: bytes[128...])
  let none = UnsafeBufferPointer<UInt64>(start: nil, count: 0)
  guard case .installed(let event) = staging.install(.init(h + 4), rights: 2) else {
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
  #expect(frame.gpr[0] == pair.entryName(boot, child: child, tree: tree, initialMap: root))
  try checkPinnedReceive(images, stack: stack, child: &child, pair: &pair, tree: tree)
  let consumed = images.initialFrame(boot, child: child, tree: tree, channel: pair)
  #expect(consumed == nil)
}
