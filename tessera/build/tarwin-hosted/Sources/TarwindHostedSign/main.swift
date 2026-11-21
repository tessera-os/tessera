import Foundation
import TarwinTrapDecode
import TarwindSigning

func sign() throws {
  let args = Array(CommandLine.arguments.dropFirst())
  var appID: String?
  var entitlements: [String] = []
  var files: [String] = []
  var index = 0
  while index < args.count {
    let argument = args[index]
    if argument == "--app-id" || argument == "--entitlement" {
      index += 1
      guard index < args.count else { throw TarwindSigningError.invalidArguments }
      if argument == "--app-id" {
        guard appID == nil else { throw TarwindSigningError.invalidArguments }
        appID = args[index]
      } else { entitlements.append(args[index]) }
    } else {
      guard !argument.hasPrefix("--") else { throw TarwindSigningError.invalidArguments }
      files.append(argument)
    }
    index += 1
  }
  guard let appID, files.count == 2 else { throw TarwindSigningError.invalidArguments }
  let input = URL(fileURLWithPath: files[0]), output = URL(fileURLWithPath: files[1])
  let handle = try FileHandle(forReadingFrom: input)
  defer { try? handle.close() }
  guard try handle.seekToEnd() <= 64 * 1024 * 1024 else { throw TarwindSigningError.malformedImage }
  try handle.seek(toOffset: 0)
  var image = try TarwindSigningImage(try handle.readToEnd() ?? Data())
  let sites = try image.executableWords().filter {
    AArch64TrapInstruction.isSyscallInstruction($0.instruction)
  }.map(\.rva)
  try image.mergeSyscallSites(sites)
  let plan = try image.prepare(appID: appID, entitlements: entitlements)
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  let message = directory.appendingPathComponent("message")
  try plan.message.write(to: message)
  var signatures = Data()
  for (name, count) in [("ed25519", 64), ("mldsa65", 3309)] {
    guard let key = Bundle.module.url(forResource: name, withExtension: "key", subdirectory: "DevelopmentIdentity") else {
      throw TarwindSigningError.identity
    }
    let signature = directory.appendingPathComponent("signature")
    let process = Process()
    process.executableURL = URL(fileURLWithPath:
      ProcessInfo.processInfo.environment["OPENSSL"] ?? "/opt/homebrew/opt/openssl@3/bin/openssl")
    process.arguments = ["pkeyutl", "-sign", "-rawin", "-inkey", key.path, "-in", message.path, "-out", signature.path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw TarwindSigningError.signature }
    let bytes = try Data(contentsOf: signature)
    guard bytes.count == count else { throw TarwindSigningError.signature }
    signatures += bytes
  }
  try image.installSignatures(signatures, at: plan.signatures)
  try image.file.write(to: output, options: .withoutOverwriting)
  print("Signed hosted debug app \(appID); \(sites.count) SVC sites")
}

do { try sign() }
catch {
  FileHandle.standardError.write(Data("tarwin-hosted-sign: \(error)\nusage: tarwin-hosted-sign --app-id ID [--entitlement NAME] INPUT OUTPUT\n".utf8))
  exit(1)
}
