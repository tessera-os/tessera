import Darwin
import TarwinTaskProtocol

struct TaskRuntime {
  private struct ThreadSlot {
    var id: UInt64 = 0
    var port: mach_port_t = 0
  }

  private var threads = InlineArray<256, ThreadSlot>(repeating: ThreadSlot())
  private let gate: TaskGateRuntime

  init(gate: TaskGateRuntime) { self.gate = gate }

  static func reserveWindow() -> kern_return_t {
    var address = TaskWindow.base
    return mach_vm_map(
      mach_task_self_, &address, TaskWindow.size, 0, VM_FLAGS_FIXED, 0, 0, 0,
      VM_PROT_NONE, VM_PROT_NONE, VM_INHERIT_NONE)
  }

  mutating func handle(_ command: TaskCommand, memoryEntry: mach_port_t) -> kern_return_t {
    switch command {
    case .map(let mapping):
      guard Self.containsGuestPages(address: mapping.address, length: mapping.length),
        let protection = Self.protection(mapping.protection) else { return KERN_INVALID_ARGUMENT }
      var address = mapping.address
      return mach_vm_map(
        mach_task_self_, &address, mapping.length, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
        memoryEntry, mapping.offset, mapping.copy ? 1 : 0, protection,
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE | VM_PROT_IS_MASK,
        mapping.copy ? VM_INHERIT_COPY : VM_INHERIT_NONE)
    case .protect(let address, let length, let protection):
      guard Self.containsGuestPages(address: address, length: length),
        let access = Self.protection(protection) else { return KERN_INVALID_ARGUMENT }
      return mach_vm_protect(mach_task_self_, address, length, 0, access)
    case .unmap(var address, let length):
      guard Self.containsGuestPages(address: address, length: length) else { return KERN_INVALID_ARGUMENT }
      return mach_vm_map(
        mach_task_self_, &address, length, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, 0, 0, 0,
        VM_PROT_NONE, VM_PROT_NONE, VM_INHERIT_NONE)
    case .createThread(let id, let entry, let argument, let stack, let tls):
      guard id != 0, threadIndex(id) == nil else { return KERN_INVALID_ARGUMENT }
      guard let index = (0..<threads.count).first(where: { threads[$0].port == 0 }) else {
        return KERN_RESOURCE_SHORTAGE
      }
      var reply: mach_port_t = 0
      let allocated = mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &reply)
      guard allocated == KERN_SUCCESS else { return allocated }
      var registered = false
      defer {
        if !registered {
          _ = mach_port_mod_refs(mach_task_self_, reply, MACH_PORT_RIGHT_RECEIVE, -1)
        }
      }
      var attributes = pthread_attr_t()
      guard pthread_attr_init(&attributes) == 0 else { return KERN_RESOURCE_SHORTAGE }
      defer { pthread_attr_destroy(&attributes) }
      guard pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED) == 0 else {
        return KERN_FAILURE
      }
      // libSystem's Mach wrappers need Darwin thread-local state even on a guest thread.
      var pthread: pthread_t?
      guard pthread_create_suspended_np(&pthread, &attributes, { _ in nil }, nil) == 0,
        let pthread else { return KERN_RESOURCE_SHORTAGE }
      let thread = pthread_mach_thread_np(pthread)
      var state = arm_thread_state64_t()
      state.__pc = entry
      state.__sp = stack
      state.__x.0 = argument
      let configured = Self.set(state, on: thread)
      guard configured == KERN_SUCCESS else {
        _ = thread_resume(thread)
        return configured
      }
      gate.register(index: index, thread: thread, id: id, tls: tls, reply: reply)
      registered = true
      threads[index] = ThreadSlot(id: id, port: thread)
      return KERN_SUCCESS
    case .setThreadState(let id, let requested):
      guard let index = threadIndex(id) else { return KERN_INVALID_ARGUMENT }
      var state = arm_thread_state64_t()
      withUnsafeMutableBytes(of: &state.__x) { destination in
        for i in 0..<29 { destination.storeBytes(of: requested.registers[i], toByteOffset: i * 8, as: UInt64.self) }
      }
      state.__fp = requested.registers[29]
      state.__lr = requested.registers[30]
      state.__sp = requested.stack
      state.__pc = requested.pc
      state.__cpsr = requested.cpsr
      return Self.set(state, on: threads[index].port)
    case .suspendThread(let id):
      guard let index = threadIndex(id) else { return KERN_INVALID_ARGUMENT }
      return thread_suspend(threads[index].port)
    case .resumeThread(let id):
      guard let index = threadIndex(id) else { return KERN_INVALID_ARGUMENT }
      return thread_resume(threads[index].port)
    case .terminate:
      return KERN_SUCCESS
    }
  }

  private func threadIndex(_ id: UInt64) -> Int? {
    (0..<threads.count).first { threads[$0].port != 0 && threads[$0].id == id }
  }

  private static func containsGuestPages(address: UInt64, length: UInt64) -> Bool {
    TaskWindow.contains(address: address, length: length)
      && address < TaskGatePage.address && length <= TaskGatePage.address - address
  }

  private static func set(_ state: arm_thread_state64_t, on thread: mach_port_t) -> kern_return_t {
    var state = state
    let count = MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
    return withUnsafeMutablePointer(to: &state) {
      $0.withMemoryRebound(to: natural_t.self, capacity: count) {
        thread_set_state(thread, ARM_THREAD_STATE64, $0, UInt32(count))
      }
    }
  }

  private static func protection(_ value: UInt32) -> vm_prot_t? {
    let allowed = UInt32(VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE)
    let writeExecute = UInt32(VM_PROT_WRITE | VM_PROT_EXECUTE)
    guard value & ~allowed == 0, value & writeExecute != writeExecute else { return nil }
    return vm_prot_t(value)
  }
}
