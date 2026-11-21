import Foundation
import TarwinLoader

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, args.count <= 4,
  args.dropFirst(2).allSatisfy({ $0 == "--finalized" || $0 == "--no-entry" }),
  let machine = ["aarch64": ElfMachine.aarch64, "x64": ElfMachine.x64, "rv64": ElfMachine.rv64][
    args[0]]
else { fail("usage: inspect-unsigned <aarch64|x64|rv64> <image> [--finalized] [--no-entry]") }

let file = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let zero = BlakeCv(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0)
var stack = [BlakeCv](repeating: zero, count: 54)
guard
  let artifact = file.withUnsafeBytes({ bytes in
    stack.withUnsafeMutableBufferPointer {
      inspectUnsignedArtifact(
        bytes, machine: machine, addressLimit: UInt64.max,
        finalized: args.contains("--finalized"), requiresEntry: !args.contains("--no-entry"),
        scratch: $0)
    }
  })
else { fail("not a valid unsigned Tarwin v1 interchange artifact") }
let cv = artifact.buildID
let id = [cv.w0, cv.w1, cv.w2, cv.w3, cv.w4, cv.w5, cv.w6, cv.w7].flatMap { w in
  (0..<4).map { String(format: "%02x", (w >> (8 * $0)) & 255) }
}.joined()
print("unsigned \(args[0]) buildID=\(id) .tirload=\(artifact.section.count) bytes; not launchable")
