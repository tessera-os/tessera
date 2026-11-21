import Foundation
import TIRCore
import TIRImage
import TarwinLoader

func packageKernel(_ object: ObjectFile) throws -> NativeImage {
  let train = TIRVersion(year: 26, month: 11, week: 1)
  let metadata = TarwinImageMetadata(
    buildTrain: train, expiryTrain: train,
    target: "aarch64.base", vectorMode: .fixed(vscale: 1), profile: .kernel, kind: .kernel)
  let image = try ImageLinker.link(
    [object],
    options: .init(
      platform: .tessera, architecture: .aarch64,
      output: .executable(entry: "tarwin_start"), tarwin: metadata))
  var stack = [BlakeCv](
    repeating: .init(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
  let ok = image.bytes.withUnsafeBytes { bytes in
    stack.withUnsafeMutableBufferPointer {
      inspectUnsignedArtifact(
        bytes, machine: ElfMachine.aarch64, addressLimit: 1 << 30, finalized: false,
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
      guard a.count == 3 else { throw InputError("usage: Stage0Image KERNEL.o NEW-UNSIGNED.elf") }
      let source = try Data(contentsOf: URL(fileURLWithPath: a[1]))
      let image = try packageKernel(readKernelObject(Array(source)))
      try Data(image.bytes).write(to: URL(fileURLWithPath: a[2]), options: .withoutOverwriting)
      print(
        "unsigned stage-0 aarch64 kernel: \(image.bytes.count) bytes, entry RVA 0x"
          + String(image.entryAddress, radix: 16))
    } catch {
      FileHandle.standardError.write(Data(("\(error)\n").utf8))
      exit(1)
    }
  }
}
