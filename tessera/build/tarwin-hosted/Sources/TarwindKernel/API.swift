import Foundation
@_exported import TarwinABI
import TarwinArchHosted
import TarwinObject

/// Paths reserved for the hosted disk, verified system image, panic log and task host.
public struct TarwindConfig: Sendable {
  public let diskPath, systemImagePath, panicRecordPath, taskExecutablePath: String
  public init(diskPath: String, systemImagePath: String, panicRecordPath: String, taskExecutablePath: String) {
    self.diskPath = diskPath; self.systemImagePath = systemImagePath
    self.panicRecordPath = panicRecordPath; self.taskExecutablePath = taskExecutablePath
  }
}

/// Lifecycle and diagnostic callbacks may arrive on the kernel worker.
public protocol TarwindHost: AnyObject, Sendable {
  func bootStage(_ name: String)
  func ready()
  func console(_ line: String)
  func panic(record: [UInt8])
}

/// An opaque registry identity, not a task port or handle-table name.
public struct TarwindProcessID: Hashable, Sendable {
  let value: UInt64
}

/// A single-consumption continuation local to one kernel instance.
public struct TarwindContinuationID: Hashable, Sendable {
  let value: UInt64
}

/// The ABI argument bank and call number supplied separately by a trap gate.
public struct TarwinCallRegisters {
  public var number: UInt64
  public var arguments: CallRegisters
  public private(set) var result = CallResult()
  public init(number: UInt64, arguments: CallRegisters = CallRegisters()) {
    self.number = number; self.arguments = arguments
  }
  mutating func complete(_ result: CallResult) {
    self.result = result
    arguments.a0 = result.status; arguments.a1 = result.detail
    arguments.a2 = result.first; arguments.a3 = result.second
  }
}

/// Blocking never retains a caller stack or parks a host thread.
public enum CallOutcome {
  case completed(CallResult)
  case blocked(TarwindContinuationID)
}

/// Registered kernel-process memory; task memory needs a separate pinned-copy backend.
public final class TarwindKernelBuffer: @unchecked Sendable {
  let bytes: UnsafeMutableRawBufferPointer
  public var address: UInt64 { UInt64(UInt(bitPattern: bytes.baseAddress!)) }
  public var count: Int { bytes.count }
  init(count: Int) {
    bytes = .allocate(byteCount: count, alignment: 4096)
    bytes.initializeMemory(as: UInt8.self, repeating: 0)
  }
  /// The caller must serialize access with calls operating on this buffer.
  public func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
    try body(bytes)
  }
  deinit { bytes.deallocate() }
}

/// The regular-Swift hosted kernel; shutdown is idempotent and drains its worker.
public final class Tarwind: @unchecked Sendable {
  let state: KernelState
  public let gate: KernelGate
  private init(state: KernelState) { self.state = state; gate = KernelGate(state: state) }
  public static func boot(_ config: TarwindConfig, host: any TarwindHost) throws -> Tarwind {
    try boot(config, host: host, devices: HostDeviceRegistry())
  }
  public static func boot(_ config: TarwindConfig, host: any TarwindHost, devices: HostDeviceRegistry) throws -> Tarwind {
    try boot(config, host: host, devices: devices, hooks: nil)
  }
  public static func boot(_ config: TarwindConfig, host: any TarwindHost,
    devices: HostDeviceRegistry, hooks: TarwindLaunchHooks?) throws -> Tarwind {
    let state = try KernelState(config: config, host: host, devices: devices, hooks: hooks)
    let kernel = Tarwind(state: state)
    do { try state.start() } catch { state.shutdown(); throw error }
    return kernel
  }
  public func shutdown() { state.shutdown() }
  /// Creates a handle namespace without an OS task; quota exhaustion returns a non-live identity.
  public func createKernelProcess(name: String) -> TarwindProcessID { state.createProcess(name: name) }
  public func containsProcess(_ process: TarwindProcessID) -> Bool {
    state.lock.withLock { state.processes[process] != nil }
  }
  public func allocateKernelBuffer(process: TarwindProcessID, count: Int) -> TarwindKernelBuffer? {
    state.lock.withLock {
      guard count > 0, count <= 4 * 1024 * 1024, let p = state.processes[process],
        p.buffers.count < 64 else { return nil }
      let buffer = TarwindKernelBuffer(count: count)
      p.buffers.append(buffer)
      return buffer
    }
  }
  /// Bind a cooperating task host's borrowed task port to its registered process.
  public func installExceptionPort(process: TarwindProcessID, task: UInt32,
    pager: (@Sendable (TarwindProcessID, HostException) throws -> HostExceptionDisposition?)? = nil) throws {
    try state.lock.withLock {
      guard state.processes[process] != nil else { throw TarwindError.invalidProcess }
      let port = try HostExceptionPort(sink: ExceptionSink(state: state, process: process, pager: pager))
      try port.install(task: task)
      state.exceptionPorts[process] = port
    }
  }
  /// Retains the receive service while handing a send right to the task spawner.
  public func makeExceptionSendRight(process: TarwindProcessID,
    pager: (@Sendable (TarwindProcessID, HostException) throws -> HostExceptionDisposition?)? = nil) throws -> HostPort {
    state.lock.lock(); defer { state.lock.unlock() }
    guard !state.stopped, state.processes[process] != nil else { throw TarwindError.invalidProcess }
    let port = try HostExceptionPort(sink: ExceptionSink(state: state, process: process, pager: pager))
    let send = try port.makeSend()
    state.exceptionPorts[process] = port
    return send
  }
  /// Exercise the same crash/registry transition without faulting the test runner.
  public func injectException(process: TarwindProcessID, kind: HostException.Kind,
    code: UInt64 = 0, faultAddress: UInt64 = 0) {
    state.fault(process: process, kind: kind, code: code, address: faultAddress, pc: 0)
  }
  deinit { shutdown() }
}

public enum TarwindError: Error { case invalidProcess, unavailable }

/// Thread-safe entry for in-kernel processes using the generated syscall catalogue.
public final class KernelGate: Sendable {
  let state: KernelState
  init(state: KernelState) { self.state = state }
  public func call(process: TarwindProcessID, registers: inout TarwinCallRegisters) -> CallOutcome {
    state.call(process: process, registers: &registers)
  }
  /// Consume a completed continuation; nil means pending, unknown or already consumed.
  public func completion(_ continuation: TarwindContinuationID) -> CallResult? {
    state.lock.withLock { state.completions.removeValue(forKey: continuation) }
  }
  /// Cancellation competes with wake and timeout through the same queue ticket.
  @discardableResult public func cancel(_ continuation: TarwindContinuationID) -> Bool {
    state.lock.withLock {
      guard let pending = state.pending[continuation] else { return false }
      return state.queue(for: pending).pointee.finish(pending.ticket, reason: .cancelled,
        change: { state.changed($0) })
    }
  }
}
