import TarwinSched

/// Kernel-side metadata attached to a reserved driver submission. Not a wire
/// format or a user handle. A completion must match the whole ticket.
public struct PresentationFrame: Equatable {
  public let queue: UInt64, slotEpoch: UInt64, interval: UInt64, deadline: UInt64
  fileprivate init(queue: UInt64, slotEpoch: UInt64, interval: UInt64, deadline: UInt64) {
    self.queue = queue
    self.slotEpoch = slotEpoch
    self.interval = interval
    self.deadline = deadline
  }
}

/// One serial presentation queue bound by the device service to a live slot,
/// client and driver. IDs are resolved kernel identities, not request fields.
/// Call under the scheduler/queue lock. The member slab is exclusively owned
/// until the slot is revoked and schedulers and completion handlers drain.
public struct PresentationQueue: ~Copyable {
  private let queue: UInt64, presenter: UInt64, driver: UInt64, slotEpoch: UInt64
  private var group: WorkInterval, frame: PresentationFrame?, removed = false

  public init?(
    queue: UInt64, presenter: UInt64, driver: UInt64, slotEpoch: UInt64,
    referenceCapacity: UInt32, members: UnsafeMutableBufferPointer<UInt64>
  ) {
    guard queue != 0, presenter != 0, driver != 0, slotEpoch != 0,
      let g = WorkInterval(owner: queue, referenceCapacity: referenceCapacity, members: members)
    else { return nil }
    self.queue = queue
    self.presenter = presenter
    self.driver = driver
    self.slotEpoch = slotEpoch
    group = g
  }

  /// The kernel supplies the process owning the resolved Thread. A client
  /// cannot nominate arbitrary workers for a scheduler boost.
  public mutating func addWorker(_ thread: UInt64, owner: UInt64, epoch: UInt64) -> Bool {
    guard !removed, owner == driver, epoch == slotEpoch else { return false }
    return group.join(thread, by: queue)
  }

  /// Kernel thread teardown (after charging its final CPU slice).
  public mutating func removeWorker(_ thread: UInt64) -> Bool { group.leave(thread) }

  /// Reserve driver command space first. Admission both starts the work
  /// interval and returns its deadline to pass to that command's workers.
  public mutating func present(by caller: UInt64, epoch: UInt64, now: UInt64, deadline: UInt64)
    -> PresentationFrame?
  {
    guard !removed, caller == presenter, epoch == slotEpoch, frame == nil,
      let id = group.begin(by: queue, start: now, deadline: deadline)
    else { return nil }
    let f = PresentationFrame(queue: queue, slotEpoch: slotEpoch, interval: id, deadline: deadline)
    frame = f
    return f
  }

  /// Called by scheduler accounting (not a driver-supplied energy estimate).
  /// Split slices at frame boundaries and charge each slice exactly once.
  public mutating func charge(
    _ f: PresentationFrame, worker: UInt64, from: UInt64, to: UInt64,
    capacity: UInt32
  ) -> Bool {
    guard frame == f else { return false }
    return group.charge(worker, epoch: f.interval, from: from, to: to, capacity: capacity)
  }

  /// A placement hint for this thread, not a realtime reservation. Combine
  /// with other load before ordinary job, isolation and thermal admission.
  public func demand(_ thread: UInt64, now: UInt64) -> UInt32 {
    guard frame != nil else { return 0 }
    return group.demand(thread, now: now)
  }

  public mutating func complete(_ f: PresentationFrame, by caller: UInt64, now: UInt64) -> Bool {
    guard caller == driver, frame == f, group.complete(by: queue, epoch: f.interval, now: now)
    else { return false }
    frame = nil
    return true
  }

  /// The slot owner invalidates the entire group before releasing its storage.
  /// A new registration gets a fresh group; no abandoned work trains it.
  public mutating func disconnect() {
    removed = true
    frame = nil
  }
}
