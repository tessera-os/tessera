import TIRCore

private let debugConfig = Array(#"{"flags":["debug"],"securityVersion":1,"slot":"A"}"#.utf8)
let maxNativeMemberBytes = 8 << 20

// Only the signer and guest verifier establish member roles and launch authority.
func bootSet(kernel: [UInt8]) throws -> [UInt8] {
  try pack([("boot.json", debugConfig), ("kernel", kernel)])
}

func stage1BootSet(kernel: [UInt8], initialProcess: [UInt8], library: [UInt8]) throws -> [UInt8] {
  try pack([("LibTessera", library), ("boot.json", debugConfig), ("kernel", kernel),
    ("tessera.init", initialProcess)])
}

func systemRootBootSet(
  kernel: [UInt8], initialProcess: [UInt8], library: [UInt8], metadataHeadSHA256: [UInt8]
) throws -> [UInt8] {
  guard metadataHeadSHA256.count == 32, metadataHeadSHA256.contains(where: { $0 != 0 })
  else { throw InputError("expected a nonzero raw 32-byte TRFS head digest") }
  return try pack([("LibTessera", library), ("boot.json", debugConfig), ("kernel", kernel),
    ("system.trfs.root", metadataHeadSHA256), ("tessera.init", initialProcess)])
}

// Callers fix the names and their unsigned UTF-8 directory order.
private func pack(_ members: [(String, [UInt8])]) throws -> [UInt8] {
  guard members.allSatisfy({ !$0.1.isEmpty && $0.1.count <= maxNativeMemberBytes }) else {
    throw InputError("boot member size out of range")
  }
  func le(_ n: Int) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: UInt64(n) >> (8 * $0)) } }
  var file: [UInt8] = [84, 73, 82, 65, 1, 0, 0, 0]
  file += le(members.count)
  file += le(members.reduce(24) { $0 + $1.1.count })
  var index: [UInt8] = []
  for (name, body) in members {
    index.append(UInt8(name.utf8.count))
    index += name.utf8
    index += le(file.count)
    index += le(body.count)
    index += le(body.count)
    index.append(0)
    index += BLAKE3.hash(body)
    file += body
  }
  return file + index
}
