public struct TcpReceiveAck: Equatable {
  public let next: UInt32, window: UInt32, finished: Bool, sacks: [SackBlock]
  /// SACK option only; caller reserves room for other options and pads the final header.
  public func sackOption(available: Int) -> [UInt8] {
    guard available >= 10 else { return [] }
    let n = min(4, sacks.count, (min(available, 40) - 2) / 8)
    guard n > 0 else { return [] }
    var out: [UInt8] = [5, UInt8(2 + 8 * n)]
    for block in sacks.prefix(n) {
      for v in [block.left, block.right] {
        for shift in [24, 16, 8, 0] { out.append(UInt8(truncatingIfNeeded: v >> shift)) }
      }
    }
    return out
  }
}
/// Receive half of one established connection. The connection owner does
/// tuple/policy demux, ACK validation, control flags and PAWS before admission.
/// Storage is bounded at setup. Every byte is retained until the reader takes it.
public struct TcpReceiveWindow: ~Copyable {
  private var base: UInt32, head: Int = 0, ready: Int = 0, fin: Int?, bytes: [UInt8],
    spans: [Range<Int>] = []
  private let limit: Int, sack: Bool
  public init?(next: UInt32, capacity: Int, maxGaps: Int = 16, sackNegotiated: Bool) {
    guard (1...1_048_576).contains(capacity), (1...32).contains(maxGaps) else { return nil }
    base = next
    limit = maxGaps
    sack = sackNegotiated
    bytes = Array(repeating: 0, count: capacity)
    spans.reserveCapacity(limit)
  }
  public var acknowledgement: TcpReceiveAck {
    let closed = fin == ready
    return TcpReceiveAck(
      next: base &+ UInt32(ready) &+ (closed ? 1 : 0),
      window: closed ? 0 : UInt32(bytes.count - ready), finished: closed,
      sacks: sack
        ? spans.prefix(4).compactMap {
          SackBlock(left: base &+ UInt32($0.lowerBound), right: base &+ UInt32($0.upperBound))
        } : [])
  }
  public var readable: Int { ready }
  var capacity: Int { bytes.count }
  var finished: Bool { fin == ready }
  func peek(upTo: Int, copy: (ArraySlice<UInt8>) -> Void) -> Int {
    let n = max(0, min(upTo, ready))
    let first = min(n, bytes.count - head)
    if first > 0 { copy(bytes[head..<head + first]) }
    if first < n { copy(bytes[0..<n - first]) }
    return n
  }
  public var atEnd: Bool { ready == 0 && fin == 0 }

  /// False means control/policy processing owns this packet. An admitted
  /// duplicate or out-of-window packet changes no bytes; send the current ACK.
  @discardableResult public mutating func receive(_ packet: TcpSegment, admit: (TcpSegment) -> Bool)
    -> Bool
  {
    // Require ACK, and route urgent data, resets and handshakes to the owner.
    guard packet.flags & 0x36 == 0x10, admit(packet) else { return false }
    guard fin != ready else { return true }
    let start = Int(Int32(bitPattern: packet.sequence &- base))
    let end = start + packet.payload.count
    let lo = max(ready, start)
    let hi = min(fin ?? bytes.count, end)
    if lo < hi {
      let touching = spans.filter { $0.lowerBound <= hi && $0.upperBound >= lo }.sorted {
        $0.lowerBound < $1.lowerBound
      }
      let merged =
        min(lo, touching.first?.lowerBound ?? lo)..<max(hi, touching.last?.upperBound ?? hi)
      // Do not ACK or advertise disjoint bytes we cannot retain.
      if lo > ready && touching.isEmpty && spans.count >= limit { return true }
      func store(_ a: Int, _ b: Int, _ storage: inout [UInt8], _ cursor: Int) {
        for i in a..<b {
          storage[(cursor + i) % storage.count] =
            packet.payload[packet.payload.startIndex + i - start]
        }
      }
      var cursor = lo
      for r in touching {
        let upto = min(r.lowerBound, hi)
        if cursor < upto { store(cursor, upto, &bytes, head) }
        cursor = max(cursor, r.upperBound)
      }
      if cursor < hi { store(cursor, hi, &bytes, head) }
      spans.removeAll { $0.lowerBound <= hi && $0.upperBound >= lo }
      if merged.lowerBound == ready {
        ready = merged.upperBound
      } else {
        spans.insert(merged, at: 0)
      }
    }
    // FIN occupies one sequence position and must itself be in the window.
    // Never retract already acknowledged or retained stream data.
    if packet.flags & 1 != 0, fin == nil, end >= ready, end < bytes.count,
      !spans.contains(where: { $0.upperBound > end })
    {
      fin = end
    }
    return true
  }

  /// Advances the advertised right edge only by bytes actually accepted.
  /// Provide a pinned destination; if the second span fails, the first
  /// accepted span remains consumed and must not be copied a second time.
  public mutating func read(upTo: Int, copy: (ArraySlice<UInt8>) -> Bool) -> Int {
    var left = min(upTo, ready)
    var done = 0
    while left > 0 {
      let n = min(left, bytes.count - head)
      guard copy(bytes[head..<head + n]) else { break }
      head = (head + n) % bytes.count
      base = base &+ UInt32(n)
      ready -= n
      if let f = fin { fin = f - n }
      for i in spans.indices { spans[i] = (spans[i].lowerBound - n)..<(spans[i].upperBound - n) }
      left -= n
      done += n
    }
    return done
  }
}
