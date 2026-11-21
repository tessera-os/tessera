// Decode an already stopped thread's frame chain. The architecture sampler
// supplies its frame layout, strips architecture-specific pointer metadata,
// and translates shadow entries. All three readers refer to the same thread.
public struct StackBounds {
  public let low: UInt64
  public let high: UInt64

  public init(low: UInt64, high: UInt64) {
    self.low = low
    self.high = high
  }
}
public struct FrameLayout {
  public let previous: UInt64
  public let link: UInt64

  public init(previous: UInt64, link: UInt64) {
    self.previous = previous
    self.link = link
  }
}
public func sampleChain(
  _ first: UInt64, _ bounds: StackBounds, _ layout: FrameLayout,
  _ limit: UInt64, _ read: (UInt64) -> UInt64, _ executable: (UInt64) -> Bool,
  _ shadow: (UInt64) -> UInt64, _ emit: (UInt64) -> Void
) -> UInt64 {
  if bounds.low >= bounds.high || bounds.high - bounds.low < 8 || layout.previous % 8 != 0
    || layout.link % 8 != 0 || layout.previous == layout.link || limit > 256
  {
    return 0
  }
  var fp = first
  var depth: UInt64 = 0
  while depth < limit {
    if fp % 8 != 0 || fp < bounds.low || fp > bounds.high - 8
      || layout.previous > bounds.high - 8 - fp || layout.link > bounds.high - 8 - fp
    {
      break
    }
    let pc = read(fp + layout.link)
    if pc == 0 || !executable(pc) || shadow(depth) != pc { break }
    emit(pc)
    depth += 1
    let next = read(fp + layout.previous)
    if next <= fp { break }
    fp = next
  }
  return depth
}
