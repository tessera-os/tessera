import Darwin
import TarwinTaskProtocol
import TarwinTaskTransport

guard TaskRuntime.reserveWindow() == KERN_SUCCESS else { _exit(70) }
var bootstrap: mach_port_t = 0
guard task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap) == KERN_SUCCESS,
  bootstrap != 0 else { _exit(71) }
guard case .success(let ports) = TaskCheckIn.send(bootstrap: bootstrap) else { _exit(72) }
guard task_set_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, 0) == KERN_SUCCESS else { _exit(73) }
_ = mach_port_deallocate(mach_task_self_, bootstrap)
guard let gate = TaskGateRuntime.install(gate: ports.gateSend) else { _exit(75) }
guard TaskSandbox.install() else { _exit(74) }

var runtime = TaskRuntime(gate: gate)
while true {
  let result = TaskCommandTransport.serveOneReply(on: ports.commandReceive) { command, entry in
    switch command {
    case .snapshot(let address, let size):
      return TaskRuntime.snapshot(address: address, size: size)
    case .threadIdentity(let id):
      return runtime.threadIdentity(id: id)
    case .readMemory(let address, let size):
      return TaskLiveMemory.read(address: address, size: size, entry: entry)
    case .writeMemory(let address, let data):
      return TaskLiveMemory.write(address: address, data: data, entry: entry)
    default:
      return TaskCommandReply(status: runtime.handle(command, memoryEntry: entry))
    }
  }
  switch result {
  case .success(.terminate): _exit(0)
  case .success, .failure(.invalidMessage): continue
  case .failure: _exit(1)
  }
}
