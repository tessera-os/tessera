public enum BalloonQueue { case inflate, deflate, report }

// Work only at the level of anonymous guest RAM. Backing providers batch under the VM
// map lock, exclude pinned DMA/queue pages, and restore zero-filled memory before reuse.
// Inflate/deflate PFNs always count 4096-byte units, even on a 16 KiB host.
public func balloonPages(
  _ command: [UInt8], _ ram: GuestAperture,
  _ queue: BalloonQueue, _ apply: (BalloonQueue, [UInt64]) -> Bool
) -> Bool {
  if queue == .report || command.count == 0 || command.count > 16384 || command.count % 4 != 0 {
    return false
  }
  var addresses: [UInt64] = []
  for i in 0..<(command.count / 4) {
    let page = vword(command, i * 4, 4) << 12
    if !containsSpan(ram, page, 4096) { return false }
    addresses.append(page)
  }
  return apply(queue, addresses)
}

public func reportFreePages(
  _ segments: [Segment], _ ram: GuestAperture,
  _ granule: UInt64, _ discard: ([Segment]) -> Bool
) -> Bool {
  if segments.count == 0 || segments.count > 32768 || granule < 4096
    || (granule & (granule - 1)) != 0
  {
    return false
  }
  for s in segments {
    if !s.writable || s.length == 0 || s.length % granule != 0 || s.address % granule != 0
      || !containsSpan(ram, s.address, s.length)
    {
      return false
    }
  }
  return discard(segments)
}
