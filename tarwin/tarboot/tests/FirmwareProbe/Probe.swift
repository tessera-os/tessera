// EFI diagnostic, not tarboot or a Tarwin kernel. The dedicated QEMU instance
// powers off only after successful ExitBootServices and inspection of the returned map.
import Tarboot

private typealias Output = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt16>) -> UInt
private typealias Reset = @convention(c) (UInt32, UInt, UInt, UnsafeRawPointer?) -> Void
nonisolated(unsafe) private var storage = InlineArray<4096, UInt64>(repeating: 0)
nonisolated(unsafe) private var records = InlineArray<512, FirmwareRegion>(repeating: .empty)

@_cdecl("efi_main")
public func efiMain(_ image: UnsafeRawPointer?, _ system: UnsafeRawPointer?) -> UInt {
  let unsupported = (UInt(1) << 63) | 3
  // Only tables owned by firmware during EFI image entry; validate before field reads.
  guard let image, let system,
    FirmwareBootServices.valid(system, signature: 0x5453_5953_2049_4249, minimum: 120),
    let runtime = system.load(fromByteOffset: 88, as: UnsafeRawPointer?.self),
    FirmwareBootServices.valid(runtime, signature: 0x5652_4553_544e_5552, minimum: 112),
    let shutdown = runtime.load(fromByteOffset: 104, as: Reset?.self),
    let console = system.load(fromByteOffset: 64, as: UnsafeRawPointer?.self),
    let output = console.load(fromByteOffset: 8, as: Output?.self)
  else { return unsupported }
  let message: StaticString = "TARWIN-FIRMWARE-EXIT-TEST\r\n"
  for i in 0..<message.utf8CodeUnitCount {
    var character = (UInt16(message.utf8Start[i]), UInt16(0))
    _ = withUnsafeBytes(of: &character) {
      output(console, $0.bindMemory(to: UInt16.self).baseAddress!)
    }
  }
  // The two static arrays are disjoint, initialized, naturally aligned and exclusive.
  let done = withUnsafeMutableBytes(of: &storage) { raw in
    withUnsafeMutableBytes(of: &records) { bytes in
      var buffer = bytes.bindMemory(to: FirmwareRegion.self)
      guard let boot = FirmwareBootServices(image: image, system: system),
        case .exited(let n) = boot.finish(map: raw, into: &buffer)
      else { return false }
      var usable = false
      var runtime = false
      for i in 0..<n {
        let kind = buffer[i].bootMapKind(afterExit: true)
        usable = usable || kind == 0
        runtime = runtime || kind == 2 || kind == 3
      }
      return usable && runtime
    }
  }
  if done { shutdown(2, 0, 0, nil) }  // EfiResetShutdown; still in physical addressing mode.
  // Failure after a partial firmware shutdown is terminal. Never return into boot services.
  while true {}
}
