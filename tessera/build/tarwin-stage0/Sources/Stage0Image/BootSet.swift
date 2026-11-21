import TIRCore

// Isolated W0 input for the archive signer. Kernel bytes may already have a
// native signature. Packing them neither verifies it nor signs the archive.
func bootSet(kernel: [UInt8]) throws -> [UInt8] {
  guard !kernel.isEmpty, kernel.count <= 8 << 20 else {
    throw InputError("kernel size out of range")
  }
  let config = Array(#"{"flags":["debug"],"securityVersion":1,"slot":"A"}"#.utf8)
  let members = [("boot.json", config), ("kernel", kernel)]
  func le(_ n: Int) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: UInt64(n) >> (8 * $0)) } }
  var file: [UInt8] = [84, 73, 82, 65, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0]
  file += le(24 + config.count + kernel.count)
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
