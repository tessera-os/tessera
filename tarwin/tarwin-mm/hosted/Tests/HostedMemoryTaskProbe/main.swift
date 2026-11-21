import Darwin
import TarwinTaskTransport

func run() throws {
  var bootstrap: mach_port_t = 0
  guard task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap) == KERN_SUCCESS else {
    exit(1)
  }
  let ports = try TaskCheckIn.send(bootstrap: bootstrap).get()
  let length = UInt64(getpagesize())
  let rx = VM_PROT_READ | VM_PROT_EXECUTE
  var executed = false
  while true {
    let opcode = try TaskCommandTransport.serveOne(on: ports.commandReceive, timeout: 5_000) {
      command, entry in
      switch command {
      case .map(let map):
        guard map.length == length, map.offset == 0, map.protection == UInt32(rx), !map.copy else {
          return KERN_INVALID_ARGUMENT
        }
        var address = map.address
        let status = mach_vm_map(
          mach_task_self_, &address, length, 0, VM_FLAGS_FIXED, entry, 0, 0, rx, rx, VM_INHERIT_NONE)
        guard status == KERN_SUCCESS else { return status }
        defer { mach_vm_deallocate(mach_task_self_, address, length) }
        guard mach_vm_protect(
          mach_task_self_, address, length, 0, VM_PROT_READ | VM_PROT_WRITE)
          == KERN_PROTECTION_FAILURE
        else { return KERN_FAILURE }
        let function = unsafeBitCast(UInt(address), to: (@convention(c) () -> UInt32).self)
        executed = function() == 42
        return executed ? KERN_SUCCESS : KERN_FAILURE
      case .terminate:
        return executed ? KERN_SUCCESS : KERN_FAILURE
      default:
        return KERN_INVALID_ARGUMENT
      }
    }.get()
    if opcode == .terminate { exit(executed ? 0 : 2) }
  }
}

do {
  try run()
} catch {
  print("hosted memory task probe: \(error)")
  exit(3)
}
