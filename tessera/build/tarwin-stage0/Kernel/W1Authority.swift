#if TARWIN_NON_RESTORABLE_DEBUG
import Tarboot
import TarwinArchAarch64
import TarwinBoot
import TarwinLoader
import TarwinW0Verify

@_extern(c, "tarwin_w1_boot") private func bootPin() -> UnsafeRawPointer
@_extern(c, "tarwin_w1_system") private func systemPin() -> UnsafeRawPointer
@_extern(c, "tarwin_w1_sdk") private func installedSDK() -> UnsafeRawPointer
@_extern(c, "tarwin_w1_receipt") private func installedReceipt() -> UnsafeRawPointer
@_extern(c, "tarwin_w1_receipt_size") private func receiptSize() -> Int
@_extern(c, "tarwin_processor_snapshot") private func snapshot(_ out: UnsafeMutablePointer<UInt64>)
@_extern(c, "tarwin_mmio_read32") private func load32(_ p: UnsafeRawPointer) -> UInt32
@_extern(c, "tarwin_mmio_read8") private func load8(_ p: UnsafeRawPointer) -> UInt8
@_extern(c, "tarwin_mmio_write8") private func store8(_ p: UnsafeRawPointer, _ v: UInt8)

struct W1VirtTPM: TPMFIFORegisters {
  private let p = UnsafeRawPointer(bitPattern: 0x0c00_0000)!
  func access() -> UInt8 { load8(p) }
  func setAccess(_ v: UInt8) { store8(p, v) }
  func status() -> UInt32 { load32(p + 0x18) }
  func setStatus(_ v: UInt8) { store8(p + 0x18, v) }
  func receive() -> UInt8 { load8(p + 0x24) }
  func send(_ v: UInt8) { store8(p + 0x24, v) }
}

/// Called with immutable install constants, exclusive TPM, private workspace
/// and a host-owned UTC clock in this specific cold virt-11.1 debug machine.
/// No firmware verdict, archive timestamp or TBIB flags supply policy.
func withW1Authority<R>(port: inout TPMFIFO<W1VirtTPM>, work: UnsafeMutableRawBufferPointer,
  _ body: (W0Policy, UnsafeRawBufferPointer, UnsafeRawBufferPointer, EarlyRIDLContract) -> R) -> R? {
  var nvName: InlineArray<32, UInt8> = [
    153,36,237,96,117,77,224,179,204,215,111,177,106,104,33,94,
    62,216,121,131,3,130,95,107,144,89,201,29,0,141,121,15,
  ]
  guard let floor = withUnsafeBytes(of: &nvName, {
    readTPMSecurityFloor(&port, index: 0x0180_f001, name: $0)
  }) else { return nil }
  return withW1Authority(floor: floor, work: work, body)
}

func withW1Authority<R>(floor: UInt64, work: UnsafeMutableRawBufferPointer,
  _ body: (W0Policy, UnsafeRawBufferPointer, UnsafeRawBufferPointer, EarlyRIDLContract) -> R) -> R? {
  let rtc = UnsafeRawPointer(bitPattern: 0x0901_0000)!
  guard load32(rtc + 0xfe0) == 0x31, load32(rtc + 0xfe4) == 0x10,
    load32(rtc + 0xfe8) & 15 == 4, load32(rtc + 0xfec) == 0,
    load32(rtc + 0xff0) == 13, load32(rtc + 0xff4) == 0xf0,
    load32(rtc + 0xff8) == 5, load32(rtc + 0xffc) == 0xb1 else { return nil }
  let utc = UInt64(load32(rtc))
  var snapshotWords = InlineArray<32, UInt64>(repeating: 0)
  let baseline = withUnsafeMutableBytes(of: &snapshotWords) {
    let words = $0.bindMemory(to: UInt64.self)
    snapshot(words.baseAddress!)
    return ArmProcessorFeatures(.init(words))?.w0Registers == true
  }
  guard baseline else { return nil }
  let policy = W0Policy(machine: ElfMachine.aarch64, baselineSupported: baseline, trustedUTC: utc,
    train: (26,11,1), tir: (26,11,2), addressLimit: 1 << 30, securityFloor: floor, slot: 0, debugEmulator: true)
  let pin = UnsafeRawBufferPointer(start: systemPin(), count: 2036)
  let h = 54 * MemoryLayout<BlakeCv>.stride
  let n = receiptSize()
  guard (1...65536).contains(n), work.count >= h + 8192 + 1024,
    UInt(bitPattern: work.baseAddress) & 15 == 0 else { return nil }
  return withProvisionedDebugW1SDK(.init(start: installedSDK(), count: 83),
    receipt: .init(start: installedReceipt(), count: n), systemEnrollment: pin, policy: policy,
    hashes: UnsafeMutableRawBufferPointer(rebasing: work[..<h]).bindMemory(to: BlakeCv.self),
    polynomials: UnsafeMutableRawBufferPointer(rebasing: work[h..<h+8192]).bindMemory(to: Int32.self),
    message: .init(rebasing: work[h+8192..<h+8192+1024])) {
      body(policy, .init(start: bootPin(), count: 2036), pin, $0)
    }
}
#endif
