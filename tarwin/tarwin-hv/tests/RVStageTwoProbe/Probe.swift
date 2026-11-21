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
  func run(_ expected: UInt64) -> Bool {
    let r = runCpu(
      TarwinCall.virtualCpuRun, thread: 1, arm: { cpu.begin($0) },
      enter: {
        enter(control, bank)
        return ExitRecord(
          reason: bank[33] == 10 ? .hypercall : .exception,
          address: bank[34], width: 0, write: false, data: 0, registerIndex: 0)
      }, finish: { cpu.finish($0) })
    if case .success(let exit) = r {
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
  return run(20) ? 1 : 0
}
