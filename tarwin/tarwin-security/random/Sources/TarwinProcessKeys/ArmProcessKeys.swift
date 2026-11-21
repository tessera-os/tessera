internal import Synchronization
import TarwinKernelRandom
import TarwinObject
import TarwinRandomCore
internal import _Volatile

/// Owns an exclusive, pinned kernel-only bank: IA, IB, DA, DB, GA, each
/// low word first. No user mappings, DMA, dumps, aliases or other writers.
/// Keep the child, immutable root and bank alive until all CPUs retire them.
public struct ArmProcessKeys: ~Copyable {
  private let member: ProcessKey
  private let header: UnsafePointer<ObjectHeader>
  private let root: UInt64
  private let bank: UnsafeMutableBufferPointer<UInt64>
  private let issued: RandomEpoch
  private let retired = Atomic<Bool>(false)

  /// Hold the tree, task and RNG locks; storage is exactly ten aligned
  /// words owned by this task. A failed RNG request does not claim the task.
  public init?(
    child: inout ProcessExecution, root: UInt64, tree: borrowing JobTree,
    storage: UnsafeMutableBufferPointer<UInt64>, random: inout KernelRandom,
    generation: RandomEpoch?
  ) {
    guard storage.count == 10, let base = storage.baseAddress,
      UInt(bitPattern: base) & 7 == 0,
      child.issueArmKeys(
        root: root, tree: tree,
        generate: {
          random.fill(UnsafeMutableRawBufferPointer(storage), generation: generation)
        }), let generation
    else { return nil }
    self.member = child.member
    self.header = child.header
    self.root = root
    self.bank = storage
    self.issued = generation
  }

  /// Under the same exclusive task/restore gate as key access. This does
  /// not clear keys from CPU registers or destroy an outstanding borrow.
  public func retire() {
    retired.store(true, ordering: .relaxed)
  }

  private func admits(_ current: () -> RandomEpoch?) -> Bool {
    guard !retired.load(ordering: .relaxed) else { return false }
    guard current() == issued else {
      retire()
      return false
    }
    return true
  }

  private func matches(_ child: borrowing ProcessExecution, _ root: UInt64) -> Bool {
    child.member == member && child.header == header && child.initialMap == root
      && self.root == root
  }

  /// Trusted non-reentrant callback only. Do not retain, copy or log key
  /// words. The leaf must restore host IA before it returns to Swift.
  public func withImportIA(
    child: borrowing ProcessExecution, root: UInt64, tree: borrowing JobTree,
    current: () -> RandomEpoch?,
    _ sign: (UnsafeBufferPointer<UInt64>) -> UInt64?
  ) -> UInt64? {
    guard admits(current), matches(child, root), child.phase == .created,
      tree.returnGate(member) == .run
    else { return nil }
    return sign(.init(start: bank.baseAddress, count: 2))
  }

  /// Called under trusted scheduler/task locks for the selected thread.
  /// Install only in the architecture transition, never in ordinary Swift.
  public func withThreadKeys(
    child: borrowing ProcessExecution, thread: borrowing ThreadExecution, root: UInt64,
    tree: borrowing JobTree, current: () -> RandomEpoch?,
    _ install: (UnsafeBufferPointer<UInt64>) -> Bool
  ) -> Bool {
    guard admits(current), matches(child, root), thread.process == member,
      thread.phase == .runnable,
      child.gate(thread.header.pointee.koid, tree: tree) == .dispatch
    else { return false }
    return install(.init(bank))
  }

  /// Consume after architectural register retirement and outstanding borrows.
  public consuming func erase() {}

  deinit {
    for i in bank.indices {
      VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(bitPattern: bank.baseAddress! + i))
        .store(0)
    }
  }
}
