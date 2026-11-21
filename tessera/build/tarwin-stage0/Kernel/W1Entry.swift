#if TARWIN_NON_RESTORABLE_DEBUG
import Tarboot
import TarwinBoot
import TarwinKernelRandom
import TarwinLoader
import TarwinW0Verify
import TarwinW1Bootstrap

@_extern(c, "tarwin_mmio_read32") private func load32(_ p: UnsafeRawPointer) -> UInt32
@_extern(c, "tarwin_mmio_write32") private func store32(_ p: UnsafeRawPointer, _ v: UInt32)
@_extern(c, "tarwin_w1_sync_rx") private func synchronizeRX(_ start: UInt64, _ end: UInt64)

private func report(_ marker: StaticString) {
  let uart = UnsafeRawPointer(bitPattern: 0x0900_0000)!
  for i in 0..<marker.utf8CodeUnitCount {
    var polls = 500000
    while load32(uart + 0x18) & 32 != 0 {
      polls -= 1
      if polls == 0 { return }
    }
    store32(uart, UInt32(marker.utf8Start[i]))
  }
}

@_cdecl("tarwin_start_body")
public func w1KernelEntry(_ handoff: UnsafeRawPointer) -> Never {
  let address = UInt64(UInt(bitPattern: handoff))
  if let intake = W1ColdKernelIntake(handoff: address) {
    var bytes = InlineArray<1100, UInt8>(repeating: 0)
    var entropy = InlineArray<32, UInt8>(repeating: 0)
    let ok = withUnsafeMutableBytes(of: &bytes) { command in
      guard var port = TPMFIFO(registers: W1VirtTPM(), scratch: command, pollLimit: 500000),
        readTPMEntropy32(&port, into: &entropy) else { return false }
      let launch = withUnsafeBytes(of: &entropy) {
        FixedDebugRandomLaunch(policy: .debugQEMU, allowsMigration: false, allowsSnapshots: false,
          block: intake.block, at: address, map: intake.map, at: address + 4096,
          hardware: $0, source: .emulatedTPM)
      }
      entropy = .init(repeating: 0)
      guard var launch else { return false }
      let work = UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(bitPattern: UInt(intake.layout.scratch)), count: 16384)
      let verified: W1ColdVerifiedSet? = withW1Authority(port: &port, work: work) { policy, boot, system, contract in
        intake.snapshot(launch: launch, enrollment: boot, systemEnrollment: system, policy: policy,
          contract: contract)
      } ?? nil
      guard let verified else { return false }
      report("TARWIN-W1-KERNEL-REVERIFIED-BOOTSET\r\n")
      guard let images = verified.stageImages(map: intake.map, launch: &launch, cleanToPoU: {
        let start = UInt64(UInt(bitPattern: $0.baseAddress))
        guard start != 0, $0.count == 16384 else { return false }
        synchronizeRX(start, start + 16384)
        return true
      }) else {
        report("TARWIN-W1-KERNEL-REFUSED-PRIVATE-IMAGES\r\n")
        while true {}
      }
      report("TARWIN-W1-KERNEL-STAGED-PRIVATE-IMAGES\r\n")
      guard images.measureInit(port: &port) != nil else {
        report("TARWIN-W1-KERNEL-REFUSED-MEASUREMENT\r\n")
        while true {}
      }
      return true
    }
    if ok { report("TARWIN-W1-KERNEL-MEASURED-SIGNED-INIT-PCR10\r\n") }
    else { report("TARWIN-W1-KERNEL-REFUSED-AUTHORITY\r\n") }
  } else { report("TARWIN-W1-KERNEL-REFUSED-FENCE\r\n") }
  while true {}
}
#endif
