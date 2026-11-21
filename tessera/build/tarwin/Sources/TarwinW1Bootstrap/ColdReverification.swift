#if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
import Tarboot
import TarwinDevice
import TarwinLoader
import TarwinW0Verify

extension QEMUW1Evidence {
  /// Single boot CPU, identity-mapped, coherent virt-11.1 debug machine.
  /// The authenticated early loader retains the work pages, all inputs and
  /// the device registers exclusively through placement/entry. No hotplug,
  /// snapshot, device restart or user mapping may invalidate the exclusion.
  /// Never resume a snapshot using this cold path.
  @unsafe public static func coldBootSet<R: QEMUFileReader>(
    work: borrowing FirmwareBootServices.ColdWorkspace,
    block: UnsafeRawBufferPointer, map: UnsafeRawBufferPointer, archive: UnsafeRawBufferPointer,
    reader: inout R, into storage: UnsafeMutableRawBufferPointer,
    enrollment: UnsafeRawBufferPointer, systemEnrollment: UnsafeRawBufferPointer,
    policy: W0Policy, contract: EarlyRIDLContract, scratch: UnsafeMutableRawBufferPointer,
    onRefusal: (VirtBootFenceResult) -> Void
  ) -> W1BootSet? {
    func span(_ bytes: UnsafeRawBufferPointer) -> DeviceRange {
      DeviceRange(base: UInt64(UInt(bitPattern: bytes.baseAddress)), length: UInt64(bytes.count))
    }
    guard !archive.isEmpty else { onRefusal(.badMemory); return nil }
    let a = span(archive)
    var extents = InlineArray<10, DeviceRange>(repeating: a)
    extents[1] = span(block)
    extents[2] = span(map)
    extents[3] = span(.init(storage))
    extents[4] = span(.init(scratch))
    if !enrollment.isEmpty { extents[5] = span(enrollment) }
    if !systemEnrollment.isEmpty { extents[6] = span(systemEnrollment) }
    if !contract.uuid.isEmpty { extents[7] = span(contract.uuid) }
    if !contract.symbol.isEmpty { extents[8] = span(contract.symbol) }
    if !contract.textSHA256.isEmpty { extents[9] = span(contract.textSHA256) }
    var bus = ColdBus()
    let result = withUnsafeBytes(of: &extents) {
      denyVirtBootDMA(table: work.table, commands: work.table + 4096,
        protected: $0.bindMemory(to: DeviceRange.self), bus: &bus)
    }
    guard result == .streamsDenied else { onRefusal(result); return nil }
    return verify(block: block, at: span(block).base, map: map, at: span(map).base,
      archive: archive, at: a.base, reader: &reader, into: storage, enrollment: enrollment,
      systemEnrollment: systemEnrollment, policy: policy, contract: contract, scratch: scratch)
  }
}
#endif
