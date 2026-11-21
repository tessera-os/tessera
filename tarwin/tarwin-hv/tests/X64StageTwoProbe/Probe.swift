import TarwinSyscall

@_silgen_name("npt_enter") private func enter()
@_silgen_name("x64_spills") private func spills() -> UnsafeMutablePointer<UInt64>
@_silgen_name("npt_next") private func nextPC(_ pc: UInt64) -> UInt64

// One dedicated ASID. The VMCB, HSAVE and software bank are private,
// physical pages identity-mapped by the bootstrap host. Guest CR3 points
// into three separate guest-owned pages translated through the NPT.
@_cdecl("run_npt_probe")
public func runNPTProbe(
  _ arena: UnsafeMutablePointer<UInt64>, _ code: UInt64,
  _ data: UnsafeMutablePointer<UInt64>, _ guest: UnsafeMutablePointer<UInt64>,
  _ vmcb: UnsafeMutableRawPointer
) -> UInt32 {
  func put<T: FixedWidthInteger>(_ offset: Int, _ value: T) {
    vmcb.storeBytes(of: value, toByteOffset: offset, as: T.self)
  }
  func get(_ offset: Int) -> UInt64 { vmcb.load(fromByteOffset: offset, as: UInt64.self) }
  let root = UInt64(UInt(bitPattern: arena))
  guard
    var tables = GuestRadixTables(
      format: .npt, arena: .init(start: arena, count: 4096),
      physicalBase: root)
  else { return 0 }
  let dataIPA: UInt64 = 0x200000
  let cr3: UInt64 = 0x3000000
  guest[0] = (cr3 + 4096) | 0x27
  guest[512] = (cr3 + 8192) | 0x27
  guest[1024] = 0xe7
  guest[1025] = dataIPA | 0xe7
  var cpu = VirtualCpuState(creator: 1)
  var ram = GuestExtent()
  var text = GuestExtent()
  var pt = GuestExtent()
  func map(
    _ extent: inout GuestExtent, _ ipa: UInt64, _ size: UInt64, _ pa: UInt64, _ rights: UInt64
  )
    -> Bool
  {
    extent.map(
      ipa, 0, size, 1 << 48, size, 4096, rights, rights, { _, _ in pa },
      { tables.install(ipa: $0, bytes: $1, pinnedPA: $2, permissions: $3) }, { _ in })
  }
  let dataPA = UInt64(UInt(bitPattern: data))
  guard map(&text, 0x10000, 4096, code, 5), map(&ram, dataIPA, 4096, dataPA, 3),
    map(&pt, cr3, 12288, UInt64(UInt(bitPattern: guest)), 3)
  else { return 0 }

  configureSVM(vmcb, root: root, cr3: cr3, rip: 0x10000)

  func run(_ expected: UInt64) -> Bool {
    let r = runCpu(
      TarwinCall.virtualCpuRun, thread: 1, arm: { cpu.begin($0) },
      enter: {
        put(0x5c, UInt8(1))  // flush every ASID before this test guest resumes
        enter()
        return ExitRecord(
          reason: get(0x70) == 0x81 ? .hypercall : .exception, address: get(0x80),
          width: 0, write: false, data: 0, registerIndex: 0)
      }, finish: { cpu.finish($0) })
    if case .success(let exit) = r {
      return get(0x70) == expected
        && (expected == 0x81
          ? exit.reason == .hypercall : (exit.reason == .exception && exit.address == dataIPA))
    }
    return false
  }
  // Frames stay pinned for this test's lifetime. Unlike synchronous TLBI,
  // SVM's TLB_CONTROL takes effect only at the next VMRUN. Do NOT report
  // shootdown to GuestExtent.retire or release real backing on a queued flush.
  guard run(0x81), data.pointee == 0x5347 else { return 0 }
  put(0x578, get(0x578) + 3)  // the controlled VMMCALL encoding
  guard let ints = GuestIntegerRegisters.x64(
    spills: .init(start: spills(), count: 14),
    rax: (vmcb + 0x5f8).assumingMemoryBound(to: UInt64.self),
    rsp: (vmcb + 0x5d8).assumingMemoryBound(to: UInt64.self))
  else { return 0 }
  var check = IntegerCheck(ints, stack: 4, ram: dataIPA)
  guard check.stage(cpu), run(0x81), check.restore(cpu, sum: 11, lhs: 6, rhs: 15) else { return 0 }
  put(0x578, get(0x578) + 3)
  guard tables.detach(ipa: dataIPA, bytes: 4096),
    tables.install(ipa: dataIPA, bytes: 4096, pinnedPA: dataPA, permissions: 1),
    run(0x400), get(0x78) & 3 == 3, data.pointee == 0x5347
  else { return 0 }
  var next = nextPC(get(0x578))
  guard next != 0, tables.detach(ipa: dataIPA, bytes: 4096) else { return 0 }
  put(0x578, next)
  guard run(0x400), get(0x78) & 3 == 0 else { return 0 }
  next = nextPC(get(0x578))
  guard next != 0, tables.install(ipa: dataIPA, bytes: 4096, pinnedPA: dataPA, permissions: 3)
  else { return 0 }
  put(0x578, next)
  return run(0x400) && get(0x78) & 0x11 == 0x11 ? 1 : 0
}
