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
    try """
    let fixtureArchiveHash: StaticString = "\(hex(fixture))"
    let fixtureConfigHash: StaticString = "\(hex(config))"
    """.write(toFile: args[3], atomically: true, encoding: .utf8)
  }
}
