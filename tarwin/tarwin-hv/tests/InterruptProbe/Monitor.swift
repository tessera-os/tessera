import TarwinSyscall

@_silgen_name("irq_ticks") private func ticks() -> UInt64
@_silgen_name("irq_timer") private func timer() -> UInt64

// Dedicated CPU; the linker reserves the RX guest and RW result page for
// the lifetime of this test. No device or host state is mapped into the VM.
private func checkpoint(_ cpu: inout VirtualCpuState, _ execute: () -> Bool) -> Bool {
  let result = runCpu(
    TarwinCall.virtualCpuRun, thread: 1, arm: { cpu.begin($0) },
    enter: {
      ExitRecord(
        reason: execute() ? .hypercall : .exception, address: 0, width: 0, write: false,
        data: 0, registerIndex: 0)
    }, finish: { cpu.finish($0) })
  guard case .success(let exit) = result else { return false }
  return exit.reason == .hypercall
}

#if arch(arm64)
  @_silgen_name("irq_prepare") private func prepare(_ offset: UInt64)
  @_silgen_name("irq_empty") private func empty() -> UInt64
  @_silgen_name("irq_write") private func writeLR0(_ value: UInt64)
  @_silgen_name("probe_enter") private func enter(
    _ root: UInt64, _ vtcr: UInt64, _ regs: UnsafeMutablePointer<UInt64>)
  @_cdecl("run_probe") public func arm(
    _ arena: UnsafeMutablePointer<UInt64>, _ code: UInt64,
    _ data: UnsafeMutablePointer<UInt64>, _ regs: UnsafeMutablePointer<UInt64>
  ) -> UInt32 {
    let root = UInt64(UInt(bitPattern: arena))
    guard var t = ArmStageTwo(arena: .init(start: arena, count: 6144), physicalBase: root),
      t.install(ipa: 0x10000, bytes: 16384, pinnedPA: code, permissions: 5),
      t.install(
        ipa: 0x200000, bytes: 16384, pinnedPA: UInt64(UInt(bitPattern: data)), permissions: 3)
    else { return 0 }
    for i in 0..<36 { regs[i] = 0 }
    regs[31] = 0x10000
    regs[32] = 0x3c5
    var cpu = VirtualCpuState(creator: 1)
    func run(_ cpu: inout VirtualCpuState, _ tag: UInt64) -> Bool {
      checkpoint(&cpu) {
        enter(root, ArmStageTwo.vtcr, regs)
        return regs[33] >> 26 == 0x16 && regs[33] & 0xffff == tag
      }
    }
    func inject(_ id: UInt32) -> Bool {
      ArmVirtualIRQ(interrupt: id, priority: 0x80)?.inject(count: 1, empty: empty()) {
        index, value in
        guard index == 0 else { return false }
        writeLR0(value)
        return empty() & 1 == 0
      } == true
    }
    let anchor = ticks()
    prepare(anchor)
    let begin = ticks() - anchor
    guard run(&cpu, 0x71), (begin...(ticks() - anchor)).contains(data[0]), data[1] == 0,
      inject(37), !inject(38), run(&cpu, 0x72), data[1] == 1, data[2] == 37, empty() & 1 != 0,
      timer() & 7 == 5, inject(27), run(&cpu, 0x73), data[1] == 2, data[3] == 27,
      empty() & 1 != 0, timer() & 1 == 0
    else { return 0 }
    return 1
  }
#elseif arch(riscv64)
  @_silgen_name("irq_prepare") private func prepare(_ delta: UInt64, _ index: UInt64) -> UInt32
  @_silgen_name("irq_post") private func post(_ address: UInt64, _ id: UInt32)
  @_silgen_name("rv_enter") private func enter(
    _ control: UInt64, _ regs: UnsafeMutablePointer<UInt64>)
  @_cdecl("run_rv_probe") public func rv(
    _ arena: UnsafeMutablePointer<UInt64>, _ code: UInt64,
    _ data: UnsafeMutablePointer<UInt64>, _ regs: UnsafeMutablePointer<UInt64>
  ) -> UInt32 {
    let root = UInt64(UInt(bitPattern: arena))
    guard
      var t = GuestRadixTables(
        format: .sv48x4, arena: .init(start: arena, count: 4096), physicalBase: root),
      t.install(ipa: 0x10000, bytes: 4096, pinnedPA: code, permissions: 5),
      t.install(
        ipa: 0x200000, bytes: 4096, pinnedPA: UInt64(UInt(bitPattern: data)), permissions: 3),
      let file = IMSICGuestTarget(
        hartBase: 0x2800_0000, bytes: 8192, files: 1, index: 1, lastID: 63)
    else { return 0 }
    for i in 0..<37 { regs[i] = 0 }
    regs[32] = 0x10000
    var cpu = VirtualCpuState(creator: 1)
    func run(_ cpu: inout VirtualCpuState, _ tag: UInt64) -> Bool {
      checkpoint(&cpu) {
        enter((UInt64(9) << 60) | (root >> 12), regs)
        return regs[33] == 10 && regs[36] & 128 != 0 && regs[10] == tag
      }
    }
    let anchor = ticks()
    guard prepare(0 &- anchor, UInt64(file.index)) != 0 else { return 0 }
    let begin = ticks() - anchor
    guard run(&cpu, 0x71), (begin...(ticks() - anchor)).contains(data[0]), data[1] == 0,
      file.post(
        37,
        write: {
          post($0, $1)
          return true
        })
    else { return 0 }
    regs[32] += 4
    guard run(&cpu, 0x73), data[1] == 2, data[2] == 37, data[3] == 5, timer() == .max else {
      return 0
    }
    return 1
  }
#endif
