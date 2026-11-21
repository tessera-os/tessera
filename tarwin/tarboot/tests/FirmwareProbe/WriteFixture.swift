import CryptoKit
import Foundation

@main
enum WriteFixture {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count == 4, let target = ["aarch64": 183, "x86_64": 62, "riscv64": 243][args[1]]
    else { throw CocoaError(.fileWriteInvalidFileName) }
    let external = ProcessInfo.processInfo.environment["TARBOOT_TEST_STAGE0_ARCHIVE"]
    let fixture: Data
    if let external {
      fixture = try Data(contentsOf: URL(fileURLWithPath: external))
    } else {
      fixture = Data(archive(target: target))
    }
    try fixture.write(to: URL(fileURLWithPath: args[2]))
    let config = Data(
      (external == nil
        ? #"{"flags":[],"slot":"A"}"# : #"{"flags":["debug"],"securityVersion":1,"slot":"A"}"#).utf8
    )
    try config.write(
      to: URL(fileURLWithPath: args[3]).deletingLastPathComponent().appendingPathComponent(
        "expected-config.json"))
    func hex(_ bytes: Data) -> String {
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    var source = """
    let fixtureArchiveHash: StaticString = "\(hex(fixture))"
    let fixtureConfigHash: StaticString = "\(hex(config))"
    """
    if ProcessInfo.processInfo.environment["TARBOOT_TEST_FIFO"] == "1" {
      let digest = Data(SHA256.hash(data: Data("Tarwin post-exit FIFO fixture".utf8)))
      let after = SHA256.hash(data: Data(repeating: 0, count: 32) + digest)
      for (name, bytes) in [("fifoProbeDigest", digest), ("fifoProbePCR", Data(after))] {
        source += "\nlet \(name): InlineArray<32,UInt8> = [" + bytes.map(String.init).joined(separator: ",") + "]\n"
      }
    }
    if let file = ProcessInfo.processInfo.environment["TARBOOT_QEMU_ENROLLMENT"] {
      let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
      guard bytes.count == 2036, bytes.prefix(4).elementsEqual("TQE1".utf8) else { throw CocoaError(.fileReadCorruptFile) }
      source += "\n#if TARBOOT_TEST_SIGNED\nnonisolated(unsafe) var qemuEnrollment: InlineArray<2036,UInt8> = ["
        + bytes.map(String.init).joined(separator: ",") + "]\n#endif\n"
    }
    try source.write(toFile: args[3], atomically: true, encoding: .utf8)
  }
}
