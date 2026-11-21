import Foundation
import CryptoKit

// Build only the protected debug installation, independently of the ESP.
// Emit immutable ELF/COFF constants, not globals in guest writable RAM.
enum InstallError: Error { case invalid }
let a = CommandLine.arguments
guard a.count == 4 else { throw InstallError.invalid }
let directory = URL(fileURLWithPath: a[1])
func file(_ name: String, size: ClosedRange<Int>) throws -> Data {
  let f = try FileHandle(forReadingFrom: directory.appendingPathComponent(name))
  defer { try? f.close() }
  let b = try f.read(upToCount: size.upperBound + 1) ?? Data()
  guard size.contains(b.count) else { throw InstallError.invalid }
  return b
}
func pin(_ name: String, digest: String) throws -> Data {
  let b = try file(name, size: 2036...2036)
  guard b.starts(with: "TQE1".utf8),
    SHA256.hash(data: b).map({ String(format: "%02x", $0) }).joined() == digest
  else { throw InstallError.invalid }
  return b
}
let boot = try pin("boot.tqe1", digest: a[2]), system = try pin("system.tqe1", digest: a[3])
guard boot[20..<52] != system[20..<52], boot.suffix(1984) != system.suffix(1984) else { throw InstallError.invalid }
let sdk = try file("LibTessera.ridlmeta", size: 83...83)
let receipt = try file("aarch64.receipt", size: 1...65536)
// The guest checks the exact signed receipt; only the public pins are trusted.
for (name, bytes) in [("boot", boot), ("system", system), ("sdk", sdk), ("receipt", receipt)] {
  let encoded = bytes.map { String(format: "\\%02X", $0) }.joined()
  print("@w1_\(name) = private constant [\(bytes.count) x i8] c\"\(encoded)\", align 16")
  print("define hidden ptr @tarwin_w1_\(name)() nounwind { ret ptr @w1_\(name) }")
}
print("define hidden i64 @tarwin_w1_receipt_size() nounwind { ret i64 \(receipt.count) }")
