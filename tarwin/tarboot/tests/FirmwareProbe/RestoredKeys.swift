import TarwinKernelRandom
import TarwinObject
import TarwinProcessKeys
import TarwinRandomCore

/// Disposable lifecycle objects only: never install or inspect key words,
/// run a child, or use a restored device-fence receipt. The root is an
/// opaque test identity, not a page table to switch to.
func rejectsRestoredBank(random: inout KernelRandom, first: RandomEpoch,
  current: () -> RandomEpoch?, restore: () -> Bool) -> Bool {
  var job = JobNode(), member = JobMember(), slot = ThreadSlot()
  return withUnsafeMutablePointer(to: &job) { j in
    withUnsafeMutablePointer(to: &member) { m in
      withUnsafeMutablePointer(to: &slot) { s in
        withUnsafeTemporaryAllocation(byteCount: MemoryLayout<HandleCell>.stride,
          alignment: MemoryLayout<HandleCell>.alignment) { raw in
          let ids = KoidSource()
          let limits = JobLimits(processes: 1, threadsPerProcess: 1, handlesPerProcess: 1,
            footprint: 4096, cpuShare: 1, maxQos: 1, jetsamBand: 1, ioRank: 1,
            entitlements: 0, denials: 0, killOnClose: false)
          guard let root = ObjectHeader(source: ids, ownerJob: 0, kind: TarwinKind.job, maximumRights: 0),
            let tree = JobTree(jobs: .init(start: j, count: 1), members: .init(start: m, count: 1),
              root: root, limits: limits),
            let process = ObjectHeader(source: ids, ownerJob: root.koid, kind: TarwinKind.process, maximumRights: 0),
            let thread = ObjectHeader(source: ids, ownerJob: root.koid, kind: TarwinKind.thread, maximumRights: 0)
          else { return false }
          let cells = raw.bindMemory(to: HandleCell.self)
          let identity: UInt64 = 0x4000
          return withUnsafePointer(to: process) { h in
            guard var child = ProcessExecution(header: h, job: tree.root, tree: tree,
              slots: .init(start: s, count: 1), cells: cells, salt: 2, initialMap: identity)
            else { return false }
            defer { cells.deinitialize() }
            var bank = InlineArray<10, UInt64>(repeating: 0)
            return withUnsafeMutableBytes(of: &bank) { bytes in
              guard let keys = ArmProcessKeys(child: &child, root: identity, tree: tree,
                storage: bytes.bindMemory(to: UInt64.self), random: &random, generation: current()),
                keys.withImportIA(child: child, root: identity, tree: tree, current: current,
                  { $0.count == 2 ? 1 : nil }) == 1 else { return false }
              let refused = withUnsafePointer(to: thread) {
                checkThread($0, child: &child, tree: tree, root: identity,
                  keys: keys, first: first, current: current, restore: restore)
              }
              keys.erase()
              for byte in bytes where byte != 0 { return false }
              return refused
            }
          }
        }
      }
    }
  }
}

private func checkThread(_ header: UnsafePointer<ObjectHeader>, child: inout ProcessExecution,
  tree: borrowing JobTree, root: UInt64, keys: borrowing ArmProcessKeys, first: RandomEpoch,
  current: () -> RandomEpoch?, restore: () -> Bool) -> Bool {
  guard var t = ThreadExecution(header: header, process: child.member, job: tree.root) else { return false }
  return withUnsafeMutablePointer(to: &t) { tp in
    guard child.join(tp, qos: 0, realtimeEntitled: false, tree: tree) == .added else { return false }
    defer {
      _ = child.stopped(header.pointee.koid, code: 0, tree: tree, notify: { _ in }, retire: { _ in })
      _ = child.beginCleanup(invalidate: { _ in }, retire: { _ in })
      _ = child.finishCleanup(tree: tree, notify: { _ in })
    }
    guard child.start(header.pointee.koid, tree: tree),
      keys.withThreadKeys(child: child, thread: tp.pointee, root: root, tree: tree,
        current: current, { $0.count == 10 }),
      restore(), let next = current(), next != first,
      child.gate(header.pointee.koid, tree: tree) == .dispatch
    else { return false }
    var called = false
    guard !keys.withThreadKeys(child: child, thread: tp.pointee, root: root, tree: tree,
      current: current, { _ in called = true; return true }),
      !keys.withThreadKeys(child: child, thread: tp.pointee, root: root, tree: tree,
        current: { first }, { _ in called = true; return true }) else { return false }
    return !called
  }
}
