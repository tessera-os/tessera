import Testing

@testable import TVMM

private func bytes(_ s: String) -> [UInt8] {
  let chars = Array(s.utf8)
  return stride(from: 0, to: chars.count, by: 2).map {
    UInt8(String(decoding: chars[$0..<$0 + 2], as: UTF8.self), radix: 16)!
  }
}
// Independent vectors from the guest transport owner.
private let clear = bytes(
  "544d533101000100070000000000000001000000000000001300000000000000000000000000000015cd5b0700000000204080ff400000003000000000000000"
)
private let blit = bytes(
  "544d533101000200070000000000000002000000000000001300000000000000490000000000000015cd5b070000000000000000400000003000000000000000"
)
private let binding = PresentBinding(guest: 1, context: 2, epoch: 7)!

private final class Host: PresentHost {
  var now: UInt64 = 0
  func monotonicNow() -> UInt64 { now }
  var guest: UInt64 = 1, ctx: UInt64 = 2, epoch: UInt64 = 7, w: UInt32 = 64
  var render = true, read = true, format = true, alias = false, drainOK = true
  var submitResult = PresentSubmission.accepted, advanceClockOnPin = false
  var submissions = [MetalPresentCommand](), pins = [UInt64](), unpins = [UInt64]()
  func resolve(_ b: PresentBinding, local: UInt64, surface: Bool) -> PresentResource? {
    guard b == binding, local == (surface ? 19 : 73) else { return nil }
    return PresentResource(
      binding: PresentBinding(guest: guest, context: ctx, epoch: epoch)!, local: local,
      object: (surface || alias ? 120 : 340), width: w, height: 48, bgra8: format,
      renderPresent: render, readBlit: read)
  }
  func pin(target: PresentResource, source: PresentResource?) -> UInt64? {
    let lease = UInt64(pins.count + 1)
    pins.append(lease)
    if advanceClockOnPin { now = UInt64.max }
    return lease
  }
  func submit(_ c: MetalPresentCommand, lease: UInt64) -> PresentSubmission {
    submissions.append(c)
    return submitResult
  }
  func unpin(_ lease: UInt64) { unpins.append(lease) }
  func stopAndDrain(_ b: PresentBinding) -> Bool { b == binding && drainOK }
}

@Test func crossOwnerMetalVectorsAndOrderedRelease() throws {
  let host = Host()
  let loop = try #require(MetalPresentation(binding: binding, maxInFlight: 2, host: host))
  #expect(loop.receive(clear) == .submitted)
  let decoded = try #require(host.submissions.first)
  #expect(decoded.color == 0xff80_4020 && decoded.deadline == 123_456_789 && !decoded.blit)
  #expect(loop.receive(blit) == .rejected)
  #expect(loop.completed(epoch: 6, serial: 1, surface: 19, phase: .gpuCompleted) == nil)
  #expect(
    loop.completed(epoch: 7, serial: 1, surface: 19, phase: .gpuCompleted)
      == bytes("544d433101000100070000000000000001000000000000001300000000000000"))
  #expect(loop.receive(blit) == .rejected && host.unpins.isEmpty)
  #expect(
    loop.completed(epoch: 7, serial: 1, surface: 19, phase: .compositorReleased)
      == bytes("544d433101000200070000000000000001000000000000001300000000000000"))
  #expect(loop.receive(clear) == .rejected)
  #expect(loop.receive(blit) == .submitted && host.submissions.last?.source == 73)
  #expect(loop.completed(epoch: 7, serial: 1, surface: 19, phase: .compositorReleased) == nil)
  #expect(host.unpins == [1])
  #expect(loop.close() && loop.close() && host.unpins == [1, 2])
}

@Test func malformedOrUnauthorizedMetalRequestsNeverReachQueue() throws {
  let host = Host()
  let loop = try #require(MetalPresentation(binding: binding, maxInFlight: 1, host: host))
  host.now = 123_456_789
  #expect(loop.receive(clear) == .rejected)
  host.now = 0
  for (idx, b): (Int, UInt8) in [
    (0, 0), (4, 2), (6, 3), (8, 8), (16, 0), (24, 0), (32, 1), (52, 65), (56, 0), (60, 1),
  ] {
    var bad = clear
    bad[idx] = b
    #expect(loop.receive(bad) == .rejected)
  }
  host.guest = 2
  #expect(loop.receive(clear) == .rejected)
  host.guest = 1
  host.ctx = 3
  #expect(loop.receive(clear) == .rejected)
  host.ctx = 2
  host.epoch = 8
  #expect(loop.receive(clear) == .rejected)
  host.epoch = 7
  host.render = false
  #expect(loop.receive(clear) == .rejected)
  host.render = true
  host.format = false
  #expect(loop.receive(clear) == .rejected)
  host.format = true
  host.read = false
  #expect(loop.receive(blit) == .rejected)
  host.read = true
  host.alias = true
  #expect(loop.receive(blit) == .rejected)
  #expect(host.pins.isEmpty && host.submissions.isEmpty)
}

@Test func deadlineDuringPinAndDefiniteRefusalNeedNoDrain() throws {
  let host = Host()
  let loop = try #require(MetalPresentation(binding: binding, maxInFlight: 1, host: host))
  host.advanceClockOnPin = true
  #expect(loop.receive(clear) == .rejected && host.submissions.isEmpty && host.unpins == [1])
  host.advanceClockOnPin = false
  host.now = 0
  host.submitResult = .notSubmitted
  #expect(loop.receive(clear) == .rejected && host.submissions.count == 1 && host.unpins == [1, 2])
  host.submitResult = .accepted
  #expect(loop.receive(blit) == .submitted)
}

@Test func uncertainSubmitAndOutOfOrderReleaseBothQuarantine() throws {
  for accepted in [true, false] {
    let host = Host()
    let loop = try #require(MetalPresentation(binding: binding, maxInFlight: 1, host: host))
    host.submitResult = accepted ? .accepted : .indeterminate
    let failed = bytes("544d433101000300070000000000000001000000000000001300000000000000")
    let result = loop.receive(clear)
    if accepted {
      #expect(
        result == .submitted
          && loop.completed(epoch: 7, serial: 1, surface: 19, phase: .compositorReleased) == failed)
    } else {
      #expect(result == .failed(failed))
    }
    #expect(loop.receive(blit) == .rejected)
    host.drainOK = false
    #expect(!loop.close() && host.unpins.isEmpty)
    host.drainOK = true
    #expect(loop.close() && host.unpins == [1])
  }
}
