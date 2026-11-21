import Darwin
import TarwinTaskTransport

guard TaskRuntime.reserveWindow() == KERN_SUCCESS else { _exit(70) }
var bootstrap: mach_port_t = 0
guard task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap) == KERN_SUCCESS,
  bootstrap != 0 else { _exit(71) }
guard case .success(let ports) = TaskCheckIn.send(bootstrap: bootstrap) else { _exit(72) }
guard task_set_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, 0) == KERN_SUCCESS else { _exit(73) }
_ = mach_port_deallocate(mach_task_self_, bootstrap)
guard TaskSandbox.install() else { _exit(74) }

var runtime = TaskRuntime()
while true {
  let result = TaskCommandTransport.serveOne(on: ports.commandReceive) { command, entry in
    runtime.handle(command, memoryEntry: entry)
  }
  switch result {
  case .success(.terminate): _exit(0)
  case .success, .failure(.invalidMessage): continue
  case .failure: _exit(1)
  }
}
