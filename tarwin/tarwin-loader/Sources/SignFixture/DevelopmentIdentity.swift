import Foundation
import TarwinLoader

enum Failure: Error { case invalid(String) }
func require(_ valid: Bool, _ reason: String) throws { if !valid { throw Failure.invalid(reason) } }
var fm: FileManager { FileManager.default }
let rootSubject = "/CN=Tarwin QEMU Development Only Root"
let subject = "/CN=Tarwin QEMU Development Only W0"
let algorithms = [("ed25519", "ED25519", 64), ("mldsa65", "ML-DSA-65", 3309)]

/// Invoke the host's OpenSSL provider; no crypto implementation or private
/// key material is linked into Tarwin or placed in its workspace.
struct DevelopmentIdentity {
  let dir: URL
  let temp: URL
  let openssl: URL
  func path(_ name: String) -> String { dir.appendingPathComponent(name).path }
  func tmp(_ name: String) -> String { temp.appendingPathComponent(name).path }
  @discardableResult func run(_ args: [String]) throws -> Data {
    let proc = Process()
    proc.executableURL = openssl
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardInput = FileHandle.nullDevice
    try proc.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    try require(proc.terminationStatus == 0, "OpenSSL rejected " + (args.first ?? "operation"))
    return data
  }
  func generate() throws {
    try fm.createDirectory(
      at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try run(["genpkey", "-algorithm", "ED25519", "-out", tmp("root.key")])
    try run([
      "req", "-new", "-x509", "-key", tmp("root.key"), "-subj", rootSubject, "-days", "2",
      "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0", "-addext",
      "keyUsage=critical,keyCertSign,cRLSign", "-out", path("root.pem"),
    ])
    let ext =
      "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n"
    try Data(ext.utf8).write(to: URL(fileURLWithPath: tmp("extensions")))
    for (n, a, _) in algorithms {
      try run(["genpkey", "-algorithm", a, "-out", path(n + ".key")])
      try run(["req", "-new", "-key", path(n + ".key"), "-subj", subject, "-out", tmp("leaf.csr")])
      try run([
        "x509", "-req", "-in", tmp("leaf.csr"), "-CA", path("root.pem"), "-CAkey", tmp("root.key"),
        "-days", "1", "-extfile", tmp("extensions"), "-out", path(n + ".pem"),
      ])
    }
    _ = try enrolledChain()
  }
  // Enroll the exact root AND both leaves from an independent directory;
  // the image never selects what OpenSSL trusts or reads from disk.
  func enrolledChain() throws -> Data {
    let root = try run(["x509", "-in", path("root.pem"), "-outform", "DER"]).base64EncodedString()
    let anchor = try run([
      "x509", "-in", path("root.pem"), "-noout", "-subject", "-nameopt", "compat",
    ])
    try require(
      String(decoding: anchor, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        == "subject=" + rootSubject, "not a QEMU development root")
    var chains: [String: [String]] = [:]
    for (n, _, _) in algorithms {
      let pem = path(n + ".pem")
      try run([
        "verify", "-x509_strict", "-check_ss_sig", "-purpose", "codesign", "-no-CApath",
        "-no-CAstore", "-trusted",
        path("root.pem"), pem,
      ])
      let name = try run(["x509", "-in", pem, "-noout", "-subject", "-nameopt", "compat"])
      try require(
        String(decoding: name, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
          == "subject=" + subject, "not a QEMU development leaf")
      let der = try run(["x509", "-in", pem, "-outform", "DER"])
      let pub = try run(["x509", "-in", pem, "-pubkey", "-noout"])
      try pub.write(to: URL(fileURLWithPath: tmp(n + ".pub")))
      // Only the exact RFC 8410/9881 SPKI encodings, absent parameters.
      let spki = try run(["pkey", "-pubin", "-in", tmp(n + ".pub"), "-outform", "DER"])
      let prefix: [UInt8] =
        n == "ed25519"
        ? [0x30, 0x2a, 0x30, 5, 6, 3, 0x2b, 0x65, 0x70, 3, 0x21, 0]
        : [
          0x30, 0x82, 0x07, 0xb2, 0x30, 0x0b, 6, 9, 0x60, 0x86, 0x48, 1, 0x65, 3, 4, 3, 0x12, 3,
          0x82, 7, 0xa1, 0,
        ]
      try require(
        spki.starts(with: prefix) && spki.count == prefix.count + (n == "ed25519" ? 32 : 1952),
        "wrong leaf algorithm")
      try spki.suffix(from: prefix.count).write(to: URL(fileURLWithPath: tmp(n + ".raw")))
      let lifetime = try validity(pem)
      try require(
        lifetime.1 > lifetime.0 && lifetime.1 - lifetime.0 <= 86400, "expected a one-day QEMU leaf")
      chains[n] = [der.base64EncodedString(), root]
    }
    return try JSONSerialization.data(
      withJSONObject: chains, options: [.sortedKeys, .withoutEscapingSlashes])
  }
  func validity(_ pem: String) throws -> (UInt64, UInt64) {
    let fields = String(
      decoding: try run(["x509", "-in", pem, "-noout", "-dates", "-dateopt", "iso_8601"]),
      as: UTF8.self
    ).split(separator: "\n")
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
    func parse(_ field: Substring, _ name: String) throws -> UInt64 {
      guard field.hasPrefix(name),
        let date = format.date(from: String(field.dropFirst(name.count))),
        date.timeIntervalSince1970 >= 0
      else { throw Failure.invalid("invalid enrollment dates") }
      return UInt64(date.timeIntervalSince1970)
    }
    try require(fields.count == 2, "missing dates")
    return try (parse(fields[0], "notBefore="), parse(fields[1], "notAfter="))
  }
  func enrollment(chain: Data) throws -> Data {
    var (start, end) = try validity(path("root.pem"))
    var s = stack()
    guard
      let hash = chain.withUnsafeBytes({ b in
        s.withUnsafeMutableBufferPointer { bootSetDigest(b, scratch: $0) }
      })
    else { throw Failure.invalid("chain digest") }
    var keys = Data()
    for (n, _, _) in algorithms {
      let (from, to) = try validity(path(n + ".pem"))
      start = max(start, from)
      end = min(end, to)
      keys += try Data(contentsOf: URL(fileURLWithPath: tmp(n + ".raw")))
    }
    try require(start < end, "empty validity intersection")
    return Data("TQE1".utf8) + little(start) + little(end) + words(hash) + keys
  }
  func signatures(_ msg: Data) throws -> Data {
    try msg.write(to: URL(fileURLWithPath: tmp("message")))
    var result = Data()
    for (n, _, size) in algorithms {
      try run([
        "pkeyutl", "-sign", "-rawin", "-inkey", path(n + ".key"), "-in", tmp("message"), "-out",
        tmp("sig"),
      ])
      let sig = try Data(contentsOf: URL(fileURLWithPath: tmp("sig")))
      try require(sig.count == size, "wrong signature length")
      result += sig
    }
    return result
  }
  func verify(_ msg: Data, envelope: Data, chain: Data) throws {
    try msg.write(to: URL(fileURLWithPath: tmp("message")))
    guard let e = envelope.withUnsafeBytes({ HybridEnvelope($0, descriptor: 0..<$0.count) }),
      Data(envelope[e.chain]) == chain
    else { throw Failure.invalid("not the enrolled hybrid identity") }
    for (n, _, _) in algorithms {
      try Data(envelope[n == "ed25519" ? e.ed25519 : e.mldsa65]).write(
        to: URL(fileURLWithPath: tmp("sig")))
      try run([
        "pkeyutl", "-verify", "-rawin", "-pubin", "-inkey", tmp(n + ".pub"), "-in", tmp("message"),
        "-sigfile", tmp("sig"),
      ])
    }
  }
}
