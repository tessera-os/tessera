import KCore

// DTSpec v0.4 flattened format, version 17. All locations are offsets
// into one immutable, pinned blob, never physical or virtual pointers.
func big<S: ByteSource>(_ s: S, p: UInt64, n: UInt64) -> UInt64 {
  var i: UInt64 = 0
  var word: UInt64 = 0
  while i < n {
    word = (word << 8) | UInt64(s.byteAt(p + i))
    i += 1
  }
  return word
}

public struct FdtCursor {
  public internal(set) var next: UInt64
  public internal(set) var limit: UInt64
  public internal(set) var names: UInt64
  public internal(set) var namesEnd: UInt64
  public internal(set) var reserve: UInt64
  public internal(set) var reserveEnd: UInt64
  public internal(set) var depth: UInt64
  public internal(set) var began: Bool
  public internal(set) var properties: Bool
  public internal(set) var ended: Bool
  public internal(set) var failed: Bool
}

public func openTree<S: ByteSource>(_ s: S) -> FdtCursor {
  var c = FdtCursor(
    next: 0, limit: 0, names: 0, namesEnd: 0, reserve: 0, reserveEnd: 0, depth: 0, began: false,
    properties: false, ended: false, failed: true)
  if s.byteCount() < 40 || big(s, p: 0, n: 4) != 0xd00d_feed || big(s, p: 20, n: 4) != 17
    || big(s, p: 24, n: 4) != 16
  {
    return c
  }
  let total = big(s, p: 4, n: 4)
  let start = big(s, p: 8, n: 4)
  let names = big(s, p: 12, n: 4)
  let reserve = big(s, p: 16, n: 4)
  let nameSize = big(s, p: 32, n: 4)
  let structSize = big(s, p: 36, n: 4)
  if total > s.byteCount() || reserve < 40 || reserve % 8 != 0 || reserve > start || start % 4 != 0
    || structSize % 4 != 0 || start + structSize > names || names + nameSize > total
  {
    return c
  }
  var p = reserve
  while start - p >= 16 {
    let base = big(s, p: p, n: 8)
    let size = big(s, p: p + 8, n: 8)
    if base == 0 && size == 0 {
      c.reserve = reserve
      c.reserveEnd = p
      c.next = start
      c.limit = start + structSize
      c.names = names
      c.namesEnd = names + nameSize
      c.failed = false
      return c
    }
    if !validExtent(base, length: size) { return c }
    p += 16
  }
  return c
}

public struct FdtItem {
  public internal(set) var token: UInt32
  public internal(set) var nameAt: UInt64
  public internal(set) var nameLength: UInt64
  public internal(set) var valueAt: UInt64
  public internal(set) var valueLength: UInt64
}

func blankItem(_ t: UInt32) -> FdtItem {
  return FdtItem(token: t, nameAt: 0, nameLength: 0, valueAt: 0, valueLength: 0)
}

func failedItem(_ c: inout FdtCursor) -> FdtItem {
  c.failed = true
  return blankItem(0)
}

func nul<S: ByteSource>(_ s: S, p: UInt64, limit: UInt64) -> UInt64 {
  var i = p
  while i < limit && s.byteAt(i) != 0 { i += 1 }
  return i
}

// End nodes report their parent's depth in the updated cursor. Token 9
// completes exactly one tree, token 0 is failure; consume once to the end
// prior to using any discovered resource. No recursion or heap scratch.
public func nextItem<S: ByteSource>(_ s: S, c: inout FdtCursor) -> FdtItem {
  if c.failed || c.ended || c.next > c.limit || c.limit - c.next < 4 || c.namesEnd > s.byteCount() {
    return failedItem(&c)
  }
  let t = UInt32(big(s, p: c.next, n: 4))
  c.next += 4
  var item = blankItem(t)
  if t == 1 {
    let end = nul(s, p: c.next, limit: c.limit)
    if end == c.limit || (c.depth == 0 && (c.began || end != c.next))
      || (c.depth != 0 && end == c.next)
    {
      return failedItem(&c)
    }
    item.nameAt = c.next
    item.nameLength = end - c.next
    c.next = (end + 4) & UInt64(0xffff_ffff_ffff_fffc)
    c.began = true
    c.properties = true
    c.depth += 1
  } else if t == 2 {
    if c.depth == 0 { return failedItem(&c) }
    c.depth -= 1
    c.properties = false
  } else if t == 3 {
    if !c.properties || c.limit - c.next < 8 { return failedItem(&c) }
    let length = big(s, p: c.next, n: 4)
    let index = big(s, p: c.next + 4, n: 4)
    c.next += 8
    if length > c.limit - c.next || index >= c.namesEnd - c.names { return failedItem(&c) }
    let nameAt = c.names + index
    let end = nul(s, p: nameAt, limit: c.namesEnd)
    if end == c.namesEnd || end == nameAt { return failedItem(&c) }
    item.nameAt = nameAt
    item.nameLength = end - nameAt
    item.valueAt = c.next
    item.valueLength = length
    c.next = (c.next + length + 3) & UInt64(0xffff_ffff_ffff_fffc)
  } else if t == 9 {
    if !c.began || c.depth != 0 || c.next != c.limit { return failedItem(&c) }
    c.ended = true
  } else if t != 4 {
    return failedItem(&c)
  }
  return item
}

