import TarwinSyscall

@_silgen_name("probe_enter")
private func enter(_ root: UInt64, _ control: UInt64, _ bank: UnsafeMutablePointer<UInt64>)
@_silgen_name("probe_invalidate") private func invalidate()

// Standalone, coherent, identity-mapped QEMU RAM, one stopped vCPU. The
// linker keeps the three pinned table frames, guest frames and bank disjoint.
// The guest instructions and initial register bank are trusted test data.
@_cdecl("run_probe")
public func runProbe(
  _ arena: UnsafeMutablePointer<UInt64>, _ code: UInt64,
  _ data: UnsafeMutablePointer<UInt64>, _ bank: UnsafeMutablePointer<UInt64>
) -> UInt32 {
  let page = ArmStageTwo.pageSize
  let textIPA: UInt64 = 0x10000
  let dataIPA: UInt64 = 0x2000000
  let root = UInt64(UInt(bitPattern: arena))
  let dataPA = UInt64(UInt(bitPattern: data))
  guard var tables = ArmStageTwo(arena: .init(start: arena, count: 6144), physicalBase: root)
  else { return 0 }
  func exercise(_ tables: inout ArmStageTwo) -> UInt32 {
    var text = GuestExtent()
    var ram = GuestExtent()
    func map(_ extent: inout GuestExtent, _ ipa: UInt64, _ pa: UInt64, _ access: UInt64) -> Bool {
      extent.map(
        ipa, 0, page, ArmStageTwo.ipaLimit, page, page, access, access,
        { _, _ in pa }, { tables.install(ipa: $0, bytes: $1, pinnedPA: $2, permissions: $3) },
        { _ in })
    }
    func retire() -> Bool {
      ram.retire(
        { tables.detach(ipa: $0, bytes: $1) },
        { _, _ in
          invalidate()
          return true
        }, { _ in })
    }
    var cpu = VirtualCpuState(creator: 1)
    let device: UInt64 = 0x4000000
    var access: ArmMMIOAccess?
    func run() -> ExitRecord? {
      let r = runCpu(
        TarwinCall.virtualCpuRun, thread: 1, arm: { cpu.begin($0) },
        enter: {
          enter(root, ArmStageTwo.vtcr, bank)
          access = ArmMMIOAccess(
            esr: bank[33], far: bank[34], hpfar: bank[35],
            registered: { $0 >= device && $0 < device + page && $1 <= device + page - $0 })
          if let access { return access.exit(readGPR: { bank[Int($0)] }) }
          if let op = armSystemExit(
            esr: bank[33], interruptPending: false,
            allow: { $0 == 0xc020 && !$1 }, readGPR: { bank[Int($0)] })
          {
            return op
          }
          return ExitRecord(
            reason: bank[33] >> 26 == 0x16 ? .hypercall : .exception,
            address: bank[34], width: 0, write: false, data: 0, registerIndex: 0)
        }, finish: { cpu.finish($0) })
      if case .success(let record) = r { return record }
      return nil
    }
    guard map(&text, textIPA, code, 5), map(&ram, dataIPA, dataPA, 3) else { return 0 }
    for i in 0..<36 { bank[i] = 0 }
    bank[31] = textIPA
    bank[32] = 0x3c5
    guard run()?.reason == .hypercall, bank[33] >> 26 == 0x16, bank[33] & 0xffff == 0x42,
      bank[0] == 4, bank[1] == dataIPA, data.pointee == 0x5347,
      retire(), map(&ram, dataIPA, dataPA, 1)
    else { return 0 }
    guard run()?.reason == .exception, bank[33] >> 26 == 0x24, bank[33] & 0x7f == 0x4f,
      bank[34] == dataIPA, data.pointee == 0x5347, retire()
    else { return 0 }
    bank[31] += 4
    guard run()?.reason == .exception, bank[33] >> 26 == 0x24, bank[33] & 0x7f == 7,
      bank[34] == dataIPA, (bank[35] & 0xff_ffff_fff0) << 8 == dataIPA,
      map(&ram, dataIPA, dataPA, 3)
    else { return 0 }
    bank[31] += 4
    guard let store = run(), store.reason == .mmio, store.address == device + 2,
      store.write, store.width == 2, store.data == 0xdead, store.registerIndex == 2
    else { return 0 }
    bank[31] += 4
    guard let load = run(), load.reason == .mmio, load.address == device + 1,
      !load.write, load.width == 1, load.registerIndex == 5, let op = access
    else { return 0 }
    op.completeLoad(0xf1, writeGPR: { bank[Int($0)] = $1 })
    bank[31] += 4
    guard run()?.reason == .hypercall, bank[33] & 0xffff == 0x43, bank[5] == UInt64.max - 14
    else { return 0 }
    guard run()?.reason == .wait else { return 0 }
    bank[31] += 4
    guard let sys = run(), sys.reason == .systemRegister, sys.address == 0xc020,
      !sys.write, sys.registerIndex == 7
    else { return 0 }
    bank[7] = 0x42
    bank[31] += 4
    guard run()?.reason == .hypercall, bank[33] & 0xffff == 0x44, bank[7] == 0x42 else { return 0 }
    func detach(_ ipa: UInt64, _ bytes: UInt64) -> Bool { tables.detach(ipa: ipa, bytes: bytes) }
    func sync(_ ipa: UInt64, _ bytes: UInt64) -> Bool {
      invalidate()
      return true
    }
    func install(_ ipa: UInt64, _ bytes: UInt64, _ pin: UInt64, _ access: UInt64) -> Bool {
      tables.install(ipa: ipa, bytes: bytes, pinnedPA: pin, permissions: access)
    }
    var dirty = TestDirtyLog(ram, page)
    for epoch: UInt64 in 1...2 {
      let before = data.pointee
      guard
        dirty.collect(
          &ram, expected: epoch == 1 ? 0 : 1, detach: detach, invalidate: sync, install: install),
        // With guest stage 1 off, FAR is the IPA; HPFAR can be
        // UNKNOWN for ordinary stage-2 permission faults.
        run()?.reason == .exception, bank[33] >> 26 == 0x24, bank[33] & 0x7ff == 0x4f,
        bank[34] == dataIPA,
        data.pointee == before,
        dirty.retry(&ram, ipa: bank[34], detach: detach, invalidate: sync, install: install),
        run()?.reason == .hypercall, bank[33] & 0xffff == 0x45, data.pointee == 0x7100 + epoch
      else { return 0 }
    }
    guard dirty.collect(&ram, expected: 1, detach: detach, invalidate: sync, install: install)
    else { return 0 }
    guard run()?.reason == .exception, bank[33] >> 26 == 0x20, bank[33] & 0x3f == 15,
      bank[34] == dataIPA
    else { return 0 }
    return 1
  }
  return exercise(&tables)
}
