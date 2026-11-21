import CHostDarwin
import Darwin
import Foundation

/// The editable AArch64 user registers exposed by the hosted exception boundary.
public struct HostExceptionState: Sendable {
  public var pc: UInt64
  public var sp: UInt64
  public var x: [UInt64]
  /// Requires exactly x0 through x28; invalid resumed states terminate the faulting task.
  public init(pc: UInt64, sp: UInt64, x: [UInt64]) {
    self.pc = pc
    self.sp = sp
    self.x = x
  }
}

/// The port is borrowed only during the sink callback; threadID is the stable kernel identity.
public struct HostThreadIdentity: Sendable {
  public let port: UInt32
  public let threadID: UInt64
}

/// A decoded Mach exception with its two 64-bit codes and faulting register state.
public struct HostException: Sendable {
  /// Exception numbers match XNU's public EXC_* constants.
  public enum Kind: Int32, Sendable {
    case badAccess = 1, badInstruction = 2, arithmetic = 3, software = 5, breakpoint = 6, guardViolation = 12
  }
  public let kind: Kind
  public let code: UInt64
  public let subcode: UInt64
  public let faultAddress: UInt64
  public let state: HostExceptionState
  public let thread: HostThreadIdentity
  public var pc: UInt64 { state.pc }
  public var sp: UInt64 { state.sp }
  public var x: [UInt64] { state.x }
}

/// A synchronous disposition applied before replying to the faulting thread.
public enum HostExceptionDisposition: Sendable {
  case resume(HostExceptionState)
  case terminate
}

/// Receives faults on the exception worker; termination kills the faulting task, not just its thread.
public protocol HostExceptionSink: Sendable {
  func handle(_ exception: HostException) -> HostExceptionDisposition
}

private final class ExceptionLoop: @unchecked Sendable {
  let port: HostPort
  let sink: any HostExceptionSink
  private let lock = NSLock()
  private var stopped = false
  init(sink: any HostExceptionSink) throws {
    port = try HostPort.receive()
    self.sink = sink
  }
  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
  }
  func run() {
    while true {
      lock.lock()
      let done = stopped
      lock.unlock()
      if done { return }
      let result = th_exception_receive(port.rawName, { context, raw in
        guard let context, let raw else { return 0 }
        let loop = Unmanaged<ExceptionLoop>.fromOpaque(context).takeUnretainedValue()
        let c = raw.pointee
        guard let kind = HostException.Kind(rawValue: c.kind) else { return 0 }
        let registers = withUnsafeBytes(of: c.x) { Array($0.bindMemory(to: UInt64.self)) }
        let exception = HostException(kind: kind, code: c.code, subcode: c.subcode,
          faultAddress: c.fault_address, state: HostExceptionState(pc: c.pc, sp: c.sp, x: registers),
          thread: HostThreadIdentity(port: c.thread_port, threadID: c.thread_id))
        switch loop.sink.handle(exception) {
        case .terminate: return 0
        case .resume(let state):
          guard state.x.count == 29 else { return 0 }
          raw.pointee.pc = state.pc
          raw.pointee.sp = state.sp
          withUnsafeMutableBytes(of: &raw.pointee.x) { bytes in
            let words = bytes.bindMemory(to: UInt64.self)
            for i in 0..<29 { words[i] = state.x[i] }
          }
          return 1
        }
      }, Unmanaged.passUnretained(self).toOpaque())
      if result != 0 { stop() }
    }
  }
}

/// Owns an EXCEPTION_DEFAULT/MACH_EXCEPTION_CODES receive loop with ARM_THREAD_STATE64 decoding.
public final class HostExceptionPort: Sendable {
  private let loop: ExceptionLoop
  private let worker: HostThread
  /// A borrowed receive name suitable for transfer as a send right to a cooperating task host.
  public var rawName: UInt32 { loop.port.rawName }
  /// Starts an exception worker; the sink must never synchronously wait for the faulting thread.
  public init(sink: any HostExceptionSink) throws {
    let loop = try ExceptionLoop(sink: sink)
    self.loop = loop
    worker = try HostCPU().startWorker(name: "tarwin.exceptions") { loop.run() }
  }
  /// Creates an owned send right for installation by a cooperating task host.
  public func makeSend() throws -> HostPort { try loop.port.makeSend() }
  /// Installs on a borrowed task port; the caller owns restoration before destroying this service.
  public func install(task: UInt32) throws {
    let send = try makeSend()
    let result = withExtendedLifetime(send) { th_exception_install(task, send.rawName, 1) }
    guard result == KERN_SUCCESS else { throw HostError("task exception port", code: result) }
  }
  /// Installs on a borrowed thread port, primarily for isolated runtime/probe threads.
  public func install(thread: UInt32) throws {
    let send = try makeSend()
    let result = withExtendedLifetime(send) { th_exception_install(thread, send.rawName, 0) }
    guard result == KERN_SUCCESS else { throw HostError("thread exception port", code: result) }
  }
  deinit { loop.stop() }
}
