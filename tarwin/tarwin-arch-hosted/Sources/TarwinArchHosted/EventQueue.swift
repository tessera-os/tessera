import CHostDarwin
import Darwin
import Foundation

private typealias KernelEvent = Darwin.kevent

/// An opaque registration identity, unique within its event queue.
public struct HostEventToken: Hashable, Sendable {
  public let rawValue: UInt64
}

/// A readiness notification; Mach messages and descriptor bytes remain unread.
public struct HostEvent: Sendable {
  /// The host mechanism which became ready.
  public enum Kind: Sendable { case machPort, read, write, processExit, timer }
  public let token: HostEventToken
  public let kind: Kind
  public let data: Int64
}

/// A concurrent kqueue with serialized registration and independent waiters.
public final class HostEventQueue: @unchecked Sendable {
  private struct Registration {
    let ident: UInt
    let filter: Int16
    let kind: HostEvent.Kind
    let once: Bool
    let portSet: mach_port_t
  }
  private struct RepeatingTimer {
    let interval: UInt64
    var deadline: UInt64
  }
  private let descriptor: Int32
  private let lock = NSLock()
  private var next: UInt64 = 1
  private var registrations: [HostEventToken: Registration] = [:]

  /// Creates an empty queue; descriptor exhaustion is reported to the caller.
  public init() throws {
    descriptor = kqueue()
    guard descriptor >= 0 else { throw HostError("kqueue", code: errno) }
  }
  deinit {
    close(descriptor)
    for entry in registrations.values where entry.portSet != 0 {
      mach_port_mod_refs(mach_task_self_, entry.portSet, MACH_PORT_RIGHT_PORT_SET, -1)
    }
  }

