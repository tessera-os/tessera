import Foundation

@main enum Driver {
  static let package = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  static let packages = package.deletingLastPathComponent().deletingLastPathComponent()

  static func source() throws -> String {
    let doc = try String(
      contentsOf: packages.appendingPathComponent("tessera/roadmap/16-libtessera.md"),
      encoding: .utf8)
    let ext = try String(
      contentsOf: package.appendingPathComponent("extensions.txt"), encoding: .utf8)
    let entries = ext.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.map(
      String.init)
    return try Catalogue.render(
      Catalogue.number(Catalogue.publicNames(in: doc), extensions: entries))
  }

  static func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.isEmpty || args == ["--check"] else {
      throw IndexError("usage: call-index [--check]")
    }
    let source = try source()
    for output in [
      package.appendingPathComponent("Sources/TarwinSyscall/CallNumbers.swift"),
      packages.appendingPathComponent("libtessera/app/Backend/Tarwin/CallNumbers.swift"),
    ] {
      if args.isEmpty {
        try source.write(to: output, atomically: true, encoding: .utf8)
      } else if try String(contentsOf: output, encoding: .utf8) != source {
        throw IndexError("Stale call numbers: \(output.path)")
      }
    }
  }
}
