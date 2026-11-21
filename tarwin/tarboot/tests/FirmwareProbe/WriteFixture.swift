import CryptoKit
import Foundation

@main
enum WriteFixture {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count == 4, let target = ["aarch64": 183, "x86_64": 62, "riscv64": 243][args[1]]
    else { throw CocoaError(.fileWriteInvalidFileName) }
    let fixture = Data(archive(target: target))
    try fixture.write(to: URL(fileURLWithPath: args[2]))
    let config = Data(#"{"flags":[],"slot":"A"}"#.utf8)
    func hex(_ bytes: Data) -> String {
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    try """
    let fixtureArchiveHash: StaticString = "\(hex(fixture))"
    let fixtureConfigHash: StaticString = "\(hex(config))"
    """.write(toFile: args[3], atomically: true, encoding: .utf8)
  }
}
