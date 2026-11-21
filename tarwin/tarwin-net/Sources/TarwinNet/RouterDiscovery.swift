private let allNodes: [UInt8] = [255, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
private let allRouters: [UInt8] = [255, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]
private let unspecified = [UInt8](repeating: 0, count: 16)
private func linkLocal(_ a: [UInt8]) -> Bool {
  a.count == 16 && a[0] == 0xfe && (a[1] & 0xc0) == 0x80
}
private func solicitation(mac: [UInt8], source: [UInt8], destination: [UInt8], body: [UInt8])
  -> [UInt8]
{
  var bytes = multicastMac(destination) + mac
  bytes += [0x86, 0xdd, 0x60, 0, 0, 0, 0, UInt8(body.count), 58, 255]
  bytes += source
  bytes += destination
  bytes += body
  putWord(&bytes, 56, 0xffff ^ ndSum(bytes, body.count))
  return bytes
}
private func expiry(_ now: UInt64, _ seconds: UInt32) -> UInt64 {
  if seconds == UInt32.max || UInt64(seconds) > UInt64.max - now { return .max }
  return now + UInt64(seconds)
}
private struct PrefixOffer { let prefix: [UInt8], valid: UInt32, preferred: UInt32 }
private struct Advertisement {
  let router: [UInt8], lifetime: UInt32, offers: [PrefixOffer]
  init?(_ b: [UInt8], link: NeighborInterface, allowRouter: ([UInt8], [UInt8]) -> Bool) {
    guard b.count >= 70, word(b, 12) == 0x86dd, b[14] >> 4 == 6, b[20] == 58, b[21] == 255,
      b[54] == 134, b[55] == 0
    else { return nil }
    let n = Int(word(b, 18))
    let ip = Array(b[22..<38])
    let mac = Array(b[6..<12])
    let dst = Array(b[38..<54])
    guard n >= 16, n <= b.count - 54, linkLocal(ip), ip != link.address, unicastMac(mac),
      mac != link.mac,
      (dst == link.address && b[0..<6].elementsEqual(link.mac))
        || (dst == allNodes && b[0..<6].elementsEqual(multicastMac(dst))),
      ndSum(b, n) == 65535, allowRouter(ip, mac)
    else { return nil }
    var cursor = 70
    var offers: [PrefixOffer] = []
    var hasSource = false
    let end = 54 + n
    while cursor < end {
      guard end - cursor >= 2 else { return nil }
      let len = Int(b[cursor + 1]) * 8
      guard len > 0, len <= end - cursor else { return nil }
      if b[cursor] == 1 {
        guard !hasSource, len == 8, b[(cursor + 2)..<(cursor + 8)].elementsEqual(mac) else {
          return nil
        }
        hasSource = true
      } else if b[cursor] == 3 {
        guard len == 32 else { return nil }
        let prefix = Array(b[(cursor + 16)..<(cursor + 24)])
        let valid = word(b, cursor + 4) << 16 | word(b, cursor + 6)
        let pref = word(b, cursor + 8) << 16 | word(b, cursor + 10)
        // A and L are independent. This path configures addresses only.
        if b[cursor + 2] == 64, b[cursor + 3] & 64 != 0, valid >= pref, prefix[0] != 255,
          !(prefix[0] == 0xfe && prefix[1] & 0xc0 == 0x80), prefix.contains(where: { $0 != 0 })
        {
          guard offers.count < 64 else { return nil }
          offers.append(.init(prefix: prefix, valid: valid, preferred: pref))
        }
      }
      cursor += len
    }
    self.router = ip
    lifetime = word(b, 60)
    self.offers = offers
  }
}
public enum AddressUse: Equatable { case tentative, preferred, deprecated, duplicate }
/// Per-link IPv6 host state. Supply an assigned link-local address and an
/// opaque interface identifier; no identifier is derived from the NIC MAC.
/// All calls are serialized within one interface epoch, on monotonic seconds.
public struct RouterDiscovery {
  private struct Router {
    let ip: [UInt8]
    var until: UInt64
  }
  private struct Entry {
    let ip: [UInt8]
    var valid: UInt64, preferred: UInt64, probes: Int = 0, next: UInt64 = 0, duplicate = false
  }
  private let link: NeighborInterface, identifier: [UInt8], limit: Int, retries: Int,
    interval: UInt32
  private var entries: [Entry] = [], routers: [Router] = [], last: UInt64 = 0
  public init?(
    link: NeighborInterface, identifier: [UInt8], capacity: Int = 16, dadTransmits: Int = 1,
    retransmitSeconds: UInt32 = 1
  ) {
    guard linkLocal(link.address), identifier.count == 8, identifier.contains(where: { $0 != 0 }),
      (1...64).contains(capacity), (1...8).contains(dadTransmits),
      (1...60).contains(retransmitSeconds)
    else { return nil }
    self.link = link
    self.identifier = identifier
    limit = capacity
    retries = dadTransmits
    interval = retransmitSeconds
  }
  private mutating func age(_ now: UInt64) -> Bool {
    guard now >= last, now != .max else { return false }
    last = now
    entries.removeAll { $0.valid <= now }
    routers.removeAll { $0.until <= now }
    return true
  }
  /// The caller schedules router solicitations per RFC 4861 and rate-limits transmissions.
  public func routerSolicitation() -> [UInt8] {
    solicitation(
      mac: link.mac, source: link.address, destination: allRouters,
      body: [133, 0, 0, 0, 0, 0, 0, 0, 1, 1] + link.mac)
  }
  public mutating func receiveAdvertisement(
    _ bytes: [UInt8], at now: UInt64,
    allowRouter: ([UInt8], [UInt8]) -> Bool
  ) -> Bool {
    guard now >= last, let ra = Advertisement(bytes, link: link, allowRouter: allowRouter), age(now)
    else { return false }
    if let i = routers.firstIndex(where: { $0.ip == ra.router }) {
      if ra.lifetime == 0 {
        routers.remove(at: i)
      } else {
        routers[i].until = expiry(now, ra.lifetime)
      }
    } else if ra.lifetime > 0, routers.count < limit {
      routers.append(Router(ip: ra.router, until: expiry(now, ra.lifetime)))
    }
    for p in ra.offers {
      let ip = p.prefix + identifier
      if let i = entries.firstIndex(where: { $0.ip == ip }) {
        // RFC 4862 §5.5.3(e): an unauthenticated short lifetime cannot
        // shorten an existing address below its remaining time or two hours.
        let remaining = entries[i].valid - now
        if p.valid == UInt32.max || p.valid > 7200 || UInt64(p.valid) > remaining {
          entries[i].valid = expiry(now, p.valid)
        } else if remaining > 7200 {
          entries[i].valid = expiry(now, 7200)
        }
        entries[i].preferred = expiry(now, p.preferred)
      } else if p.valid > 0, entries.count < limit {
        entries.append(
          Entry(ip: ip, valid: expiry(now, p.valid), preferred: expiry(now, p.preferred)))
      }
    }
    return true
  }
  public mutating func defaultRouters(at now: UInt64) -> [[UInt8]] {
    guard age(now) else { return [] }
    return routers.map { $0.ip }
  }
  public mutating func addresses(at now: UInt64) -> [([UInt8], AddressUse)] {
    guard age(now) else { return [] }
    return entries.map { e in
      let use: AddressUse =
        e.duplicate
        ? .duplicate
        : e.probes < retries || now < e.next
          ? .tentative : now < e.preferred ? .preferred : .deprecated
      return (e.ip, use)
    }
  }
  /// Join the solicited-node group and enable receive BEFORE sending.
  /// Failure to send does not start the DAD timer. Link loss resets the epoch.
  public mutating func probeTentative(at now: UInt64, send: ([UInt8]) -> Bool) -> Bool {
    guard age(now), now <= UInt64.max - UInt64(interval),
      let i = entries.firstIndex(where: { !$0.duplicate && $0.probes < retries && now >= $0.next })
    else { return false }
    let target = entries[i].ip
    let frame = solicitation(
      mac: link.mac, source: unspecified, destination: solicited(target),
      body: [135, 0, 0, 0, 0, 0, 0, 0] + target)
    guard send(frame) else { return false }
    entries[i].probes += 1
    entries[i].next = now + UInt64(interval)
    return true
  }
  /// Feed only ingress from this link, excluding a locally looped copy of
  /// our own multicast send (the MAC alone cannot distinguish duplicates).
  public mutating func observeConflict(_ b: [UInt8], at now: UInt64) -> Bool {
    guard b.count >= 78, age(now), unicastMac(Array(b[6..<12])), b[54] == 135 || b[54] == 136,
      let opts = ndOptions(b, type: b[54]),
      let i = entries.firstIndex(where: {
        b[62..<78].elementsEqual($0.ip) && !$0.duplicate && ($0.probes < retries || now < $0.next)
      })
    else { return false }
    let dst = Array(b[38..<54])
    let source = Array(b[22..<38])
    if b[54] == 135 {
      guard source == unspecified, dst == solicited(entries[i].ip), opts.link == nil,
        b[..<6].elementsEqual(multicastMac(dst))
      else { return false }
    } else {
      guard validNextHop(source),
        (dst == allNodes && b[58] & 0x40 == 0 && b[..<6].elementsEqual(multicastMac(dst)))
          || (dst == entries[i].ip && b[..<6].elementsEqual(link.mac))
      else { return false }
    }
    entries[i].duplicate = true
    return true
  }
}
