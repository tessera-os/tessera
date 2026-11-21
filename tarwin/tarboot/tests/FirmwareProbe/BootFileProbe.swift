import Tarboot
import TarbootPreflight
import TarwinLoader

nonisolated(unsafe) private var digest = DigestScratch()
#if TARBOOT_TEST_STAGE0
  nonisolated(unsafe) private var frontier = InlineArray<54, BlakeCv>(
    repeating: .init(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0))
#endif

func exerciseFile(
  _ boot: inout FirmwareBootServices, system: UnsafeRawPointer, console: UnsafeRawPointer,
  output: Output, into out: UnsafeMutableRawBufferPointer
) -> Int? {
  let filename: StaticString = "\\BOOT.TIR"
  var path = InlineArray<10, UInt16>(repeating: 0)
  for i in 0..<filename.utf8CodeUnitCount { path[i] = UInt16(filename.utf8Start[i]) }
  return withUnsafeBytes(of: &path) { names in
    let path = names.bindMemory(to: UInt16.self)
    guard
      boot.readBootFile(path: path, into: UnsafeMutableRawBufferPointer(rebasing: out[..<1]))
        == nil,
      let size = boot.readBootFile(path: path, into: out)
    else { return nil }
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
    #if TARBOOT_TEST_STAGE0
      func memberRange(_ key: StaticString) -> Range<Int>? {
        let path = UnsafeRawBufferPointer(start: key.utf8Start, count: key.utf8CodeUnitCount)
        if case .intact(let range) = inspectRawMember(bytes, path: path, scratch: &digest) {
          return range
        }
        return nil
      }
      guard let kernelRange = memberRange("kernel"), let configRange = memberRange("boot.json"),
        !kernelRange.overlaps(configRange)
      else { return nil }
      let kernel = UnsafeRawBufferPointer(rebasing: bytes[kernelRange])
      let config = UnsafeRawBufferPointer(rebasing: bytes[configRange])
      guard let parsed = DebugBootConfig(config), parsed.slot == 0, parsed.securityVersion == 1
      else { return nil }
      guard
        let artifact = withUnsafeMutableBytes(
          of: &frontier,
          { b in
            inspectUnsignedArtifact(
              kernel, machine: target, addressLimit: 1 << 30, finalized: false,
              requiresEntry: true, scratch: b.bindMemory(to: BlakeCv.self))
          }), let profile = artifact.notes.profile, profile.count == 2,
        kernel[profile.lowerBound] == 3, kernel[profile.lowerBound + 1] == 4,
        case .invalidELF = inspectBootKernel(
          bytes, path: name, target: target, addressLimit: 1 << 30, scratch: &digest)
      else { return nil }
      writeDiagnostic("TARWIN-STAGE0-UNSIGNED-NOT-LAUNCHABLE\r\n", console: console, output: output)
    #else
      guard
        case .inspected(let extent, let info) = inspectBootKernel(
          bytes, path: name, target: target,
          addressLimit: 0x10000, scratch: &digest)
      else { return nil }
      guard extent == 24..<3525 && info.entry == 0x4080 && info.notes.buildID == 212..<244 else {
        return nil
      }
      let json: StaticString = #"{"flags":[],"slot":"A"}"#
      let config = UnsafeRawBufferPointer(start: json.utf8Start, count: json.utf8CodeUnitCount)
    #endif
    #if TARBOOT_TEST_TPM
      guard
        exerciseMeasurements(
          &boot, archive: bytes, config: config, system: system, console: console, output: output)
      else { return nil }
    #endif
    return size
  }
}
