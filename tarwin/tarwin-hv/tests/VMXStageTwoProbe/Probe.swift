import TarwinSyscall

@_silgen_name("vmx_msr") private func msr(_ index: UInt32) -> UInt64
@_silgen_name("vmx_cr") private func cr(_ index: UInt32) -> UInt64
@_silgen_name("vmx_activate") private func activate(_ cr0: UInt64, _ cr4: UInt64)
@_silgen_name("vmx_cmd") private func command(_ op: UInt32, _ pa: UInt64) -> UInt32
@_silgen_name("vmx_put") private func vmwrite(_ field: UInt64, _ value: UInt64) -> UInt32
@_silgen_name("vmx_get") private func get(_ field: UInt64) -> UInt64
@_silgen_name("vmx_flush") private func invalidate(_ eptp: UInt64) -> UInt32
@_silgen_name("vmx_enter") private func enterVMX(_ resume: UInt32) -> UInt32
@_silgen_name("vmx_table_base") private func table(_ which: UInt32) -> UInt64
@_silgen_name("npt_next") private func nextPC(_ pc: UInt64) -> UInt64

// Dedicated PVH CPU after CPUID.VMX admission. The linker owns all frames
// for the entire image lifetime. No user pointers or untrusted MSR indices.
@_cdecl("run_vmx_probe")
public func runVMXProbe(
  _ arena: UnsafeMutablePointer<UInt64>, _ code: UInt64, _ data: UnsafeMutablePointer<UInt64>,
  _ guest: UnsafeMutablePointer<UInt64>, _ vmcs: UnsafeMutablePointer<UInt32>,
  _ on: UnsafeMutablePointer<UInt32>
) -> UInt32 {
  let root = UInt64(UInt(bitPattern: arena))
  let v = UInt64(UInt(bitPattern: vmcs))
  let o = UInt64(UInt(bitPattern: on))
  let basic = msr(0x480)
  guard msr(0x3a) & 5 == 5, basic & (1 << 55) != 0,
    msr(0x48e) & (1 << 63) != 0, msr(0x48b) & (1 << 33) != 0,
    let config = VMXControls(
      vmx: true, featureControl: msr(0x3a), basic: basic,
      physicalBits: 32, vmxonPA: o, vmcsPA: v, eptRoot: root,
      eptCaps: msr(0x48c), pinCaps: msr(0x48d), primaryCaps: msr(0x48e),
      secondaryCaps: msr(0x48b), entryCaps: msr(0x490), exitCaps: msr(0x48f)),
    var ept = GuestRadixTables(
      format: .ept, arena: .init(start: arena, count: 4096), physicalBase: root)
  else { return 0 }
  let c0 = cr(0) | msr(0x486)
  let c4 = cr(4) | msr(0x488) | 0x2000
  guard c0 & ~msr(0x487) == 0, c4 & ~msr(0x489) == 0 else { return 0 }
  let pt: UInt64 = 0x3000000
  let d: UInt64 = 0x200000
  let pa = UInt64(UInt(bitPattern: data))
  guest[0] = (pt + 4096) | 0x27
  guest[512] = (pt + 8192) | 0x27
  guest[1024] = 0xe7
  guest[1025] = d | 0xe7
  var ram = GuestExtent()
  func map(_ ept: inout GuestRadixTables, _ ram: inout GuestExtent, _ rights: UInt64) -> Bool {
    ram.map(
      d, 0, 4096, 1 << 48, 4096, 4096, rights, rights, { _, _ in pa },
      { ept.install(ipa: $0, bytes: $1, pinnedPA: $2, permissions: $3) }, { _ in })
  }
  func retire(_ ept: inout GuestRadixTables, _ ram: inout GuestExtent) -> Bool {
    ram.retire(
      { ept.detach(ipa: $0, bytes: $1) }, { _, _ in invalidate(config.eptp) != 0 }, { _ in })
  }
  guard ept.install(ipa: 0x10000, bytes: 4096, pinnedPA: code, permissions: 5), map(&ept, &ram, 3),
    ept.install(ipa: pt, bytes: 12288, pinnedPA: UInt64(UInt(bitPattern: guest)), permissions: 3)
  else { return 0 }
  for i in 0..<1024 {
    on[i] = 0
    vmcs[i] = 0
  }
  on[0] = config.revision
  vmcs[0] = config.revision
  activate(c0, c4)
  guard command(0, o) != 0 else { return 0 }
  func write(_ field: UInt64, _ value: UInt64) -> Bool { vmwrite(field, value) != 0 }
  func execute(_ ept: inout GuestRadixTables, _ ram: inout GuestExtent) -> Bool {
    guard command(1, v) != 0, command(2, v) != 0, config.install(write: write) else { return false }
    // Host selectors/bases correspond to this image's GDT and loaded TSS.
    for i: UInt64 in 0..<7 {
      guard write(0xc00 + 2 * i, i == 1 ? 8 : i == 6 ? 24 : i < 4 ? 16 : 0) else { return false }
    }
    for i: UInt64 in 0..<8 {
      let unusable = (4...6).contains(i)
      guard write(0x800 + 2 * i, i == 1 ? 8 : i == 7 ? 24 : unusable ? 0 : 16),
        write(0x6806 + 2 * i, 0), write(0x4800 + 2 * i, i == 7 ? 103 : unusable ? 0 : 0xffff_ffff),
        write(0x4814 + 2 * i, i == 1 ? 0xa09b : i == 7 ? 0x8b : unusable ? 0x10000 : 0xc093)
      else { return false }
    }
    let efer = msr(0xc000_0080)
    guard write(0x6c00, c0), write(0x6c02, cr(3)), write(0x6c04, c4),
      write(0x6c06, 0), write(0x6c08, 0), write(0x6c0a, table(1)), write(0x6c0c, table(0)),
      write(0x6c0e, 0), write(0x6c10, 0), write(0x6c12, 0), write(0x4c00, 0), write(0x2c02, efer),
      write(0x6800, c0), write(0x6802, pt), write(0x6804, c4), write(0x2806, efer),
      write(0x6816, 0), write(0x6818, 0), write(0x4810, 0), write(0x4812, 0),
      write(0x681a, 0x400), write(0x681c, 0), write(0x681e, 0x10000), write(0x6820, 2),
      write(0x6822, 0), write(0x6824, 0), write(0x6826, 0), write(0x482a, 0),
      write(0x4824, 0), write(0x4826, 0), write(0x2802, 0),
      write(0x6000, .max), write(0x6002, .max), write(0x6004, c0), write(0x6006, c4 & ~0x2000)
    else { return false }
    var state = VMXRunState()
    var cpu = VirtualCpuState(creator: 1)
    func run(_ state: inout VMXRunState, _ cpu: inout VirtualCpuState, _ reason: UInt32) -> Bool {
      var actual: UInt32?
      let r = runCpu(
        TarwinCall.virtualCpuRun, thread: 1, arm: { cpu.begin($0) },
        enter: {
          actual = state.run(enter: { enterVMX($0 ? 1 : 0) != 0 }, readReason: { get(0x4402) })
          return ExitRecord(
            reason: actual == 18 ? .hypercall : .exception,
            address: actual == 48 ? get(0x2400) : 0, width: 0, write: false, data: 0,
            registerIndex: 0)
        }, finish: { cpu.finish($0) })
      if case .success(let record) = r {
        return actual == reason
          && (reason == 18 ? record.reason == .hypercall : record.address == d)
      }
      return false
    }
    guard run(&state, &cpu, 18), data.pointee == 0x5347, get(0x440c) == 3,
      write(0x681e, get(0x681e) + 3), retire(&ept, &ram), map(&ept, &ram, 1), run(&state, &cpu, 48),
      get(0x6400) & 7 == 2,
      data.pointee == 0x5347, retire(&ept, &ram)
    else { return false }
    let readPC = nextPC(get(0x681e))
    guard readPC != 0, write(0x681e, readPC), run(&state, &cpu, 48), get(0x6400) & 7 == 1 else {
      return false
    }
    let jumpPC = nextPC(get(0x681e))
    return jumpPC != 0 && map(&ept, &ram, 3) && write(0x681e, jumpPC) && run(&state, &cpu, 48)
      && get(0x6400) & 7 == 4
  }
  let result = execute(&ept, &ram)
  let clear = command(1, v)
  let off = command(3, 0)
  return result && clear != 0 && off != 0 ? 1 : 0
}
