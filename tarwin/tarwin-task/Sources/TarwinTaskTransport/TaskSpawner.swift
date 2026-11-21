import Darwin
import TarwinTaskProtocol

/// Owns the command send and gate receive rights, not the child lifecycle.
public final class SpawnedTask: Sendable {
  public let pid: pid_t
  public let commandSend: mach_port_t
  public let gateReceive: mach_port_t

  fileprivate init(pid: pid_t, ports: KernelTaskPorts) {
    self.pid = pid
    commandSend = ports.commandSend
    gateReceive = ports.gateReceive
  }

  deinit {
    TaskMachMessage.releaseSend(commandSend)
    TaskMachMessage.releaseReceive(gateReceive)
  }

  public func command(
    _ command: TaskCommand, memoryEntry: mach_port_t = 0, timeout: mach_msg_timeout_t = 5_000
  ) -> Result<TaskCommandReply, TaskTransportError> {
    TaskCommandTransport.call(command, on: commandSend, memoryEntry: memoryEntry, timeout: timeout)
  }

  public func threadIdentity(
    id: UInt64, timeout: mach_msg_timeout_t = 5_000
  ) -> Result<UInt64, TaskTransportError> {
    command(.threadIdentity(id: id), timeout: timeout).flatMap { response in
      guard response.status == KERN_SUCCESS else { return .failure(.mach(response.status)) }
      guard let threadID = response.kernelThreadID else { return .failure(.invalidMessage) }
      return .success(threadID)
    }
  }
}

public enum TaskSpawner {
  public static func spawn(
    executable: String, exceptionPort: mach_port_t = 0, timeout: mach_msg_timeout_t = 5_000
  ) throws -> SpawnedTask {
    var bootstrap: mach_port_t = 0
    let result = TaskMachMessage.newReceive(&bootstrap)
    guard result == KERN_SUCCESS else { throw TaskTransportError.mach(result) }
    defer { TaskMachMessage.releaseReceive(bootstrap) }
    let makeSend = mach_port_insert_right(
      mach_task_self_, bootstrap, bootstrap, UInt32(MACH_MSG_TYPE_MAKE_SEND))
    guard makeSend == KERN_SUCCESS else { throw TaskTransportError.mach(makeSend) }
    defer { TaskMachMessage.releaseSend(bootstrap) }

    var attributes: posix_spawnattr_t?
    try check(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)))
    try check(posix_spawnattr_setspecialport_np(&attributes, bootstrap, TASK_BOOTSTRAP_PORT))
    if exceptionPort != 0 {
      let mask = exception_mask_t(EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC
        | EXC_MASK_BREAKPOINT | EXC_MASK_SOFTWARE | EXC_MASK_GUARD)
      try check(posix_spawnattr_setexceptionports_np(
        &attributes, mask, exceptionPort, EXCEPTION_DEFAULT | Int32(bitPattern: MACH_EXCEPTION_CODES),
        ARM_THREAD_STATE64))
    }

    var pid: pid_t = 0
    try executable.withCString { path in
      var argv: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: path), nil]
      var envp: [UnsafeMutablePointer<CChar>?] = [nil]
      try check(posix_spawn(&pid, path, nil, &attributes, &argv, &envp))
    }

    switch TaskCheckIn.receive(bootstrap: bootstrap, pid: pid, timeout: timeout) {
    case .success(let ports):
      return SpawnedTask(pid: pid, ports: ports)
    case .failure(let error):
      var status: Int32 = 0
      let waited = waitpid(pid, &status, WNOHANG)
      if waited == pid { throw TaskTransportError.childExited(status) }
      kill(pid, SIGKILL)
      while waitpid(pid, nil, 0) == -1 && errno == EINTR {}
      throw error
    }
  }

  private static func check(_ status: Int32) throws {
    if status != 0 { throw TaskTransportError.spawn(status) }
  }
}
