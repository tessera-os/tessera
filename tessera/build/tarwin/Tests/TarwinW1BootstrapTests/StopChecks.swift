import TarwinArchAarch64
import TarwinObject
import TarwinW1Bootstrap
import Testing

func checkStopAcknowledgment(
  child: inout ProcessExecution, tree: borrowing JobTree,
  ids: borrowing KoidSource
) throws {
  let tables = UnsafeMutableRawBufferPointer.allocate(byteCount: 65536, alignment: 16)
  defer { tables.deallocate() }
  let root: UInt64 = 0x80000
  let pa: UInt64 = 0x40000
  let va: UInt64 = 0xffff_8000_0001_0000
  let page: UInt64 = 16384
  let dest = va + 3 * page
  guard var k = ArmKernelTranslation(backing: tables, physical: root) else {
    Issue.record("no TTBR1")
    return
  }
  func map(_ va: UInt64, _ pa: UInt64, _ write: Bool = true) -> Bool {
    k.insert(virtual: va, physical: pa, write: write, execute: false)
  }
  for i: UInt64 in 0..<2 {
    #expect(map(va + i * page, pa + i * page))
    #expect(map(dest + i * page, pa + (2 + i) * page))
    #expect(map(dest + (3 + i) * page, pa + i * page))
  }
  func select(_ scheduler: UInt64, _ physical: UInt64) -> ArmStopStacks? {
    ArmStopStacks(
      tables: k, outgoingVA: va, outgoingPA: pa, schedulerVA: scheduler, schedulerPA: physical)
  }
  #expect(select(va, pa) == nil)
  #expect(select(dest + 3 * page, pa) == nil)
  #expect(select(dest, pa) == nil)
  // Another, disjoint pair that would otherwise qualify has no guard.
  for i: UInt64 in 0..<3 {
    #expect(map(dest + (6 + i) * page, pa + (4 + i) * page))
  }
  #expect(select(dest + 7 * page, pa + 5 * page) == nil)
  let stacks = try #require(select(dest, pa + 2 * page))

  let head = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
  let thread = UnsafeMutablePointer<ThreadExecution>.allocate(capacity: 1)
  head.initialize(
    to: ObjectHeader(
      source: ids, ownerJob: child.job.id, kind: TarwinKind.thread, maximumRights: 0)!)
  thread.initialize(
    to: ThreadExecution(header: .init(head), process: child.member, job: child.job)!)
  defer {
    thread.deinitialize(count: 1)
    thread.deallocate()
    _ = head.pointee.release()
    head.deinitialize(count: 1)
    head.deallocate()
  }
  let joined = child.join(thread, qos: 0, realtimeEntitled: false, tree: tree)
  let started = child.start(head.pointee.koid, tree: tree)
  #expect(joined == .added && started)
  func capture() -> W1StoppedCaller? {
    W1StoppedCaller(outcome: .stopCaller, child: child, thread: thread.pointee, stacks: stacks)
  }
  let early = capture() == nil
  #expect(early)
  let exiting = child.requestExit(TaskExit(.exited, code: -71), tree: tree) { _ in }
  #expect(exiting)
  let frame = va + 2 * page - UInt64(ArmTrapLayout.size)
  var notifications = 0
  func acknowledge(_ sp: UInt64) -> Bool {
    guard let stopped = capture() else { return false }
    #expect(stopped.destination(frame: frame, hostRoot: root) == dest + 2 * page)
    #expect(stopped.destination(frame: frame + 16, hostRoot: root) == nil)
    #expect(stopped.destination(frame: frame, hostRoot: root + page) == nil)
    #expect(stopped.destinationAfterCapture(sp: va + 2 * page, hostRoot: root) == nil)
    return stopped.acknowledge(
      sp: sp, hostRoot: root, child: &child, tree: tree,
      notify: { h in
        #expect(h == UnsafePointer(head))
        notifications += 1
      }, retire: { _ in Issue.record("released live thread") })
  }
  #expect(!acknowledge(frame) && notifications == 0 && child.threadCount == 1)
  #expect(acknowledge(dest + 2 * page) && notifications == 1 && child.threadCount == 0)
  #expect(thread.pointee.phase == .terminated && thread.pointee.exitCode == -71)
  let cleaned = child.beginCleanup(invalidate: { _ in }, retire: { _ in })
  let finished = child.finishCleanup(tree: tree, notify: { _ in })
  #expect(cleaned && finished)
}
