import Foundation
import Metal
import MosaicMetal
import TVMM
import TvGpuGuest

struct CheckError: Error { let message: String }
func require<T>(_ v: T?, _ message: String) throws -> T {
  guard let v else { throw CheckError(message: message) }
  return v
}
func check(_ yes: Bool, _ message: String) throws { if !yes { throw CheckError(message: message) } }

// Local, grant-scoped service for one offscreen target allocated by the
// test. No external surface, user-selected file, or global lookup exists.
final class Offscreen: PresentHost {
  let binding: PresentBinding, driver: MetalSurfaceDevice, image: any MTLTexture
  var pinned = false, allowRead = false
  init(_ b: PresentBinding, _ driver: MetalSurfaceDevice, _ source: any MTLTexture) {
    binding = b
    self.driver = driver
    image = source
  }
  func monotonicNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  func resolve(_ b: PresentBinding, local: UInt64, surface: Bool) -> PresentResource? {
    guard b == binding, local == (surface ? 19 : 73) else { return nil }
    return PresentResource(
      binding: b, local: local, object: surface ? 1 : 2, width: 64, height: 48,
      bgra8: true, renderPresent: surface, readBlit: !surface)
  }
  func pin(target: PresentResource, source: PresentResource?) -> UInt64? {
    guard !pinned, target.object == 1, source == nil || source?.object == 2 else { return nil }
    pinned = true
    allowRead = source != nil
    return 1
  }
  func submit(_ command: MetalPresentCommand, lease: UInt64) -> PresentSubmission {
    guard pinned && lease == 1 else { return .notSubmitted }
    let result = driver.submit(bytes: command.bytes, by: binding.context) {
      self.allowRead && $0 == 73 ? self.image : nil
    }
    switch result {
    case .accepted: return .accepted
    case .notSubmitted: return .notSubmitted
    case .indeterminate: return .indeterminate
    }
  }
  func unpin(_ lease: UInt64) {
    precondition(pinned && lease == 1)
    pinned = false
    allowRead = false
  }
  func stopAndDrain(_ b: PresentBinding) -> Bool { !pinned && b == binding }
}

