/// A single Ethernet interface, address and driver epoch. Construct only
/// after DAD/address assignment. Routes select an on-link next hop before
/// lookup. ARP and ND establish reachability, not peer authentication.
public struct NeighborInterface: Equatable {
  public let mac: [UInt8], address: [UInt8]
  public init?(mac: [UInt8], address: [UInt8]) {
    guard unicastMac(mac), validNextHop(address) else { return nil }
    self.mac = mac
    self.address = address
  }
  public func probe(_ target: [UInt8]) -> [UInt8]? {
    guard target.count == address.count, validNextHop(target), target != address else { return nil }
    if address.count == 4 { return arp(1, to: broadcast, peer: [0, 0, 0, 0, 0, 0], ip: target) }
    let dst = solicited(target)
    return nd(135, to: multicastMac(dst), ip: dst, target: target, flags: 0)
  }
  private func arp(_ op: UInt8, to: [UInt8], peer: [UInt8], ip: [UInt8]) -> [UInt8] {
    var b = to + mac
    b += [8, 6, 0, 1, 8, 0, 6, 4, 0, op]
    b += mac
    b += address
    b += peer
    b += ip
    return b
  }
  private func nd(_ type: UInt8, to: [UInt8], ip: [UInt8], target: [UInt8], flags: UInt8) -> [UInt8]
  {
    var b = to + mac
    b += [0x86, 0xdd, 0x60, 0, 0, 0, 0, 32, 58, 255]
    b += address
    b += ip
    b += [type, 0, 0, 0, flags, 0, 0, 0]
    b += target
    b += [type == 135 ? 1 : 2, 1]
    b += mac
    putWord(&b, 56, 0xffff ^ ndSum(b, 32))
    return b
  }
  /// Only answer requests for our configured address. Do not create a
  /// cache entry for an unsolicited sender (including a duplicate probe).
  public func reply(_ b: [UInt8]) -> [UInt8]? {
    guard b.count >= 14 else { return nil }
    let sender = Array(b[6..<12])
    let to = Array(b[0..<6])
    guard unicastMac(sender), sender != mac else { return nil }
    if address.count == 4 {
      guard goodArp(b, op: 1), to == mac || to == broadcast, b[38..<42].elementsEqual(address)
      else { return nil }
      let peer = Array(b[28..<32])
      guard validNextHop(peer) || peer == [0, 0, 0, 0] else { return nil }
      return arp(2, to: sender, peer: sender, ip: peer)
    }
    guard let opts = ndOptions(b, type: 135), b[62..<78].elementsEqual(address) else { return nil }
    let peer = Array(b[22..<38])
    let dst = Array(b[38..<54])
    let group = solicited(address)
    guard (dst == address && to == mac) || (dst == group && to == multicastMac(group)) else {
      return nil
    }
    if peer.allSatisfy({ $0 == 0 }) {
      guard opts.link == nil, dst == group else { return nil }
      let all: [UInt8] = [0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
      return nd(136, to: multicastMac(all), ip: all, target: address, flags: 0x20)
    }
    guard validNextHop(peer), opts.link == nil || opts.link == sender else { return nil }
    return nd(136, to: sender, ip: peer, target: address, flags: 0x60)
  }
  fileprivate func confirmation(_ b: [UInt8]) -> (ip: [UInt8], mac: [UInt8])? {
    guard b.count >= 14, b[0..<6].elementsEqual(mac) else { return nil }
    let sender = Array(b[6..<12])
    guard unicastMac(sender), sender != mac else { return nil }
    if address.count == 4 {
      guard goodArp(b, op: 2), b[32..<38].elementsEqual(mac), b[38..<42].elementsEqual(address)
      else { return nil }
      return (Array(b[28..<32]), sender)
    }
    guard let opts = ndOptions(b, type: 136), b[58] & 0x40 != 0, b[38..<54].elementsEqual(address),
      validNextHop(Array(b[22..<38])), opts.link == sender
    else { return nil }
    return (Array(b[62..<78]), sender)
  }
}
private let broadcast: [UInt8] = [255, 255, 255, 255, 255, 255]
func unicastMac(_ m: [UInt8]) -> Bool {
  m.count == 6 && m[0] & 1 == 0 && m.contains(where: { $0 != 0 })
}
func validNextHop(_ ip: [UInt8]) -> Bool {
  if ip.count == 4 { return ip[0] != 0 && ip[0] != 127 && ip[0] < 224 }
  return ip.count == 16 && ip[0] != 255 && ip.contains(where: { $0 != 0 })
    && !(ip.prefix(15).allSatisfy { $0 == 0 } && ip[15] == 1)
}
func solicited(_ target: [UInt8]) -> [UInt8] {
  [0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0xff] + target.suffix(3)
}
func multicastMac(_ ip: [UInt8]) -> [UInt8] { [0x33, 0x33] + ip.suffix(4) }
private func goodArp(_ b: [UInt8], op: UInt8) -> Bool {
  b.count >= 42 && b[12..<22].elementsEqual([8, 6, 0, 1, 8, 0, 6, 4, 0, op])
    && b[6..<12].elementsEqual(b[22..<28])
}
func ndSum(_ b: [UInt8], _ n: Int) -> UInt32 {
  let sum = sumBytes(b, 22, 32, UInt32(n) + 58)
  return sumBytes(b, 54, n, sum)
}
struct NdOptions { let link: [UInt8]? }
func ndOptions(_ b: [UInt8], type: UInt8) -> NdOptions? {
  guard b.count >= 78, word(b, 12) == 0x86dd, b[14] >> 4 == 6, b[20] == 58, b[21] == 255,
    b[54] == type, b[55] == 0
  else { return nil }
  let n = Int(word(b, 18))
  guard n >= 24, n <= b.count - 54, ndSum(b, n) == 65535 else { return nil }
  var next = 78
  var link: [UInt8]?
  while next < 54 + n {
    guard next + 2 <= 54 + n else { return nil }
    let bytes = Int(b[next + 1]) * 8
    guard bytes > 0, bytes <= 54 + n - next else { return nil }
    if b[next] == (type == 135 ? 1 : 2) {
      guard link == nil, bytes == 8 else { return nil }
      link = Array(b[(next + 2)..<(next + 8)])
    }
    next += bytes
  }
  return NdOptions(link: link)
}
public enum NeighborStep: Equatable {
  case send([UInt8])
  case resolved([UInt8])
  case waiting, unavailable
}
/// Bounded solicited-only cache. The owner serializes per-interface calls
/// using one monotonic clock and discards the table on readdress or restart.
public struct NeighborTable {
  private struct Entry {
    let ip: [UInt8]
    var mac: [UInt8]?, deadline: UInt64, tries: Int
  }
  public let interface: NeighborInterface
  private let limit: Int, retry: UInt64, lifetime: UInt64, maximum: Int
  private var entries: [Entry] = [], last: UInt64 = 0
  public init?(
    interface: NeighborInterface, limit: Int, retryNs: UInt64, reachableNs: UInt64,
    attempts: Int = 3
  ) {
    guard (1...4096).contains(limit), retryNs > 0, reachableNs > 0, (1...8).contains(attempts)
    else { return nil }
    self.interface = interface
    self.limit = limit
    retry = retryNs
    lifetime = reachableNs
    maximum = attempts
  }
  public mutating func resolve(_ ip: [UInt8], now: UInt64) -> NeighborStep {
    guard now >= last, now <= UInt64.max - retry, ip.count == interface.address.count,
      validNextHop(ip), ip != interface.address
    else { return .unavailable }
    last = now
    if let i = entries.firstIndex(where: { $0.ip == ip }) {
      if entries[i].deadline > now {
        if let m = entries[i].mac { return .resolved(m) }
        return .waiting
      }
      if entries[i].mac != nil {
        entries[i].tries = 0
        entries[i].mac = nil
      }
      guard entries[i].tries < maximum else {
        entries.remove(at: i)
        return .unavailable
      }
      entries[i].tries += 1
      entries[i].deadline = now + retry
    } else {
      if entries.count == limit {
        guard let i = entries.firstIndex(where: { $0.deadline <= now }) else { return .unavailable }
        entries.remove(at: i)
      }
      entries.append(Entry(ip: ip, mac: nil, deadline: now + retry, tries: 1))
    }
    guard let b = interface.probe(ip) else { return .unavailable }
    return .send(b)
  }
  public mutating func confirm(_ frame: [UInt8], now: UInt64) -> Bool {
    guard now >= last, now <= UInt64.max - lifetime else { return false }
    last = now
    guard let c = interface.confirmation(frame),
      let i = entries.firstIndex(where: { $0.ip == c.ip && $0.mac == nil && $0.deadline > now })
    else { return false }
    entries[i].mac = c.mac
    entries[i].deadline = now + lifetime
    return true
  }
}
