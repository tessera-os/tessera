import Synchronization
import TarwinObject
import TarwinSyscall

public struct FenceTicket: Equatable {
  public let object: UInt64, sequence: UInt64
  fileprivate init(_ id: UInt64, _ seq: UInt64) {
    object = id
    sequence = seq
  }
}
public enum FenceWake { case signaled, cancelled, deviceRemoved }
public enum FenceReply: Equatable {
  case ready
  case parked(FenceTicket)
  case invalidHandle, wrongType, denied, full, invalidValue, deviceRemoved, unsupported
}
/// Hooks execute under the platform's IRQ-safe fence lock. They update
/// scheduler records without allocating, switching, sleeping or reentering.
/// Reserve a block record before calling wait. Only switch after unlocking,
/// and only if the thread is still blocked on that exact ticket.
public protocol FenceScheduler: ~Copyable {
  mutating func park(_ ticket: FenceTicket)
  mutating func wake(_ ticket: FenceTicket, _ reason: FenceWake)
  mutating func donate(fence: UInt64, priority: UInt32)
}
/// Construct once, before publishing any handle or mapping. Header, private
/// waiter slab and the dedicated coherent atomic word have stable storage.
/// Clients and devices may read (acquire), never write, this word. The IRQ
/// path must synchronize device writes before advancing. Reclaim after all
/// mappings, handles, waiter references and read epochs have drained.
public struct FenceObject: ~Copyable {
  private let header: UnsafePointer<ObjectHeader>, word: UnsafeMutablePointer<Atomic<UInt64>>
  private var timeline: GpuTimeline, sequence: UInt64 = 0, removed = false
  public init?(
    header: UnsafePointer<ObjectHeader>, word: UnsafeMutablePointer<Atomic<UInt64>>,
    waiters: UnsafeMutableBufferPointer<FenceWait>
  ) {
    guard header.pointee.kind == TarwinKind.fence, word.pointee.load(ordering: .relaxed) == 0 else {
      return nil
    }
    self.header = header
    self.word = word
    timeline = GpuTimeline(storage: waiters)
  }
  private func unpin(_ retire: (UnsafePointer<ObjectHeader>) -> Void) {
    if header.pointee.release() == .destroy { retire(header) }
  }
  /// Kernel caller holds a live payload reference and its lock. `table` is
  /// the calling process's protected read view; `priority` is scheduler
  /// state, not an argument from user space. Retire only enqueues destruction.
  public mutating func invoke<S: FenceScheduler & ~Copyable>(
    number: UInt64, name: UInt64, value: UInt64, priority: UInt32, table: HandleReadView,
    scheduler: inout S,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> FenceReply {
    let wait = number == TarwinCall.fenceWait
    guard wait || number == TarwinCall.fenceSignal else { return .unsupported }
    switch table.pinWithinEpoch(name, kind: TarwinKind.fence, need: wait ? 128 : 64) {
    case .invalidHandle: return .invalidHandle
    case .wrongType: return .wrongType
    case .accessDenied: return .denied
    case .found(let grant):
      guard grant.header == header else {
        grant.drop(retire: retire)
        return .invalidHandle
      }
      guard !removed else {
        grant.drop(retire: retire)
        return .deviceRemoved
      }
      let id = header.pointee.koid
      if wait {
        if value <= timeline.value {
          grant.drop(retire: retire)
          return .ready
        }
        guard sequence != .max, header.pointee.retainIfLive() else {
          grant.drop(retire: retire)
          return .full
        }
        let key = sequence + 1
        guard
          timeline.waitFor(true, FenceWait(key: key, target: value, priority: priority), { _ in })
            == .queued
        else {
          unpin(retire)
          grant.drop(retire: retire)
          return .full
        }
        // The waiter keeps its own reference until signal, cancel or unplug.
        grant.drop(retire: retire)
        sequence = key
        let ticket = FenceTicket(id, key)
        scheduler.park(ticket)
        scheduler.donate(fence: id, priority: timeline.inheritedPriority())
        return .parked(ticket)
      }
      let output = word
      let h = header
      let ok = timeline.advance(
        true, value, { output.pointee.store($0, ordering: .releasing) },
        { key in
          scheduler.wake(FenceTicket(id, key), .signaled)
          if h.pointee.release() == .destroy { retire(h) }
        }, { p in scheduler.donate(fence: id, priority: p) })
      grant.drop(retire: retire)
      return ok ? .ready : .invalidValue
    }
  }
  public mutating func cancel<S: FenceScheduler & ~Copyable>(
    _ ticket: FenceTicket, scheduler: inout S,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    let id = header.pointee.koid
    guard ticket.object == id, timeline.cancel(ticket.sequence, { _ in }) else { return false }
    scheduler.wake(ticket, .cancelled)
    scheduler.donate(fence: id, priority: timeline.inheritedPriority())
    unpin(retire)
    return true
  }
  public mutating func disconnect<S: FenceScheduler & ~Copyable>(
    scheduler: inout S, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) {
    guard !removed else { return }
    removed = true
    let h = header
    let id = h.pointee.koid
    timeline.drain { key in
      scheduler.wake(FenceTicket(id, key), .deviceRemoved)
      if h.pointee.release() == .destroy { retire(h) }
    }
    scheduler.donate(fence: id, priority: 0)
  }
}