func run(guest: Bool) throws {
  let gpu = try require(MTLCreateSystemDefaultDevice(), "Metal device unavailable")
  let queue = try require(gpu.makeCommandQueue(), "Metal queue unavailable")
  let desc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: 64, height: 48, mipmapped: false)
  desc.usage = [.shaderRead, .renderTarget]
  desc.storageMode = .shared
  let target = try require(gpu.makeTexture(descriptor: desc), "target")
  let backbuffer = try require(gpu.makeTexture(descriptor: desc), "offscreen compositor output")
  let source = try require(gpu.makeTexture(descriptor: desc), "source")
  let region = MTLRegionMake2D(0, 0, 64, 48)
  let pattern = (0..<12288).map { UInt8(truncatingIfNeeded: $0 * 37) }
  pattern.withUnsafeBytes {
    source.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256)
  }
  let grant = try require(
    MosaicGrant(
      client: 5, compositor: 9, epoch: 7, surface: 19, width: 64, height: 48, chargedBytes: 12288),
    "grant")
  let device = try require(MetalSurfaceDevice(grant: grant, queue: queue, target: target), "driver")
  let binding = try require(PresentBinding(guest: 1, context: 5, epoch: 7), "binding")
  let host = Offscreen(binding, device, source)
  let vmm = try require(MetalPresentation(binding: binding, maxInFlight: 1, host: host), "channel")
  let console = GuestConsole()
  var lane = MetalPresentationLane(grant)
  var guestDeadline: UInt64 = 0
  if guest {
    try console.begin()
    let now = host.monotonicNow()
    guestDeadline = now + 10_000_000_000
    try console.reply(console.word(now) + console.word(guestDeadline))
  }
  for op in [MetalSurfaceOp.clear(0xff80_4020), .blit(73)] {
    let now = host.monotonicNow()
    let serial: UInt64
    let deadline: UInt64
    let wire: [UInt8]
    if guest {
      wire = try console.request()
      let c = try require(MetalSurfaceCommand(bytes: wire, grant: grant), "guest command")
      serial = c.serial
      deadline = c.deadline
      try check(
        c.operation == op && c.deadline == guestDeadline
          && c.serial == (op == .clear(0xff80_4020) ? 1 : 2), "unexpected guest request")
      try check(vmm.receive(wire) == .submitted, "TVMM refused guest submission")
    } else {
      let command = try require(
        lane.present(
          by: 5, epoch: 7, now: now, deadline: now + 5_000_000_000,
          operation: op, canRead: { $0 == 73 }
        ) { wire in
          switch vmm.receive(wire) {
          case .submitted: return .accepted
          case .rejected: return .notSubmitted
          case .failed: return .indeterminate
          }
        }, "TVMM→Metal submission")
      serial = command.serial
      deadline = command.deadline
      wire = command.bytes
    }
    try check(
      host.pinned && (guest || !lane.reusable)
        && device.release(by: 9, epoch: 7, serial: serial) == nil, "early release")
    var event: MosaicReceipt?
    while host.monotonicNow() < deadline && event == nil {
      event = device.poll()
      if event == nil { Thread.sleep(forTimeInterval: 0.001) }
    }
    let gpuEvent = try require(event, "GPU completion timeout")
    try check(gpuEvent.phase == .rendered, "GPU error")
    func forward(_ e: MosaicReceipt, _ p: PresentPhase) -> [UInt8]? {
      vmm.completed(epoch: e.epoch, serial: e.serial, surface: e.surface, phase: p)
    }
    let done = try require(forward(gpuEvent, .gpuCompleted), "TVMM GPU completion")
    try check(
      done == gpuEvent.bytes && (guest || (lane.complete(done) && !lane.reusable)) && host.pinned,
      "render receipt")
    var pixels = [UInt8](repeating: 0, count: pattern.count)
    pixels.withUnsafeMutableBytes {
      target.getBytes($0.baseAddress!, bytesPerRow: 256, from: region, mipmapLevel: 0)
    }
    let clear = op == .clear(0xff80_4020)
    let expected = clear ? (0..<pattern.count).map { [UInt8(32), 64, 128, 255][$0 % 4] } : pattern
    try check(pixels == expected, "GPU readback mismatch")
    if guest {
      try console.reply(done)
      try console.rendered()
    }
    let frame = try require(MetalSurfaceCommand(bytes: wire, grant: grant), "composition frame")
    let scene = try require(
      MosaicComposition.begin(
        by: grant.compositor, backbuffer: backbuffer, queue: queue,
        layers: [MosaicLayer(device: device, frame: frame, x: 0, y: 0)]), "composition")
    try check(
      device.release(by: grant.compositor, epoch: frame.epoch, serial: serial) == nil && host.pinned,
      "source must stay pinned until the compositor copy completes")
    var receipts: [MosaicReceipt]?
    while host.monotonicNow() < deadline && receipts == nil {
      receipts = scene.collect()
      if receipts == nil { Thread.sleep(forTimeInterval: 0.001) }
    }
    let ack = try require(receipts?.first, "compositor copy timeout")
    try check(receipts?.count == 1 && ack.phase == .released && scene.collect() == nil,
      "release must come once from the completed composition")
    var composed = [UInt8](repeating: 0, count: expected.count)
    composed.withUnsafeMutableBytes {
      backbuffer.getBytes($0.baseAddress!, bytesPerRow: 256, from: region, mipmapLevel: 0)
    }
    try check(composed == expected, "compositor output mismatch")
    let release = try require(forward(ack, .compositorReleased), "TVMM compositor completion")
    try check(
      release == ack.bytes && (guest || (lane.complete(release) && lane.reusable)) && !host.pinned,
      "release receipt")
    try check(vmm.receive(wire) == .rejected, "replay")
    if guest { try console.reply(release) }
    console.note(
      "\(clear ? "Clear" : "Blit") passed: \(pixels.count/4) pixels match on the guest surface and compositor output; GPU and compositor copy receipts match."
    )
  }
  try check(vmm.close(), "drain")
  if guest { try console.finish() }
  console.note(
    "Device: \(gpu.name). \(guest ? "QEMU debug guest and monitor relay" : "Hosted, no booted guest"); no physical scanout or W4/W11 acceptance."
  )
}

do { try run(guest: CommandLine.arguments.dropFirst().elementsEqual(["--guest-stdio"])) } catch {
  FileHandle.standardError.write(Data("NOT VERIFIED: \(error)\n".utf8))
  exit(1)
}
