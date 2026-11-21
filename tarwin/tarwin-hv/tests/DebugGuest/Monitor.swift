import TarwinSyscall

@_silgen_name("debug_layout") private func layout() -> UnsafePointer<UInt64>
@_silgen_name("debug_putchar") private func putchar(_ value: UInt32)

#if METAL_GUEST
  @_silgen_name("debug_getchar") private func getchar() -> UInt32
#endif

private func guestCalls(_ resume: () -> UInt64?) -> Bool {
  #if STORAGE_GUEST
    let l = layout()
    guard let work = UnsafeMutableRawPointer(bitPattern: UInt(l[6])),
      let scratch = UnsafeMutableRawPointer(bitPattern: UInt(l[7])),
      let disk = UnsafeRawPointer(bitPattern: UInt(l[8]))
    else { return false }
    var backend = ReadOnlyBlockGrant(), reads = 0
    while let op = resume() {
      if op == 0x4b44 { return reads != 0 }
      guard op == 0x5342, reads < 256,
        backend.read(grant: .init(start: work, count: 8192), scratch: .init(start: scratch, count: 8192),
          disk: .init(start: disk, count: 1048576)) else { return false }
      reads += 1
    }
    return false
  #else
  #if METAL_GUEST
    guard let screen = UnsafeMutableRawPointer(bitPattern: UInt(layout()[4])) else { return false }
    let p = screen + 14848
    func send(_ s: StaticString) {
      for i in 0..<s.utf8CodeUnitCount { putchar(UInt32(s.utf8Start[i])) }
    }
    func hex(_ n: UInt8) { putchar(UInt32(n < 10 ? 48 + n : 87 + n)) }
    for step in 0..<5 {
      var size = 32
      switch step {
      case 0:
        guard resume() == 0x4d10 else { return false }
        send("TM-BEGIN\n")
        size = 16
      case 1, 3:
        guard resume() == 0x4d11 else { return false }
        send("TMS1 ")
        for i in 0..<64 {
          let byte = p.load(fromByteOffset: i, as: UInt8.self)
          hex(byte >> 4)
          hex(byte & 15)
        }
        putchar(10)
      default:
        guard resume() == 0x4d12 else { return false }
        send("TM-RENDERED\n")
      }
      for i in 0..<size {
        p.storeBytes(of: UInt8(truncatingIfNeeded: getchar()), toByteOffset: 64 + i, as: UInt8.self)
      }
    }
  #endif
  return resume() == 0x4b44
  #endif
}

// The monitor links the immutable text/rodata image and reserves private
// backing for each guest extent. No physical address comes from the guest.
private func mapImage(_ page: UInt64, _ install: (UInt64, UInt64, UInt64, UInt64) -> Bool) -> Bool {
  let l = layout()
  #if STORAGE_GUEST
    guard install(0x540000, 16384, l[6], 3) else { return false }
  #endif
  return l[1] > 0 && l[1] <= 0xf0000 && l[1] % page == 0
    && install(0x10000, l[1], l[0], 5) && install(0x100000, 65536, l[2], 3)
    && install(0x180000, page, l[3], 1) && install(0x200000, 16384, l[4], 3)
    && install(0x400000, 64 * page, l[5], 3)
}

private func boot(_ operation: () -> Bool) -> UInt32 {
  var cpu = VirtualCpuState(creator: 1)
  let exit = runCpu(
    TarwinCall.virtualCpuRun, thread: 1, arm: { cpu.begin($0) },
    enter: {
      ExitRecord(
        reason: operation() ? .hypercall : .exception, address: 0, width: 0,
        write: false, data: 0, registerIndex: 0)
    }, finish: { cpu.finish($0) })
  guard case .success(let record) = exit, record.reason == .hypercall,
    let screen = UnsafeRawPointer(bitPattern: UInt(layout()[4]))
  else { return 0 }
  // Fixed frame: never follow an address from the launch result.
  let count = screen.load(fromByteOffset: 16376, as: UInt64.self)
  guard count > 0 && count <= 256 else { return 0 }
  #if STORAGE_GUEST
    let rows = 4
  #else
    let rows = 3
  #endif
  for row in 0..<rows {
    var ink = false
    for i in 0..<(108 * 8)
    where screen.load(fromByteOffset: (row * 108 * 8 + i) * 4, as: UInt32.self) == 0xffffff {
      ink = true
    }
    if !ink { return 0 }
  }
  for i in 0..<Int(count) {
    let byte = screen.load(fromByteOffset: 14336 + i, as: UInt8.self)
    guard byte == 10 || (32...126).contains(byte) else { return 0 }
  }
  for i in 0..<Int(count) {
    putchar(UInt32(screen.load(fromByteOffset: 14336 + i, as: UInt8.self)))
  }
  return 1
}

