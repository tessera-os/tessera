import Darwin
import Dispatch

private final class Socket: Sendable {
  let fd: Int32
  init(_ descriptor: Int32) throws {
    guard descriptor >= 0 else { throw ProofError.system(errno) }
    fd = descriptor
  }
  deinit { close(fd) }
}

private func listenOnLoopback(_ port: UInt16) throws -> (Socket, UInt16) {
  let listener = try Socket(socket(AF_INET, SOCK_STREAM, 0))
  var addr = sockaddr_in()
  addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  addr.sin_port = port.bigEndian
  var length = socklen_t(addr.sin_len)
  try withUnsafeMutablePointer(to: &addr) {
    try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      guard bind(listener.fd, $0, length) == 0, listen(listener.fd, 1) == 0,
        getsockname(listener.fd, $0, &length) == 0 else { throw ProofError.system(errno) }
    }
  }
  return (listener, UInt16(bigEndian: addr.sin_port))
}

/// Both sockets bind only on IPv4 loopback. A connection to the sentinel fails the trial.
public final class LoopbackWitness: Sendable {
  private let allowed, denied: Socket
  public let allowedPort, deniedPort: UInt16
  public init(allowed: UInt16 = 43871, denied: UInt16 = 43872) throws {
    (self.allowed, allowedPort) = try listenOnLoopback(allowed)
    (self.denied, deniedPort) = try listenOnLoopback(denied)
  }

  private func wait(_ fd: Int32, _ events: Int16, until end: UInt64) throws {
    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < end else { throw ProofError.timeout }
      var fds = [pollfd(fd: denied.fd, events: Int16(POLLIN), revents: 0),
        pollfd(fd: fd, events: events, revents: 0)]
      let ms = min(UInt64(Int32.max), (end - now + 999_999) / 1_000_000)
      let n = poll(&fds, 2, Int32(ms))
      if n < 0 && errno == EINTR { continue }
      guard n >= 0 else { throw ProofError.system(errno) }
      guard n != 0 else { throw ProofError.timeout }
      guard fds[0].revents == 0 else { throw ProofError.deniedConnection }
      if fds[1].revents & events != 0 { return }
      if fds[1].revents != 0 { throw ProofError.disconnected }
    }
  }

  public func exchange(challenge: [UInt8], timeoutMilliseconds: UInt32 = 10_000) throws {
    guard challenge.count == 32 else { throw ProofError.invalidChallenge }
    let end = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
    try wait(allowed.fd, Int16(POLLIN), until: end)
    let peer = try Socket(accept(allowed.fd, nil, nil))
    var one: Int32 = 1
    guard setsockopt(peer.fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0
    else { throw ProofError.system(errno) }
    var reply = [UInt8](repeating: 0, count: 32)
    for reading in [false, true] {
      var count = 0
      while count < 32 {
        try wait(peer.fd, Int16(reading ? POLLIN : POLLOUT), until: end)
        let n: Int
        if reading {
          n = reply.withUnsafeMutableBytes { recv(peer.fd, $0.baseAddress! + count, 32 - count, MSG_DONTWAIT) }
        } else {
          n = challenge.withUnsafeBytes { send(peer.fd, $0.baseAddress! + count, 32 - count, MSG_DONTWAIT) }
        }
        if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
        guard n > 0 else { throw ProofError.disconnected }
        count += n
      }
    }
    guard reply == challenge else { throw ProofError.wrongReply }
  }

  /// Check again after verified task exit, not just when the positive response arrived.
  public func checkDeniedPort() throws {
    var fd = pollfd(fd: denied.fd, events: Int16(POLLIN), revents: 0)
    var n: Int32
    repeat { n = poll(&fd, 1, 0) } while n < 0 && errno == EINTR
    guard n >= 0 else { throw ProofError.system(errno) }
    guard n == 0 else { throw ProofError.deniedConnection }
  }
}
