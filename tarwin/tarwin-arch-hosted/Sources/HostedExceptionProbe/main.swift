import CHostDarwin
import Darwin
import TarwinArchHosted

struct Sink: HostExceptionSink {
  let terminate: Bool
  func handle(_ exception: HostException) -> HostExceptionDisposition {
    guard exception.kind == .badAccess, exception.faultAddress == 0x1000,
      exception.pc != 0, exception.sp != 0, exception.x.count == 29
    else { _exit(2) }
    let message = Array("EXC_BAD_ACCESS faultAddress=0x1000 registers=29\n".utf8)
    message.withUnsafeBytes { _ = write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    if terminate { return .terminate }
    var state = exception.state
    state.pc += 4
    return .resume(state)
  }
}

let exceptions = try HostExceptionPort(sink: Sink(terminate: CommandLine.arguments.contains("--terminate")))
let thread = mach_thread_self()
try exceptions.install(thread: thread)
mach_port_deallocate(mach_task_self_, thread)
withExtendedLifetime(exceptions) { th_deliberate_fault() }
print("resumed after fault")
exit(0)
