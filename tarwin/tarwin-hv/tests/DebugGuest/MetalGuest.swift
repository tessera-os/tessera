// Optional test-only transport in private guest RAM. The wire encoder and
// completion state are the independent guest driver's Embedded Swift code.
@_silgen_name("guest_exchange") private func exchange(
  _ op: UInt64, _ mailbox: UnsafeMutableRawPointer)
func presentFrames(_ p: UnsafeMutableRawPointer) -> Bool {
  guard
    let grant = MosaicGrant(
      client: 5, compositor: 9, epoch: 7, surface: 19, width: 64,
      height: 48, chargedBytes: 12288)
  else { return false }
  var lane = MetalPresentationLane(grant)
  let request = UnsafeMutableRawBufferPointer(start: p, count: 64)
  let reply = UnsafeRawBufferPointer(start: p + 64, count: 32)
  exchange(0x4d10, p)
  let now = p.load(fromByteOffset: 64, as: UInt64.self)
  let deadline = p.load(fromByteOffset: 72, as: UInt64.self)
  for serial: UInt64 in 1...2 {
    let submitted = lane.present(
      by: 5, epoch: 7, now: now, deadline: deadline,
      operation: serial == 1 ? .clear(0xff80_4020) : .blit(73), into: request,
      canRead: { $0 == 73 },
      submit: { _ in
        exchange(0x4d11, p)
        return .accepted
      })
    guard submitted?.serial == serial, !lane.reusable, lane.complete(reply), !lane.reusable
    else { return false }
    exchange(0x4d12, p)
    guard lane.complete(reply), lane.reusable else { return false }
  }
  return true
}