public protocol MemoryBankSink {
  mutating func bank(_ base: UInt64, length: UInt64) -> Bool
  mutating func reserve(_ base: UInt64, length: UInt64) -> Bool
}

/// Cursor immediately following the node's BEGIN_NODE token in an already
/// validated immutable tree. Reject duplicate or malformed direct properties.
func treeProperty<S: ByteSource>(_ tree: S, node: FdtCursor?, _ key: StaticString,
  optional: Bool = false, _ valid: (FdtItem) -> Bool) -> Bool
{
  guard var c = node else { return false }
  var seen = false
  while true {
    let x = nextItem(tree, c: &c)
    guard !c.failed else { return false }
    if x.token == 4 { continue }
    guard x.token == 3 else { return seen || optional }
    if matches(tree, at: x.nameAt, length: x.nameLength, key) {
      guard !seen, valid(x) else { return false }
      seen = true
    }
  }
}

func field<S: ByteSource>(_ s: S, p: UInt64, n: UInt64, size: UInt64, head: UInt64, tail: UInt64)
  -> Bool
{
  if n != size { return false }
  if n <= 8 { return big(s, p: p, n: n) == head }
  return big(s, p: p, n: 8) == head && big(s, p: p + 8, n: n - 8) == tail
}

func stageReg<S: ByteSource, B: MemoryBankSink>(
  _ s: S, sink: inout B, at: UInt64, length: UInt64, a: UInt64, z: UInt64, reserved: Bool
) -> Bool {
  if a < 1 || a > 2 || z < 1 || z > 2 { return false }
  let stride = 4 * (a + z)
  if length == 0 || length % stride != 0 { return false }
  var i: UInt64 = 0
  while i < length {
    let base = big(s, p: at + i, n: 4 * a)
    let size = big(s, p: at + i + 4 * a, n: 4 * z)
    if !validExtent(base, length: size) { return false }
    if reserved {
      if !sink.reserve(base, length: size) { return false }
    } else if !sink.bank(base, length: size) {
      return false
    }
    i += stride
  }
  return true
}

