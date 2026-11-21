import Foundation

@main
enum WriteFixture {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count == 3, let target = ["aarch64": 183, "x86_64": 62, "riscv64": 243][args[1]]
    else { throw CocoaError(.fileWriteInvalidFileName) }
    try Data(archive(target: target)).write(to: URL(fileURLWithPath: args[2]))
  }
}