#if arch(arm64)
  @_silgen_name("probe_enter") private func enter(
    _ root: UInt64, _ vtcr: UInt64, _ regs: UnsafeMutablePointer<UInt64>)
  @_cdecl("run_probe") public func arm(
    _ arena: UnsafeMutablePointer<UInt64>, _ unused: UInt64, _ data: UInt64,
    _ regs: UnsafeMutablePointer<UInt64>
  ) -> UInt32 {
    let root = UInt64(UInt(bitPattern: arena))
    guard var t = ArmStageTwo(arena: .init(start: arena, count: 6144), physicalBase: root),
      mapImage(16384, { t.install(ipa: $0, bytes: $1, pinnedPA: $2, permissions: $3) })
    else { return 0 }
    for i in 0..<37 { regs[i] = 0 }
    regs[0] = 0x180000
    regs[31] = 0x10000
    regs[32] = 0x3c5
    return boot {
      guestCalls {
        enter(root, ArmStageTwo.vtcr, regs)
        return regs[33] >> 26 == 0x16 && regs[33] & 0xffff == 0x4b ? regs[0] : nil
      }
    }
  }
#elseif arch(riscv64)
  @_silgen_name("rv_enter") private func enter(
    _ control: UInt64, _ regs: UnsafeMutablePointer<UInt64>)
  @_cdecl("run_rv_probe") public func rv(
    _ arena: UnsafeMutablePointer<UInt64>, _ unused: UInt64, _ data: UInt64,
    _ regs: UnsafeMutablePointer<UInt64>
  ) -> UInt32 {
    let root = UInt64(UInt(bitPattern: arena))
    guard
      var t = GuestRadixTables(
        format: .sv48x4, arena: .init(start: arena, count: 8192), physicalBase: root),
      mapImage(4096, { t.install(ipa: $0, bytes: $1, pinnedPA: $2, permissions: $3) })
    else { return 0 }
    for i in 0..<37 { regs[i] = 0 }
    regs[11] = 0x180000
    regs[32] = 0x10000
    return boot {
      guestCalls {
        enter((UInt64(9) << 60) | (root >> 12), regs)
        guard regs[33] == 10, regs[36] & 128 != 0 else { return nil }
        regs[32] += 4
        return regs[10]
      }
    }
  }
#elseif arch(x86_64)
  @_silgen_name("npt_enter") private func enter()
  @_silgen_name("debug_rdi") private func rdi(_ value: UInt64)
  @_cdecl("run_npt_probe") public func x64(
    _ arena: UnsafeMutablePointer<UInt64>, _ unused: UInt64, _ data: UInt64,
    _ guest: UnsafeMutablePointer<UInt64>, _ vmcb: UnsafeMutableRawPointer
  ) -> UInt32 {
    let root = UInt64(UInt(bitPattern: arena))
    let pt: UInt64 = 0x3000000
    guard
      var t = GuestRadixTables(
        format: .npt, arena: .init(start: arena, count: 8192), physicalBase: root),
      mapImage(4096, { t.install(ipa: $0, bytes: $1, pinnedPA: $2, permissions: $3) }),
      t.install(ipa: pt, bytes: 12288, pinnedPA: UInt64(UInt(bitPattern: guest)), permissions: 3)
    else { return 0 }
    guest[0] = pt + 4096 | 0x27
    guest[512] = pt + 8192 | 0x27
    for i in 0..<3 { guest[1024 + i] = UInt64(i) << 21 | 0xe7 }
    configureSVM(vmcb, root: root, cr3: pt, rip: 0x10000)
    rdi(0x180000)
    return boot {
      guestCalls {
        vmcb.storeBytes(of: UInt8(1), toByteOffset: 0x5c, as: UInt8.self)
        enter()
        guard vmcb.load(fromByteOffset: 0x70, as: UInt64.self) == 0x81 else { return nil }
        // The linked test guest uses an unprefixed three-byte VMMCALL.
        let rip = vmcb.load(fromByteOffset: 0x578, as: UInt64.self)
        vmcb.storeBytes(of: rip + 3, toByteOffset: 0x578, as: UInt64.self)
        return vmcb.load(fromByteOffset: 0x5f8, as: UInt64.self)
      }
    }
  }
#endif
