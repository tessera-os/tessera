import Darwin
import TarwinTaskTransport

var bootstrap: mach_port_t = 0
guard task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap) == KERN_SUCCESS,
  bootstrap != 0
else { exit(1) }

// Simulate a system bootstrap request queued before the task's check-in.
let size = UInt32(MemoryLayout<mach_msg_header_t>.size)
var unrelated = mach_msg_header_t(
  msgh_bits: UInt32(MACH_MSG_TYPE_COPY_SEND), msgh_size: size, msgh_remote_port: bootstrap,
  msgh_local_port: 0, msgh_voucher_port: 0, msgh_id: 1)
guard mach_msg(&unrelated, MACH_SEND_MSG | MACH_SEND_TIMEOUT, size, 0, 0, 1_000, 0) == KERN_SUCCESS
else { exit(2) }

guard case .success(let ports) = TaskCheckIn.send(bootstrap: bootstrap) else { exit(3) }
guard task_set_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, 0) == KERN_SUCCESS
else { exit(4) }
_ = mach_port_deallocate(mach_task_self_, bootstrap)

let result = TaskCommandTransport.serveOne(on: ports.commandReceive, timeout: 5_000) { command, _ in
  command.opcode == .terminate ? KERN_SUCCESS : KERN_NOT_SUPPORTED
}
if case .success(.terminate) = result { exit(0) }
exit(5)
