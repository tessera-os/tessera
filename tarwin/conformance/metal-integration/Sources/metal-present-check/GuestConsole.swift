import Foundation

/// Test relay on a private QEMU serial socket. Only fixed-size messages from
/// the monitor are accepted. Nothing on this channel names a file or host address.
final class GuestConsole {
  func note(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
  private func line() throws -> String {
    var bytes = [UInt8]()
    while bytes.count < 256, let b = try FileHandle.standardInput.read(upToCount: 1)?.first {
      if b == 10 { return String(decoding: bytes, as: UTF8.self) }
      if b != 13 { bytes.append(b) }
    }
    throw CheckError(message: "missing/oversize monitor line")
  }
  func begin() throws {
    // Skip the RV firmware banner only before the monitor announces itself.
    for _ in 0..<128 {
      let s = try line()
      if s == "TM-BEGIN" { return }
      if s.hasPrefix("TARWIN") { break }
    }
    throw CheckError(message: "missing TM-BEGIN")
  }
  func word(_ n: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }
  func reply(_ b: [UInt8]) throws {
    // Exactly the bytes requested by the private monitor. Do not append a newline.
    try FileHandle.standardOutput.write(contentsOf: Data(b))
  }
  func request() throws -> [UInt8] {
    let s = try line()
    guard s.hasPrefix("TMS1 "), s.utf8.count == 133 else {
      throw CheckError(message: "guest TMS1 framing")
    }
    let bytes = Array(s.utf8.dropFirst(5))
    return try (0..<64).map { i in
      try require(
        UInt8(String(decoding: bytes[2 * i...2 * i + 1], as: UTF8.self), radix: 16), "hex command")
    }
  }
  func rendered() throws { try check(try line() == "TM-RENDERED", "guest GPU acknowledgement") }
  func finish() throws {
    for s in [
      "TARWIN DEBUG GUEST", "MEMORY ONLINE", "BOOT CPU ONLINE", "TARWIN DEBUG CONSOLE PASS",
    ] {
      try check(try line() == s, "guest completion: " + s)
    }
  }
}
