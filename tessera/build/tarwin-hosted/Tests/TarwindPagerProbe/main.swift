import Darwin
import Foundation
import TarwinArchHosted
import TarwindKernel

final class Host: TarwindHost, @unchecked Sendable {
  func bootStage(_ name: String) {}
  func ready() {}
  func console(_ line: String) {
    let bytes = Array((line + "\n").utf8)
    bytes.withUnsafeBytes { _ = Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
  }
  func panic(record: [UInt8]) { _exit(20) }
}

let mode = CommandLine.arguments[1]
let directory = CommandLine.arguments[2]
let host = Host()
let kernel = try Tarwind.boot(.init(diskPath: directory + "/disk", systemImagePath: directory + "/absent",
  panicRecordPath: "", taskExecutablePath: ""), host: host)
let process = kernel.createKernelProcess(name: "pager-probe")
let page = mmap(nil, 16384, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)!
guard page != MAP_FAILED else { exit(21) }
page.storeBytes(of: UInt64(42), as: UInt64.self)
guard mprotect(page, 16384, PROT_NONE) == 0 else { exit(22) }
let address = UInt64(UInt(bitPattern: page))
let pager: @Sendable (TarwindProcessID, HostException) throws -> HostExceptionDisposition? = { id, exception in
  guard id == process, exception.kind == .badAccess, exception.faultAddress == address,
    exception.subcode == address, exception.code != 0, exception.pc != 0, exception.sp != 0,
    exception.x.count == 29, kernel.containsProcess(id) else { _exit(23) }
  if mode == "throw" { throw TarwindError.unavailable }
  if mode == "terminate" { return .terminate }
  if mode == "nil-result" { return nil }
  guard let pointer = UnsafeMutableRawPointer(bitPattern: UInt(address)),
    mprotect(pointer, 16384, PROT_READ | PROT_WRITE) == 0 else { _exit(24) }
  host.console("pager mapped original fault; registry live")
  return .resume(exception.state)
}
if mode == "nil-pager" {
  try kernel.installExceptionPort(process: process, task: mach_task_self_)
} else {
  let send = try kernel.makeExceptionSendRight(process: process, pager: pager)
  let installed = withExtendedLifetime(send) {
    task_set_exception_ports(mach_task_self_, exception_mask_t(EXC_MASK_BAD_ACCESS), send.rawName,
      exception_behavior_t(bitPattern: UInt32(EXCEPTION_DEFAULT) | MACH_EXCEPTION_CODES), thread_state_flavor_t(ARM_THREAD_STATE64))
  }
  guard installed == KERN_SUCCESS else { exit(25) }
}
let value = page.load(as: UInt64.self)
guard value == 42, kernel.containsProcess(process) else { exit(26) }
host.console("resumed faulting load; process survived")
kernel.shutdown()
exit(0)
