import Tarboot
import TarwinDevice

typealias Locate =
  @convention(c) (UnsafeRawPointer, UnsafeRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>) ->
  UInt
private typealias Output = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt16>) -> UInt
private typealias Reset = @convention(c) (UInt32, UInt, UInt, UnsafeRawPointer?) -> Void
nonisolated(unsafe) private var scratch = PciWalkScratch()

// Read-only EFI_PCI_ROOT_BRIDGE_IO_PROTOCOL on the single segment-zero
// root bridge in these QEMU machines. No BAR writes, DMA or driver claims.
private func discover(_ system: UnsafeRawPointer) -> Bool {
  guard let boot = system.load(fromByteOffset: 96, as: UnsafeRawPointer?.self),
    FirmwareBootServices.valid(boot, signature: 0x5652_4553_544f_4f42, minimum: 328),
    let locate = boot.load(fromByteOffset: 320, as: Locate?.self)
  else { return false }
  var guid = (UInt64(0x11d4_4a1a_2f70_7ebb), UInt64(0x4dc1_3f27_9000_389a))
  var root: UnsafeRawPointer?
  guard withUnsafeBytes(of: &guid, { locate($0.baseAddress!, nil, &root) }) == 0,
    let root, root.load(fromByteOffset: 144, as: UInt32.self) == 0,
    let read = root.load(fromByteOffset: 56, as: PciRead?.self)
  else { return false }
  var disk = false
  var rng = false
  var count = 0
  var bridges: UInt64 = 0
  let ok = visitEcam(0, 255, scratch: &scratch) { off in
    let bdf = ((off >> 20) << 24) | (((off >> 15) & 31) << 16) | (((off >> 12) & 7) << 8)
    var value: UInt32 = .max
    let status = read(root, 2, UInt64(bdf | (off & 255)), 1, &value)
    return status == 0 ? value : .max
  } visit: { f in
    guard count < 64 else { return false }
    if f.parent == -1, f.bus == 0 {
      if f.classRevision >> 16 == 0x0604 { bridges |= 1 << count }
      if f.identity == 0x1042_1af4 || f.identity == 0x1001_1af4 { disk = true }
    } else if f.identity == 0x1044_1af4 {
      guard f.parent >= 0, f.parent < count, f.bus > 0, bridges & (1 << f.parent) != 0 else {
        return false
      }
      rng = checkConfig(root: root, read: read, function: f)
      #if arch(x86_64)
        rng = rng && checkQ35Ecam(locate: locate, root: root, read: read, function: f)
      #endif
    }
    count += 1
    return true
  }
  return ok && disk && rng
}

@_cdecl("efi_main")
public func efiMain(_ image: UnsafeRawPointer?, _ system: UnsafeRawPointer?) -> UInt {
  guard image != nil, let system,
    FirmwareBootServices.valid(system, signature: 0x5453_5953_2049_4249, minimum: 120),
    let rt = system.load(fromByteOffset: 88, as: UnsafeRawPointer?.self),
    FirmwareBootServices.valid(rt, signature: 0x5652_4553_544e_5552, minimum: 112),
    let reset = rt.load(fromByteOffset: 104, as: Reset?.self),
    let console = system.load(fromByteOffset: 64, as: UnsafeRawPointer?.self),
    let output = console.load(fromByteOffset: 8, as: Output?.self)
  else { return (1 << 63) | 3 }
  let msg: StaticString =
    discover(system) ? "TARWIN-PCI-TOPOLOGY-PASS\r\n" : "TARWIN-PCI-TOPOLOGY-FAIL\r\n"
  for i in 0..<msg.utf8CodeUnitCount {
    var pair = (UInt16(msg.utf8Start[i]), UInt16(0))
    _ = withUnsafeBytes(of: &pair) { output(console, $0.bindMemory(to: UInt16.self).baseAddress!) }
  }
  reset(2, 0, 0, nil)
  return (1 << 63) | 3
}
