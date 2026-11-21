// Virtio 1.3 §2.7: little-endian split descriptor table snapshotted from a single VM.
// The caller pins each returned span in that VM's memory objects before submitting I/O.
public struct GuestAperture {
  public let base: UInt64
  public let length: UInt64

  public init(base: UInt64, length: UInt64) {
    self.base = base
    self.length = length
  }
}
public struct Segment {
  public let address: UInt64
  public let length: UInt64
  public let writable: Bool

  public init(address: UInt64, length: UInt64, writable: Bool) {
    self.address = address
    self.length = length
    self.writable = writable
  }
}
public enum QueueError: Error {
  case invalidQueue, invalidDescriptor, invalidAddress, direction, invalidChain
}

func vword(_ bytes: [UInt8], _ at: Int, _ width: Int) -> UInt64 {
  var value: UInt64 = 0
  for i in 0..<width { value = value | (UInt64(bytes[at + i]) << UInt64(i * 8)) }
  return value
}

func containsSpan(_ ram: GuestAperture, _ address: UInt64, _ size: UInt64) -> Bool {
  if address < ram.base { return false }
  let offset = address - ram.base
  return offset <= ram.length && size <= ram.length - offset
    && (size == 0 || size - 1 <= 0xffff_ffff_ffff_ffff - address)
}

public func descriptorChain(
  _ table: [UInt8], _ slots: Int, _ head: Int,
  _ ram: GuestAperture
) -> Result<[Segment], QueueError> {
  if slots < 1 || slots > 32768 || (Int(slots) & (Int(slots) - 1)) != 0
    || table.count != slots * 16
  {
    return .failure(.invalidQueue)
  }
  var index = head
  var chain: [Segment] = []
  var writableSeen = false
  for hop in 0..<slots {
    if index < 0 || index >= slots { return .failure(.invalidDescriptor) }
    let p = index * 16
    let address = vword(table, p, 8)
    let size = vword(table, p + 8, 4)
    let flags = vword(table, p + 12, 2)
    // No indirect or packed descriptors are advertised by this transport.
    if flags > 3 { return .failure(.invalidDescriptor) }
    if !containsSpan(ram, address, size) { return .failure(.invalidAddress) }
    let writable = (flags & 2) != 0
    if writableSeen && !writable { return .failure(.direction) }
    writableSeen = writable
    chain.append(Segment(address: address, length: size, writable: writable))
    if (flags & 1) == 0 { return .success(chain) }
    index = Int(vword(table, p + 14, 2))
  }
  return .failure(.invalidChain)
}

// Queue event suppression across wrapping 16-bit available/used indices (§2.7.7).
public func needEvent(_ event: UInt64, _ next: UInt64, _ previous: UInt64) -> Bool {
  let distance = (65536 + (next & 65535) - (previous & 65535)) & 65535
  let past = (131071 + (next & 65535) - (event & 65535)) & 65535
  return past < distance
}
