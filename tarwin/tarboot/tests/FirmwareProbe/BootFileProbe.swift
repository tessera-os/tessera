import Tarboot
import TarbootPreflight
import TarwinLoader

nonisolated(unsafe) private var digest = DigestScratch()
nonisolated(unsafe) private var snapshot = InlineArray<4096, UInt8>(repeating: 0)

func exerciseFile(
  _ boot: inout FirmwareBootServices, system: UnsafeRawPointer, console: UnsafeRawPointer,
  output: Output
) -> Bool {
  let filename: StaticString = "\\BOOT.TIR"
  var path = InlineArray<10, UInt16>(repeating: 0)
  for i in 0..<filename.utf8CodeUnitCount { path[i] = UInt16(filename.utf8Start[i]) }
  return withUnsafeBytes(of: &path) { names in
    let path = names.bindMemory(to: UInt16.self)
    return withUnsafeMutableBytes(of: &snapshot) { out in
      guard
        boot.readBootFile(path: path, into: UnsafeMutableRawBufferPointer(rebasing: out[..<1]))
          == nil,
        let size = boot.readBootFile(path: path, into: out)
      else { return false }
      let bytes = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(out)[..<size])
      let member: StaticString = "kernel"
      let name = UnsafeRawBufferPointer(start: member.utf8Start, count: member.utf8CodeUnitCount)
      #if arch(arm64)
        let target: UInt16 = 183
      #elseif arch(x86_64)
        let target: UInt16 = 62
      #elseif arch(riscv64)
        let target: UInt16 = 243
      #endif
      guard
        case .inspected(let extent, let info) = inspectBootKernel(
          bytes, path: name, target: target,
          addressLimit: 0x10000, scratch: &digest)
      else { return false }
      guard extent == 24..<3525 && info.entry == 0x4080 && info.notes.buildID == 212..<244 else {
        return false
      }
      #if TARBOOT_TEST_TPM
        return exerciseMeasurements(
          &boot, archive: bytes, system: system, console: console, output: output)
      #else
        return true
      #endif
    }
  }
}
