import TarwinSyscall

@_silgen_name("rv_enter") private func enter(_ hgatp: UInt64, _ bank: UnsafeMutablePointer<UInt64>)
@_silgen_name("rv_flush") private func flush()

// Host owns all test frames for the lifetime of this single-hart payload.
// VS has only its RX text and an independently pinned RAM page at a different IPA.
@_cdecl("run_rv_probe")
public func runRVProbe(
  _ arena: UnsafeMutablePointer<UInt64>, _ code: UInt64,
  _ data: UnsafeMutablePointer<UInt64>, _ bank: UnsafeMutablePointer<UInt64>
) -> UInt32 {
  let pa = UInt64(UInt(bitPattern: arena))
  let dataPA = UInt64(UInt(bitPattern: data))
  let textIPA: UInt64 = 0x10000
  let dataIPA: UInt64 = 0x200000
  guard
    var tables = GuestRadixTables(
      format: .sv48x4, arena: .init(start: arena, count: 4096),
      physicalBase: pa)
  else { return 0 }
  func exercise(_ tables: inout GuestRadixTables) -> UInt32 {
    let control = (UInt64(9) << 60) | (pa >> 12)  // VMID 0 on this private hart
    var cpu = VirtualCpuState(creator: 1)
    var text = GuestExtent()
    var ram = GuestExtent()
    func map(_ ext: inout GuestExtent, _ ipa: UInt64, _ pa: UInt64, _ rights: UInt64) -> Bool {
      ext.map(
        ipa, 0, 4096, 1 << 50, 4096, 4096, rights, rights, { _, _ in pa },
        { tables.install(ipa: $0, bytes: $1, pinnedPA: $2, permissions: $3) }, { _ in })
    }
    func retire() -> Bool {
      ram.retire(
        { tables.detach(ipa: $0, bytes: $1) },
        { _, _ in
          flush()
          return true
        }, { _ in })
    }
    var access: RVMMIOAccess?
    var system: ExitRecord?
    func run(_ expected: UInt64, mmio: Bool = false) -> Bool {
      let r = runCpu(
        TarwinCall.virtualCpuRun, thread: 1, arm: { cpu.begin($0) },
        enter: {
          enter(control, bank)
          func fetch(_ va: UInt64) -> UInt16? {
            guard bank[38] == 0, va >= textIPA && va - textIPA <= 4094,
              let p = UnsafeRawPointer(bitPattern: UInt(code + (va - textIPA)))
            else { return nil }
            return p.load(as: UInt16.self)
          }
          system = rvSystemExit(
            cause: bank[33], hstatus: bank[36], pc: bank[32], stval: bank[34],
            interruptPending: false, fetch: fetch, allowRead: { $0 == 0x180 })
          if let system { return system }
          access = RVMMIOAccess(
            cause: bank[33], hstatus: bank[36], stval: bank[34], htval: bank[35],
            htinst: bank[37], pc: bank[32], vsatp: bank[38], readGPR: { bank[Int($0)] },
            fetch: fetch, registered: { $0 >= 0x400000 && $0 < 0x401000 && $1 <= 0x401000 - $0 })
          if let access { return access.exit(readGPR: { bank[Int($0)] }) }
          return ExitRecord(
            reason: bank[33] == 10 ? .hypercall : .exception,
            address: bank[34], width: 0, write: false, data: 0, registerIndex: 0)
        }, finish: { cpu.finish($0) })
      if case .success(let exit) = r {
        if expected == 22 {
          return bank[33] == 22 && system != nil && exit.reason == system?.reason
        }
        if mmio { return bank[33] == expected && exit.reason == .mmio }
        return bank[33] == expected && bank[36] & 128 != 0
          && (expected == 10
            ? exit.reason == .hypercall
            : (exit.reason == .exception && bank[35] << 2 == dataIPA && exit.address == dataIPA))
      }
      return false
    }
    for i in 0..<37 { bank[i] = 0 }
    bank[32] = textIPA
    guard map(&text, textIPA, code, 5), map(&ram, dataIPA, dataPA, 3), run(10),
      data.pointee == 0x5347, bank[11] == dataIPA, retire(), map(&ram, dataIPA, dataPA, 1)
    else { return 0 }
    bank[32] += 4
    guard run(23), data.pointee == 0x5347, retire() else { return 0 }
    bank[32] += 4
    guard run(21), map(&ram, dataIPA, dataPA, 3) else { return 0 }
    bank[32] += 4
    guard run(23, mmio: true), let store = access, store.write, store.width == 4,
      store.address == 0x400000, store.exit(readGPR: { bank[Int($0)] }).data == 0x1234_5678,
      store.nextPC - bank[32] == 2
    else { return 0 }
    bank[32] = store.nextPC
    guard run(21, mmio: true), let word = access, !word.write, word.width == 4,
      word.address == 0x400004,
      word.nextPC - bank[32] == 2
    else { return 0 }
    word.completeLoad(0x8123_4567, writeGPR: { bank[Int($0)] = $1 })
    bank[32] = word.nextPC
    guard run(21, mmio: true), let byte = access, !byte.write, byte.width == 1,
      byte.address == 0x400003,
      byte.nextPC - bank[32] == 4
    else { return 0 }
    byte.completeLoad(0xfedc_ba98, writeGPR: { bank[Int($0)] = $1 })
    bank[32] = byte.nextPC
    guard run(10), bank[14] == 0xffff_ff81_2345_6798 else { return 0 }
    bank[32] += 4
    guard run(22), system?.reason == .wait else { return 0 }
    bank[32] += 4
    guard run(22), system?.reason == .systemRegister, system?.address == 0x180,
      system?.registerIndex == 16
    else { return 0 }
    bank[16] = 0x42
    bank[32] += 4
    guard run(10), bank[16] == 0x42 else { return 0 }
    bank[32] += 4
    func detach(_ ipa: UInt64, _ bytes: UInt64) -> Bool { tables.detach(ipa: ipa, bytes: bytes) }
    func sync(_ ipa: UInt64, _ bytes: UInt64) -> Bool {
      flush()
      return true
    }
    func install(_ ipa: UInt64, _ bytes: UInt64, _ pin: UInt64, _ access: UInt64) -> Bool {
      tables.install(ipa: ipa, bytes: bytes, pinnedPA: pin, permissions: access)
    }
    var dirty = TestDirtyLog(ram, 4096)
    for epoch: UInt64 in 1...2 {
      let before = data.pointee
      guard
        dirty.collect(
          &ram, expected: epoch == 1 ? 0 : 1, detach: detach, invalidate: sync, install: install),
        run(23), bank[38] == 0, bank[34] == dataIPA,
        data.pointee == before,
        dirty.retry(
          &ram, ipa: (bank[35] << 2) | (bank[34] & 3), detach: detach, invalidate: sync,
          install: install),
        run(10), data.pointee == 0x7100 + epoch
      else { return 0 }
      bank[32] += 4
    }
    guard dirty.collect(&ram, expected: 1, detach: detach, invalidate: sync, install: install)
    else { return 0 }
    return run(20) ? 1 : 0
  }
  return exercise(&tables)
}
