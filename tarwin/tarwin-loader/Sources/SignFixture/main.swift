import Foundation
import TarwinLoader

func version(_ v: String) throws -> [UInt8] {
  let fields = v.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
  try require(
    fields.count == 3 && fields[0] > 0 && (1...12).contains(fields[1])
      && (1...5).contains(fields[2]) && fields.map(String.init).joined(separator: ".") == v,
    "invalid train or TIR version")
  return fields
}
func input(_ path: String) throws -> Data {
  let f = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
  defer { try? f.close() }
  var data = Data()
  let limit = 64 * 1024 * 1024
  while let chunk = try f.read(upToCount: 65536), !chunk.isEmpty {
    try require(data.count <= limit - chunk.count, "fixture exceeds 64 MiB")
    data += chunk
  }
  return data
}
func main() throws {
  let args = Array(CommandLine.arguments.dropFirst())
  guard args.count >= 2 else {
    throw Failure.invalid(
      "use init, sign-image, verify-image, sign-set or verify-set; see SIGN-FIXTURE.md")
  }
  let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(
    at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? fm.removeItem(at: temp) }
  let id = DevelopmentIdentity(
    dir: URL(fileURLWithPath: args[1]), temp: temp,
    openssl: URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["OPENSSL"]
        ?? "/opt/homebrew/opt/openssl@3/bin/openssl"))
  if args[0] == "init" {
    try require(
      args.count == 2 && !fm.fileExists(atPath: id.dir.path), "identity directory must be new")
    try id.generate()
    print("Created QEMU-only development identity. Do not enroll in production.")
    return
  }
  let chain = try id.enrolledChain()
  if args[0] == "enroll" {
    try require(args.count == 3, "expected identity output")
    try id.enrollment(chain: chain).write(
      to: URL(fileURLWithPath: args[2]), options: .withoutOverwriting)
    print(
      "QEMU-only public enrollment; install in trusted emulator harness, never load from image.")
    return
  }
  if args[0] == "sign-w1-debug-sdk" {
    try require(args.count == 5, "expected identity machine historical.ridlmeta NEW-RECEIPT")
    guard let machine = ["aarch64": ElfMachine.aarch64, "x64": ElfMachine.x64,
        "rv64": ElfMachine.rv64][args[2]] else { throw Failure.invalid("machine") }
    let sdk = try input(args[3])
    var bytes = Data(repeating: 0, count: 256)
    guard let n = sdk.withUnsafeBytes({ raw in bytes.withUnsafeMutableBytes {
      debugW1SDKMessage(raw, machine: machine, into: $0)
    } }) else { throw Failure.invalid("not the historical 26.11.1 SDK") }
    let msg = Data(bytes.prefix(n))
    var envelope = makeEnvelope(chain)
    envelope.replaceSubrange(envelope.count - 3373..<envelope.count, with: try id.signatures(msg))
    try id.verify(msg, envelope: envelope, chain: chain)
    try envelope.write(to: URL(fileURLWithPath: args[4]), options: .withoutOverwriting)
  } else if args[0] == "sign-w1-users" || args[0] == "verify-w1-users" {
    let signing = args[0] == "sign-w1-users"
    try require(args.count == (signing ? 7 : 5), "expected identity machine init library [NEW-INIT NEW-LIBRARY]")
    guard let machine = ["aarch64": ElfMachine.aarch64, "x64": ElfMachine.x64,
        "rv64": ElfMachine.rv64][args[2]] else { throw Failure.invalid("machine") }
    let roles: [EarlyUserRole] = [.initialProcess(entryTag: 0x4d3e_7643), .systemLibrary]
    var images = try (0..<2).map { i in
      let file = try input(args[3 + i])
      return signing ? try addEnvelope(file, chain, machine: machine, user: roles[i]) : file
    }
    try verifyUserPair(images[0], images[1], machine: machine)
    for i in 0..<2 {
      let (msg, env, span) = try signingParts(images[i], machine: machine,
        train: [26, 11, 1], tir: [26, 11, 2], user: roles[i])
      if signing { images[i].replaceSubrange(span, with: try id.signatures(msg)) }
      try id.verify(msg, envelope: Data(images[i][env]), chain: chain)
    }
    if signing {
      for i in 0..<2 {
        try images[i].write(to: URL(fileURLWithPath: args[5 + i]), options: .withoutOverwriting)
      }
    }
  } else if args[0] == "sign-set" || args[0] == "verify-set" {
    try require(args.count == 4, "expected identity archive sidecar")
    let archive = try input(args[2])
    var s = stack()
    guard archive.count >= 24, archive.starts(with: [0x54, 0x49, 0x52, 0x41, 1, 0, 0, 0]),
      let cv = archive.withUnsafeBytes({ b in
        s.withUnsafeMutableBufferPointer { bootSetDigest(b, scratch: $0) }
      })
    else { throw Failure.invalid("expected TIRA v1 archive") }
    let msg = Data("Tarwin boot set v1\0".utf8) + words(cv)
    if args[0] == "sign-set" {
      var envelope = makeEnvelope(chain)
      envelope.replaceSubrange(envelope.count - 3373..<envelope.count, with: try id.signatures(msg))
      try id.verify(msg, envelope: envelope, chain: chain)
      try envelope.write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
    } else {
      try id.verify(msg, envelope: try input(args[3]), chain: chain)
    }
  } else {
    let isUser = args[0] == "sign-user" || args[0] == "verify-user"
    let signing = args[0] == "sign-image" || args[0] == "sign-user"
    try require(
      (isUser || signing || args[0] == "verify-image")
        && args.count == (signing ? 7 : 6) + (isUser ? 1 : 0),
      "expected identity machine train tir [framework|init:HEX] input [output]")
    guard
      let machine = [
        "aarch64": ElfMachine.aarch64, "x64": ElfMachine.x64, "rv64": ElfMachine.rv64,
      ][args[2]]
    else { throw Failure.invalid("machine") }
    var user: EarlyUserRole?
    if isUser {
      if args[5] == "framework" {
        user = .systemLibrary
      } else if args[5].hasPrefix("init:"), let tag = UInt32(args[5].dropFirst(5), radix: 16) {
        user = .initialProcess(entryTag: tag)
      } else {
        throw Failure.invalid("expected framework or init:HEX")
      }
    }
    let i = isUser ? 6 : 5
    var file = try input(args[i])
    if signing { file = try addEnvelope(file, chain, machine: machine, user: user) }
    let (msg, env, signatures) = try signingParts(
      file, machine: machine, train: version(args[3]), tir: version(args[4]), user: user)
    if signing { file.replaceSubrange(signatures, with: try id.signatures(msg)) }
    try id.verify(msg, envelope: Data(file[env]), chain: chain)
    if signing {
      try file.write(to: URL(fileURLWithPath: args[i + 1]), options: .withoutOverwriting)
    }
  }
  print("QEMU development fixture: both signatures verified on host; no guest launch")
}
do { try main() } catch {
  FileHandle.standardError.write(Data("sign-fixture: \(error)\n".utf8))
  exit(1)
}
