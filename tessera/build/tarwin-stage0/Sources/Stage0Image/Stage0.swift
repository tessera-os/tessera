import Foundation
import TIRCore
import TIRImage
import TarwinLoader

func packageKernel(_ object: ObjectFile) throws -> NativeImage {
  let train = TIRVersion(year: 26, month: 11, week: 1)
  let arm = object.architecture == .aarch64
  let metadata = TarwinImageMetadata(
    buildTrain: train, expiryTrain: train,
    target: arm ? "aarch64.base" : "x64.v3",
    features: arm ? [
      "bti", "crc", "dotprod", "fcma", "flagm", "flagm2", "fp16", "frintts", "jscvt",
      "lse", "lse2", "pauth", "rcpc", "rcpc2", "rdm", "sb", "ssbs",
    ] : [
      "aes", "avx", "avx2", "bmi1", "bmi2", "cx16", "erms", "f16c", "fma", "ibt",
      "lahf_sahf", "lzcnt", "movbe", "pclmul", "popcnt", "rdrand", "rdseed", "shstk",
      "sse3", "sse4_1", "sse4_2", "ssse3", "vaes", "vpclmulqdq", "xsave",
    ], vectorMode: .fixed(vscale: arm ? 1 : 2), profile: .kernel, kind: .kernel)
  let tag = UInt32(truncatingIfNeeded: BLAKE3.hash64(Array("fn(ptr) -> never abi(c)".utf8)))
  let veneer = TarwinEntryVeneer.object(entry: "tarwin_start", body: "tarwin_start_body",
    tag: tag, architecture: object.architecture)
  let image = try ImageLinker.link(
    [veneer, object],
    options: .init(
      platform: .tessera, architecture: object.architecture,
      output: .executable(entry: "tarwin_start"), tarwin: metadata))
  var stack = [BlakeCv](
    repeating: .init(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
  let ok = image.bytes.withUnsafeBytes { bytes in
    stack.withUnsafeMutableBufferPointer {
      inspectUnsignedArtifact(
        bytes, machine: arm ? ElfMachine.aarch64 : ElfMachine.x64, addressLimit: 1 << 30, finalized: false,
        requiresEntry: true, scratch: $0) != nil
    }
  }
  guard ok else { throw InputError("loader rejected A12 output") }
  return image
}

@main enum Stage0Image {
  static func main() {
    do {
      let a = CommandLine.arguments
      if a.count == 4, a[1] == "bootset" {
        let kernel = try Data(contentsOf: URL(fileURLWithPath: a[2]))
        let archive = try bootSet(kernel: Array(kernel))
        try Data(archive).write(to: URL(fileURLWithPath: a[3]), options: .withoutOverwriting)
        print("W0 archive signing input: \(archive.count) bytes; no detached signature")
        return
      }
      guard a.count == 3 else { throw InputError("usage: Stage0Image KERNEL.o NEW-UNSIGNED.elf") }
      let source = try Data(contentsOf: URL(fileURLWithPath: a[1]))
      let image = try packageKernel(readKernelObject(Array(source)))
      try Data(image.bytes).write(to: URL(fileURLWithPath: a[2]), options: .withoutOverwriting)
      print(
        "unsigned stage-0 kernel: \(image.bytes.count) bytes, entry RVA 0x"
          + String(image.entryAddress, radix: 16))
    } catch {
      FileHandle.standardError.write(Data(("\(error)\n").utf8))
      exit(1)
    }
  }
}
