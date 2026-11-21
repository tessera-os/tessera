// Offline provisioning for a new, isolated swtpm state directory only.
// No network endpoints, device paths or preexisting TPMs are accepted.
import Darwin
import Foundation

struct Failure: Error {
  let reason: String
  init(_ reason: String) { self.reason = reason }
}

func provision(_ dir: String) throws {
  guard try FileManager.default.contentsOfDirectory(atPath: dir).isEmpty else {
    throw Failure("nonempty state")
  }
  var fds = [Int32](repeating: -1, count: 2)
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw Failure("socketpair") }
  let host = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
  let peer = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
  var timeout = timeval(tv_sec: 5, tv_usec: 0)
  guard
    setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      == 0
  else {
    throw Failure("timeout")
  }
  // Foundation maps the private socket to stdin; swtpm requires an fd >= 3.
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/sh")
  p.arguments = [
    "-c", #"exec 3<&0; exec "$@""#, "swtpm-provision", "swtpm", "socket",
    "--tpm2", "--tpmstate", "dir=" + dir, "--flags", "not-need-init,startup-clear", "--fd", "3",
    "--terminate",
  ]
  p.standardInput = peer
  try p.run()
  defer {
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
  }
  try peer.close()
  func be(_ v: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: v >> $0) } }
  func read(_ n: Int) throws -> [UInt8] {
    var b = [UInt8]()
    while b.count < n {
      guard let more = try host.read(upToCount: n - b.count), !more.isEmpty else {
        throw Failure("short reply")
      }
      b += more
    }
    return b
  }
  func command(_ sessions: Bool, _ code: UInt32, _ args: [UInt8]) throws {
    let bytes: [UInt8] = [128, sessions ? 2 : 1] + be(UInt32(10 + args.count)) + be(code) + args
    try host.write(contentsOf: bytes)
    let h = try read(10)
    let size = h[2..<6].reduce(0) { $0 << 8 | Int($1) }
    guard size >= 10, size <= 128 else { throw Failure("invalid response") }
    _ = try read(size - 10)
    guard h[6..<10].allSatisfy({ $0 == 0 }) else {
      throw Failure("command \(code): \(Array(h[6..<10]))")
    }
  }
  let platform = be(0x4000_000c)
  let index = be(0x0180_f001)
  let pw = be(9) + be(0x4000_0009) + [0, 0, 0, 0, 0]
  let attributes = be(0x4204_0011)
  let nv = index + [0, 11] + attributes + [0, 0, 0, 8]
  try command(true, 0x12a, platform + pw + [0, 0, 0, 14] + nv)
  try command(true, 0x134, platform + index + pw)
  try command(false, 0x145, [0, 0])
  try host.close()
}
do {
  guard CommandLine.arguments.count == 2 else { throw Failure("expected empty state directory") }
  try provision(CommandLine.arguments[1])
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
