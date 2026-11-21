import Darwin
import Synchronization

public enum NetError: Error, Equatable {
  case denied(String), limit, closed, wouldBlock, host(Int32)
}

public enum NetIO: Equatable {
  case bytes(Int)
  case wouldBlock
  case closed
}

/// One Tarwin network endpoint backed by one BSD socket owned by tarwind.
/// Sockets are non-blocking, close-on-exec and never raise SIGPIPE; `fd`
/// is for readiness registration in tarwind's event queue only.
public final class HostedSocketEndpoint: @unchecked Sendable {
  public enum Kind: Sendable, Equatable { case stream, listener, datagram }
  public let kind: Kind, app: String
  public let fd: Int32
  private let network: HostedNetwork
  /// For streams: the peer. For datagrams: the connected peer, if any.
  public let remote: NetAddress?
  private let closed = Atomic(false)

  init(kind: Kind, app: String, fd: Int32, remote: NetAddress?, network: HostedNetwork) {
    self.kind = kind
    self.app = app
    self.fd = fd
    self.remote = remote
    self.network = network
  }
  deinit { close() }

  public func close() {
    guard !closed.exchange(true, ordering: .acquiringAndReleasing) else { return }
    Darwin.close(fd)
    network.release(app)
  }
  public var isClosed: Bool { closed.load(ordering: .acquiring) }

  public var local: NetAddress? {
    var ss = sockaddr_storage()
    var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let rc = withUnsafeMutablePointer(to: &ss) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return rc == 0 ? withUnsafePointer(to: &ss) { NetAddress(storage: $0) } : nil
  }

  /// For a stream that is still connecting: nil while in progress, then the
  /// connect result.
  public func connectResult() -> NetError?? {
    var e: Int32 = 0
    var len = socklen_t(4)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &len) == 0 else { return .some(.host(errno)) }
    if e != 0 { return .some(.host(e)) }
    var ss = sockaddr_storage()
    var sl = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let rc = withUnsafeMutablePointer(to: &ss) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &sl) }
    }
    return rc == 0 ? .some(nil) : (errno == ENOTCONN ? nil : .some(.host(errno)))
  }

  private static func io(_ n: Int) -> NetIO {
    if n > 0 { return .bytes(n) }
    if n == 0 { return .closed }
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINPROGRESS ? .wouldBlock : .closed
  }

  public func send(_ bytes: UnsafeRawBufferPointer) -> NetIO {
    guard kind == .stream, !isClosed else { return .closed }
    if bytes.isEmpty { return .bytes(0) }
    return Self.io(Darwin.send(fd, bytes.baseAddress, bytes.count, 0))
  }
  public func receive(into buf: UnsafeMutableRawBufferPointer) -> NetIO {
    guard kind == .stream, !isClosed, !buf.isEmpty else { return .closed }
    return Self.io(recv(fd, buf.baseAddress, buf.count, 0))
  }
  public func shutdown(read: Bool, write: Bool) {
    guard read || write else { return }
    _ = Darwin.shutdown(fd, read && write ? SHUT_RDWR : read ? SHUT_RD : SHUT_WR)
  }

  /// Accepts one peer. Peers the filter denies are closed before the app
  /// sees them, and accepting continues.
  public func accept() throws -> HostedSocketEndpoint {
    guard kind == .listener, !isClosed else { throw NetError.closed }
    while true {
      var ss = sockaddr_storage()
      var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let c = withUnsafeMutablePointer(to: &ss) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &len) }
      }
      if c < 0 {
        if errno == EINTR || errno == ECONNABORTED { continue }
        throw errno == EAGAIN ? NetError.wouldBlock : .host(errno)
      }
      guard let peer = withUnsafePointer(to: &ss, { NetAddress(storage: $0) }),
        network.policy.check(NetFlow(app: app, proto: .tcp, direction: .inbound, address: peer))
          == .allow
      else {
        Darwin.close(c)
        network.count(denied: true)
        continue
      }
      guard network.reserve(app) else {
        Darwin.close(c)
        throw NetError.limit
      }
      HostedNetwork.configure(c)
      return HostedSocketEndpoint(kind: .stream, app: app, fd: c, remote: peer, network: network)
    }
  }

  /// Datagram send; every destination is filtered before sendto().
  public func sendDatagram(_ bytes: UnsafeRawBufferPointer, to peer: NetAddress) throws -> NetIO {
    guard kind == .datagram, !isClosed else { throw NetError.closed }
    let verdict = network.policy.check(
      NetFlow(app: app, proto: .udp, direction: .outbound, address: peer))
    guard verdict == .allow else {
      network.count(denied: true)
      if case .deny(let why) = verdict { throw NetError.denied(why) }
      throw NetError.denied("")
    }
    network.remember(app, peer)
    let n = peer.withSockaddr { sa, len in sendto(fd, bytes.baseAddress, bytes.count, 0, sa, len) }
    return n >= 0 ? .bytes(n) : Self.io(n)
  }

  /// Receives one datagram. Datagrams from sources the filter denies are
  /// dropped; replies from peers this app sent to are allowed.
  public func receiveDatagram(into buf: UnsafeMutableRawBufferPointer) throws -> (Int, NetAddress)? {
    guard kind == .datagram, !isClosed else { throw NetError.closed }
    while true {
      var ss = sockaddr_storage()
      var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let n = withUnsafeMutablePointer(to: &ss) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &len)
        }
      }
      if n < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN { return nil }
        throw NetError.host(errno)
      }
      guard let peer = withUnsafePointer(to: &ss, { NetAddress(storage: $0) }) else { continue }
      if network.replied(app, peer)
        || network.policy.check(NetFlow(app: app, proto: .udp, direction: .inbound, address: peer))
          == .allow
      {
        return (n, peer)
      }
      network.count(denied: true)
    }
  }
}

