import Darwin

/// A failed host operation, preserving its POSIX or Mach status.
public struct HostError: Error, Sendable {
  public let operation: String
  public let code: Int32
  public init(_ operation: String, code: Int32) {
    self.operation = operation
    self.code = code
  }
}

/// Exclusive ownership of one receive, send, or send-once right reference.
public struct HostPort: ~Copyable, Sendable {
  /// The right reference released when this owner is destroyed.
  public enum Kind: Sendable { case receive, send, sendOnce }
  /// A borrowed name, valid only while its owner remains alive.
  public let rawName: UInt32
  /// The owned right's disposition.
  public let kind: Kind

  /// Adopts an existing right reference; the caller must relinquish ownership.
  public init(adopting rawName: UInt32, kind: Kind) {
    self.rawName = rawName
    self.kind = kind
  }

  /// Allocates an empty receive right in this task.
  public static func receive() throws -> HostPort {
    var name: mach_port_t = 0
    let result = mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &name)
    guard result == KERN_SUCCESS else { throw HostError("mach_port_allocate", code: result) }
    return HostPort(adopting: name, kind: .receive)
  }

  /// Creates one independently owned send reference to this receive right.
  public borrowing func makeSend() throws -> HostPort {
    guard kind == .receive else { throw HostError("makeSend", code: KERN_INVALID_RIGHT) }
    let result = mach_port_insert_right(mach_task_self_, rawName, rawName, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
    guard result == KERN_SUCCESS else { throw HostError("mach_port_insert_right", code: result) }
    return HostPort(adopting: rawName, kind: .send)
  }

  deinit {
    if kind == .receive {
      _ = mach_port_mod_refs(mach_task_self_, rawName, MACH_PORT_RIGHT_RECEIVE, -1)
    } else {
      _ = mach_port_deallocate(mach_task_self_, rawName)
    }
  }
}

/// Host counter conversion with continuous and awake-only nanosecond epochs.
public struct HostClock: Sendable {
  private let numerator: UInt64
  private let denominator: UInt64
  /// Captures the immutable host Mach timebase.
  public init() {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    numerator = UInt64(info.numer)
    denominator = UInt64(info.denom)
  }
  /// Counter ticks per second, before conversion to nanoseconds.
  public var counterFrequency: UInt64 { 1_000_000_000 * denominator / numerator }
  /// Nanoseconds including time spent asleep.
  public func monotonicNanos() -> UInt64 { nanos(mach_continuous_time()) }
  /// Nanoseconds in the mach_absolute_time epoch, excluding sleep.
  public func absoluteNanos() -> UInt64 { nanos(mach_absolute_time()) }
  private func nanos(_ ticks: UInt64) -> UInt64 {
    denominator.dividingFullWidth(ticks.multipliedFullWidth(by: numerator)).quotient
  }
  func ticks(_ ns: UInt64) -> UInt64 {
    numerator.dividingFullWidth(ns.multipliedFullWidth(by: denominator)).quotient
  }
}