  /// Borrows a receive right and exclusively owns its port-set membership until cancellation.
  public func registerMachPort(_ port: borrowing HostPort) throws -> HostEventToken {
    guard port.kind == .receive else { throw HostError("registerMachPort", code: KERN_INVALID_RIGHT) }
    var set: mach_port_t = 0
    var result = mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_PORT_SET, &set)
    guard result == KERN_SUCCESS else { throw HostError("port set", code: result) }
    result = mach_port_insert_member(mach_task_self_, port.rawName, set)
    guard result == KERN_SUCCESS else {
      mach_port_mod_refs(mach_task_self_, set, MACH_PORT_RIGHT_PORT_SET, -1)
      throw HostError("mach_port_insert_member", code: result)
    }
    do {
      return try add(ident: UInt(set), filter: Int16(EVFILT_MACHPORT), kind: .machPort, portSet: set)
    } catch {
      mach_port_mod_refs(mach_task_self_, set, MACH_PORT_RIGHT_PORT_SET, -1)
      throw error
    }
  }

  /// Borrows a descriptor until cancellation; duplicate direction registrations are rejected.
  public func registerFileDescriptor(_ fd: Int32, write: Bool = false) throws -> HostEventToken {
    guard fd >= 0 else { throw HostError("descriptor", code: EBADF) }
    return try add(ident: UInt(fd), filter: Int16(write ? EVFILT_WRITE : EVFILT_READ), kind: write ? .write : .read)
  }

  /// Watches an existing process once; register before allowing a spawned child to exit.
  public func registerProcessExit(_ pid: Int32) throws -> HostEventToken {
    guard pid > 0 else { throw HostError("pid", code: EINVAL) }
    return try add(ident: UInt(pid), filter: Int16(EVFILT_PROC), kind: .processExit, flags: UInt32(NOTE_EXIT), once: true)
  }

  /// Schedules an absolute awake-time deadline; an optional positive interval repeats thereafter.
  public func registerTimer(deadlineNanos: UInt64, repeatingNanos: UInt64? = nil) throws -> HostEventToken {
    if let interval = repeatingNanos, interval == 0 || interval > UInt64(Int.max) {
      throw HostError("timer interval", code: EINVAL)
    }
    let clock = HostClock()
    let ticks = clock.ticks(deadlineNanos)
    guard ticks <= UInt64(Int.max) else { throw HostError("timer deadline", code: EOVERFLOW) }
    return try add(ident: nil, filter: Int16(EVFILT_TIMER), kind: .timer,
      flags: UInt32(NOTE_MACHTIME | NOTE_ABSOLUTE | NOTE_CRITICAL), data: Int(ticks), once: true,
      repeating: repeatingNanos.map { RepeatingTimer(interval: $0, deadline: deadlineNanos) })
  }
  private var repeats: [HostEventToken: RepeatingTimer] = [:]

  /// Removes a registration; cancellation is idempotent, including after a one-shot fires.
  public func cancel(_ token: HostEventToken) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = registrations[token] else { return }
    var change = KernelEvent(ident: entry.ident, filter: entry.filter, flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil)
    if th_kevent(descriptor, &change, 1, nil, 0, nil) < 0 && errno != ENOENT && errno != ESRCH {
      throw HostError("kevent cancel", code: errno)
    }
    remove(token, entry)
  }

  /// Waits for up to 64 events; nil blocks, zero polls, and interruptions return an empty batch.
  public func wait(timeoutNanos: UInt64? = nil) throws -> [HostEvent] {
    var events = [KernelEvent](repeating: KernelEvent(), count: 64)
    let count: Int32
    if let timeoutNanos {
      var timeout = timespec(tv_sec: Int(timeoutNanos / 1_000_000_000), tv_nsec: Int(timeoutNanos % 1_000_000_000))
      count = th_kevent(descriptor, nil, 0, &events, Int32(events.count), &timeout)
    } else {
      count = th_kevent(descriptor, nil, 0, &events, Int32(events.count), nil)
    }
    if count < 0 {
      if errno == EINTR { return [] }
      throw HostError("kevent wait", code: errno)
    }
    lock.lock()
    defer { lock.unlock() }
    var output: [HostEvent] = []
    for event in events.prefix(Int(count)) {
      let token = HostEventToken(rawValue: UInt64(UInt(bitPattern: event.udata)))
      guard let entry = registrations[token] else { continue }
      if event.flags & UInt16(EV_ERROR) != 0 { throw HostError("kevent event", code: Int32(event.data)) }
      var data = Int64(event.data)
      if var timer = repeats[token] {
        let now = HostClock().absoluteNanos()
        let elapsed = now >= timer.deadline ? (now - timer.deadline) / timer.interval : 0
        let (count, countOverflow) = elapsed.addingReportingOverflow(1)
        let (advance, advanceOverflow) = count.multipliedReportingOverflow(by: timer.interval)
        let (deadline, deadlineOverflow) = timer.deadline.addingReportingOverflow(advance)
        let ticks = HostClock().ticks(deadline)
        guard !countOverflow, !advanceOverflow, !deadlineOverflow, ticks <= UInt64(Int.max) else {
          remove(token, entry)
          throw HostError("repeat timer overflow", code: EOVERFLOW)
        }
        data = Int64(min(count, UInt64(Int64.max)))
        var change = KernelEvent(ident: entry.ident, filter: entry.filter, flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
          fflags: UInt32(NOTE_MACHTIME | NOTE_ABSOLUTE | NOTE_CRITICAL), data: Int(ticks), udata: event.udata)
        guard th_kevent(descriptor, &change, 1, nil, 0, nil) == 0 else {
          throw HostError("repeat timer", code: errno)
        }
        timer.deadline = deadline
        repeats[token] = timer
      } else if entry.once { remove(token, entry) }
      output.append(HostEvent(token: token, kind: entry.kind, data: data))
    }
    return output
  }

  private func add(ident: UInt?, filter: Int16, kind: HostEvent.Kind, flags: UInt32 = 0,
    data: Int = 0, once: Bool = false, portSet: mach_port_t = 0,
    repeating: RepeatingTimer? = nil) throws -> HostEventToken {
    lock.lock()
    defer { lock.unlock() }
    let token = HostEventToken(rawValue: next)
    next += 1
    let id = ident ?? UInt(token.rawValue)
    guard !registrations.values.contains(where: { $0.ident == id && $0.filter == filter }) else {
      throw HostError("duplicate registration", code: EEXIST)
    }
    var change = KernelEvent(ident: id, filter: filter, flags: UInt16(EV_ADD | EV_ENABLE | (once ? EV_ONESHOT : EV_CLEAR)),
      fflags: flags, data: data, udata: UnsafeMutableRawPointer(bitPattern: UInt(token.rawValue)))
    guard th_kevent(descriptor, &change, 1, nil, 0, nil) == 0 else { throw HostError("kevent add", code: errno) }
    registrations[token] = Registration(ident: id, filter: filter, kind: kind, once: once, portSet: portSet)
    repeats[token] = repeating
    return token
  }
  private func remove(_ token: HostEventToken, _ entry: Registration) {
    registrations.removeValue(forKey: token)
    repeats.removeValue(forKey: token)
    if entry.portSet != 0 { mach_port_mod_refs(mach_task_self_, entry.portSet, MACH_PORT_RIGHT_PORT_SET, -1) }
  }
}
