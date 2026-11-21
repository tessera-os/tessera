import Darwin

/// An IPv4 or IPv6 address and port, as Tarwin endpoints name peers.
public struct NetAddress: Hashable, Sendable, CustomStringConvertible {
  public enum Family: Sendable { case v4, v6 }
  public let family: Family
  /// 4 or 16 bytes, network order.
  public let bytes: [UInt8]
  public let port: UInt16

  public init?(_ bytes: [UInt8], port: UInt16) {
    guard bytes.count == 4 || bytes.count == 16 else { return nil }
    family = bytes.count == 4 ? .v4 : .v6
    self.bytes = bytes
    self.port = port
  }
  /// Numeric text only ("127.0.0.1", "::1"); never a host-name lookup.
  public init?(_ text: String, port: UInt16) {
    var a4 = in_addr(), a6 = in6_addr()
    if inet_pton(AF_INET, text, &a4) == 1 {
      self.init(withUnsafeBytes(of: a4) { Array($0) }, port: port)
    } else if inet_pton(AF_INET6, text, &a6) == 1 {
      self.init(withUnsafeBytes(of: a6) { Array($0) }, port: port)
    } else {
      return nil
    }
  }
  public static func any(_ family: Family, port: UInt16 = 0) -> NetAddress {
    NetAddress([UInt8](repeating: 0, count: family == .v4 ? 4 : 16), port: port)!
  }
  public static func loopback(_ family: Family, port: UInt16 = 0) -> NetAddress {
    family == .v4 ? NetAddress([127, 0, 0, 1], port: port)!
      : NetAddress([UInt8](repeating: 0, count: 15) + [1], port: port)!
  }

  /// IPv4-mapped IPv6 addresses are judged as the IPv4 address they carry.
  public var unmapped: NetAddress {
    guard family == .v6, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff,
      bytes[11] == 0xff
    else { return self }
    return NetAddress(Array(bytes[12...]), port: port)!
  }
  public var isLoopback: Bool {
    let a = unmapped
    return a.family == .v4 ? a.bytes[0] == 127 : a.bytes == NetAddress.loopback(.v6).bytes
  }
  public var isUnspecified: Bool { unmapped.bytes.allSatisfy { $0 == 0 } }
  public var isMulticastOrBroadcast: Bool {
    let a = unmapped
    return a.family == .v4 ? a.bytes[0] >= 224 : a.bytes[0] == 0xff
  }

  public var description: String {
    var buf = [CChar](repeating: 0, count: 64)
    _ = bytes.withUnsafeBytes {
      inet_ntop(family == .v4 ? AF_INET : AF_INET6, $0.baseAddress, &buf, 64)
    }
    let host = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return family == .v4 ? "\(host):\(port)" : "[\(host)]:\(port)"
  }

  func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    if family == .v4 {
      var s = sockaddr_in()
      s.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      s.sin_family = sa_family_t(AF_INET)
      s.sin_port = port.bigEndian
      withUnsafeMutableBytes(of: &s.sin_addr) { $0.copyBytes(from: bytes) }
      return withUnsafePointer(to: &s) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
      }
    }
    var s = sockaddr_in6()
    s.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    s.sin6_family = sa_family_t(AF_INET6)
    s.sin6_port = port.bigEndian
    withUnsafeMutableBytes(of: &s.sin6_addr) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &s) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
    }
  }
  init?(storage: UnsafePointer<sockaddr_storage>) {
    switch Int32(storage.pointee.ss_family) {
    case AF_INET:
      let s = UnsafeRawPointer(storage).load(as: sockaddr_in.self)
      self.init(withUnsafeBytes(of: s.sin_addr) { Array($0) }, port: UInt16(bigEndian: s.sin_port))
    case AF_INET6:
      let s = UnsafeRawPointer(storage).load(as: sockaddr_in6.self)
      self.init(
        withUnsafeBytes(of: s.sin6_addr) { Array($0) }, port: UInt16(bigEndian: s.sin6_port))
    default: return nil
    }
  }
}

/// An address prefix such as 10.0.0.0/8 or ::1/128.
public struct NetPrefix: Hashable, Sendable {
  public let base: NetAddress, length: Int
  public init?(_ text: String) {
    let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
    guard let a = NetAddress(parts[0], port: 0) else { return nil }
    let max = a.family == .v4 ? 32 : 128
    let len = parts.count == 2 ? Int(parts[1]) : max
    guard let len, len >= 0, len <= max else { return nil }
    base = a
    length = len
  }
  public func contains(_ address: NetAddress) -> Bool {
    let a = address.unmapped
    guard a.family == base.family else { return false }
    var bits = length
    for i in 0..<a.bytes.count where bits > 0 {
      let m: UInt8 = bits >= 8 ? 0xff : ~(0xff >> UInt8(bits))
      guard a.bytes[i] & m == base.bytes[i] & m else { return false }
      bits -= 8
    }
    return true
  }
}
