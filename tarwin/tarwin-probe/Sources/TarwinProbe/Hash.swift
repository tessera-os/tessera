public enum HashState { case empty, present, removed }
public struct HashEntry {
  public let state: HashState
  public let key: UInt64
  public let value: UInt64

  public init(state: HashState, key: UInt64, value: UInt64) {
    self.state = state
    self.key = key
    self.value = value
  }
}
public enum HashOp { case lookup, insert, erase }
public enum HashStatus { case found, inserted, removed, absent, full }
public struct HashReply {
  public let status: HashStatus
  public let value: UInt64

  public init(status: HashStatus, value: UInt64) {
    self.status = status
    self.value = value
  }
}

// A bounded 64-bit key/value map helper. The kernel map lock, keyed hash and
// fixed storage are supplied when the map object is created; no probe callback
// chooses them. Limit collision probes per call as well as total allocation.
public func hashOperation(
  _ capacity: UInt64, _ key: UInt64, _ value: UInt64, _ hash: UInt64, _ op: HashOp,
  _ get: (UInt64) -> HashEntry, _ put: (UInt64, HashEntry) -> Void
) -> HashReply {
  if capacity == 0 || capacity > ProbeLimit.entries || (capacity & (capacity - 1)) != 0 {
    return HashReply(status: .full, value: 0)
  }
  let limit = capacity < 64 ? capacity : UInt64(64)
  var free = capacity
  var index = hash & (capacity - 1)
  var n: UInt64 = 0
  while n < limit {
    let item = get(index)
    if item.state == .present && item.key == key {
      if op == .erase {
        put(index, HashEntry(state: .removed, key: 0, value: 0))
        return HashReply(status: .removed, value: item.value)
      }
      if op == .insert { put(index, HashEntry(state: .present, key: key, value: value)) }
      return HashReply(status: .found, value: item.value)
    }
    if item.state != .present && free == capacity { free = index }
    if item.state == .empty { break }
    index = (index + 1) & (capacity - 1)
    n += 1
  }
  if op != .insert { return HashReply(status: .absent, value: 0) }
  if free == capacity { return HashReply(status: .full, value: 0) }
  put(free, HashEntry(state: .present, key: key, value: value))
  return HashReply(status: .inserted, value: 0)
}