/// tarwind's socket broker: the only place hosted Tarwin opens host sockets.
/// Each call is filtered first, so a denied flow never reaches the socket API.
public final class HostedNetwork: @unchecked Sendable {
  public let policy: NetPolicy
  public let perAppLimit: Int
  private struct State {
    var open: [String: Int] = [:]
    var peers: [String: Set<NetAddress>] = [:]
    var denied = 0
  }
  private let state = Mutex(State())

  public init(policy: NetPolicy, perAppLimit: Int = 1024) {
    self.policy = policy
    self.perAppLimit = perAppLimit
  }

  public var deniedCount: Int { state.withLock { $0.denied } }
  public func openCount(_ app: String) -> Int { state.withLock { $0.open[app] ?? 0 } }

  func count(denied: Bool) { if denied { state.withLock { $0.denied += 1 } } }
  func reserve(_ app: String) -> Bool {
    state.withLock { s in
      let n = s.open[app] ?? 0
      guard n < perAppLimit else { return false }
      s.open[app] = n + 1
      return true
    }
  }
  func release(_ app: String) {
    state.withLock { s in
      let n = (s.open[app] ?? 1) - 1
      s.open[app] = n > 0 ? n : nil
      if n <= 0 { s.peers[app] = nil }
    }
  }
  func remember(_ app: String, _ peer: NetAddress) {
    state.withLock { s in
      if s.peers[app, default: []].count < 4096 { s.peers[app, default: []].insert(peer) }
    }
  }
  func replied(_ app: String, _ peer: NetAddress) -> Bool {
    state.withLock { $0.peers[app]?.contains(peer.unmapped) == true || $0.peers[app]?.contains(peer) == true }
  }

  static func configure(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
  }

  private func gate(_ f: NetFlow) throws {
    let v = policy.check(f)
    guard v == .allow else {
      count(denied: true)
      if case .deny(let why) = v { throw NetError.denied(why) }
      return
    }
    guard reserve(f.app) else { throw NetError.limit }
  }
  private func socket(_ family: NetAddress.Family, _ type: Int32, _ app: String) throws -> Int32 {
    let fd = Darwin.socket(family == .v4 ? AF_INET : AF_INET6, type, 0)
    guard fd >= 0 else {
      release(app)
      throw NetError.host(errno)
    }
    Self.configure(fd)
    return fd
  }

  /// Starts a non-blocking TCP connect; poll `connectResult()` on writability.
  public func connect(app: String, to peer: NetAddress) throws -> HostedSocketEndpoint {
    try gate(NetFlow(app: app, proto: .tcp, direction: .outbound, address: peer))
    let fd = try socket(peer.family, SOCK_STREAM, app)
    var one: Int32 = 1
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, 4)
    let rc = peer.withSockaddr { Darwin.connect(fd, $0, $1) }
    guard rc == 0 || errno == EINPROGRESS else {
      let e = errno
      Darwin.close(fd)
      release(app)
      throw NetError.host(e)
    }
    return HostedSocketEndpoint(kind: .stream, app: app, fd: fd, remote: peer, network: self)
  }

  public func listen(app: String, on local: NetAddress, backlog: Int32 = 128) throws
    -> HostedSocketEndpoint
  {
    try gate(NetFlow(app: app, proto: .tcp, direction: .listen, address: local))
    let fd = try socket(local.family, SOCK_STREAM, app)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
    guard local.withSockaddr({ bind(fd, $0, $1) }) == 0, Darwin.listen(fd, backlog) == 0 else {
      let e = errno
      Darwin.close(fd)
      release(app)
      throw NetError.host(e)
    }
    return HostedSocketEndpoint(kind: .listener, app: app, fd: fd, remote: nil, network: self)
  }

  /// A UDP endpoint bound to `local` (port 0 picks one). Binding beyond
  /// loopback with a fixed port is a listen and needs `server`.
  public func datagram(app: String, on local: NetAddress) throws -> HostedSocketEndpoint {
    let listening = local.port != 0 && !local.isLoopback
    if listening {
      try gate(NetFlow(app: app, proto: .udp, direction: .listen, address: local))
    } else {
      guard reserve(app) else { throw NetError.limit }
    }
    let fd = try socket(local.family, SOCK_DGRAM, app)
    guard local.withSockaddr({ bind(fd, $0, $1) }) == 0 else {
      let e = errno
      Darwin.close(fd)
      release(app)
      throw NetError.host(e)
    }
    return HostedSocketEndpoint(kind: .datagram, app: app, fd: fd, remote: nil, network: self)
  }
}