// Stage root physical banks, FDT reserve entries and static reserved-memory
// carveouts. Refuse enabled dynamic reservations (no boot allocator bound).
// The sink discards partial results on any failure; combine reservations
// with firmware, images and handoff extents before releasing any memory.
public func stageMemoryBanks<S: ByteSource, B: MemoryBankSink>(_ s: S, sink: inout B) -> Bool {
  var c = openTree(s)
  if c.failed { return false }
  var a: UInt64 = 2
  var z: UInt64 = 1
  var memory = false
  var enabled = false
  var regAt: UInt64 = 0
  var regSize: UInt64 = 0
  var rootFields: UInt8 = 0
  var nodeFields: UInt8 = 0
  var reservedParent = false
  var sawReserved = false
  var resFields: UInt8 = 0
  var childReg: UInt64 = 0
  var childSize: UInt64 = 0
  var childEnabled = false
  var childFields: UInt8 = 0
  while !c.ended {
    let item = nextItem(s, c: &c)
    if c.failed { return false }
    if item.token == 1 && c.depth == 2 {
      memory = false
      enabled = true
      regAt = 0
      regSize = 0
      nodeFields = 0
      reservedParent = field(
        s, p: item.nameAt, n: item.nameLength, size: 15, head: 0x7265_7365_7276_6564,
        tail: 0x2d_6d65_6d6f_7279)
      if reservedParent && sawReserved { return false }
      if reservedParent { sawReserved = true }
      resFields = 0
    }
    if item.token == 1 && c.depth == 3 && reservedParent {
      if enabled && resFields != 7 { return false }
      childReg = 0
      childSize = 0
      childEnabled = true
      childFields = 0
    }
    if item.token == 3 && c.depth == 1 {
      if field(
        s, p: item.nameAt, n: item.nameLength, size: 14, head: 0x2361_6464_7265_7373,
        tail: 0x2d63_656c_6c73)
      {  // #address-cells
        if (rootFields & 1) != 0 || item.valueLength != 4 { return false }
        a = big(s, p: item.valueAt, n: 4)
        rootFields = rootFields | 1
      } else if field(
        s, p: item.nameAt, n: item.nameLength, size: 11, head: 0x2373_697a_652d_6365, tail: 0x6c6c73
      ) {  // #size-cells
        if (rootFields & 2) != 0 || item.valueLength != 4 { return false }
        z = big(s, p: item.valueAt, n: 4)
        rootFields = rootFields | 2
      }
    }
    if item.token == 3 && c.depth == 2 {
      if reservedParent {
        if field(
          s, p: item.nameAt, n: item.nameLength, size: 14, head: 0x2361_6464_7265_7373,
          tail: 0x2d63_656c_6c73)
        {
          if (resFields & 1) != 0 || item.valueLength != 4 || big(s, p: item.valueAt, n: 4) != a {
            return false
          }
          resFields = resFields | 1
        } else if field(
          s, p: item.nameAt, n: item.nameLength, size: 11, head: 0x2373_697a_652d_6365,
          tail: 0x6c6c73)
        {
          if (resFields & 2) != 0 || item.valueLength != 4 || big(s, p: item.valueAt, n: 4) != z {
            return false
          }
          resFields = resFields | 2
        } else if field(
          s, p: item.nameAt, n: item.nameLength, size: 6, head: 0x7261_6e67_6573, tail: 0)
        {
          if (resFields & 4) != 0 || item.valueLength != 0 { return false }
          resFields = resFields | 4
        }
      }
      if field(
        s, p: item.nameAt, n: item.nameLength, size: 11, head: 0x6465_7669_6365_5f74, tail: 0x797065
      ) {  // device_type
        if (nodeFields & 1) != 0 { return false }
        nodeFields = nodeFields | 1
        memory = field(
          s, p: item.valueAt, n: item.valueLength, size: 7, head: 0x6d_656d_6f72_7900, tail: 0)
      } else if field(s, p: item.nameAt, n: item.nameLength, size: 3, head: 0x726567, tail: 0) {  // reg
        if (nodeFields & 2) != 0 { return false }
        nodeFields = nodeFields | 2
        regAt = item.valueAt
        regSize = item.valueLength
      } else if field(
        s, p: item.nameAt, n: item.nameLength, size: 6, head: 0x7374_6174_7573, tail: 0)
      {  // status
        if (nodeFields & 4) != 0 { return false }
        nodeFields = nodeFields | 4
        enabled = field(
          s, p: item.valueAt, n: item.valueLength, size: 5, head: 0x6f_6b61_7900, tail: 0)
      }
    }
    if item.token == 3 && c.depth == 3 && reservedParent {
      if field(s, p: item.nameAt, n: item.nameLength, size: 3, head: 0x726567, tail: 0) {
        if (childFields & 1) != 0 { return false }
        childFields = childFields | 1
        childReg = item.valueAt
        childSize = item.valueLength
      } else if field(
        s, p: item.nameAt, n: item.nameLength, size: 6, head: 0x7374_6174_7573, tail: 0)
      {
        if (childFields & 2) != 0 { return false }
        childFields = childFields | 2
        childEnabled = field(
          s, p: item.valueAt, n: item.valueLength, size: 5, head: 0x6f_6b61_7900, tail: 0)
      }
    }
    if item.token == 2 && c.depth == 2 && reservedParent && enabled && childEnabled {
      if !stageReg(s, sink: &sink, at: childReg, length: childSize, a: a, z: z, reserved: true) {
        return false
      }
    }
    if item.token == 2 && c.depth == 1 && memory && enabled {
      if reservedParent
        || !stageReg(s, sink: &sink, at: regAt, length: regSize, a: a, z: z, reserved: false)
      {
        return false
      }
    }
  }
  var p = c.reserve
  while p < c.reserveEnd {
    if !sink.reserve(big(s, p: p, n: 8), length: big(s, p: p + 8, n: 8)) { return false }
    p += 16
  }
  return true
}
