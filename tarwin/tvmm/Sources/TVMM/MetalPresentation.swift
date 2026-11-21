/// Private copy of a guest request from a pre-bound ordered presentation
/// channel. This is not virtio-gpu, and none of these identifiers is an address.
public struct MetalPresentCommand {
  public let bytes: [UInt8]
  public let epoch, serial, surface, source, deadline: UInt64
  public let color, width, height: UInt32
  public var blit: Bool { source != 0 }
  public init?(_ bytes: [UInt8]) {
    guard bytes.count == 64, bytes.prefix(4).elementsEqual("TMS1".utf8),
      vword(bytes, 4, 2) == 1, vword(bytes, 60, 4) == 0
    else { return nil }
    let op = vword(bytes, 6, 2)
    epoch = vword(bytes, 8, 8)
    serial = vword(bytes, 16, 8)
    surface = vword(bytes, 24, 8)
    source = vword(bytes, 32, 8)
    deadline = vword(bytes, 40, 8)
    color = UInt32(vword(bytes, 48, 4))
    width = UInt32(vword(bytes, 52, 4))
    height = UInt32(vword(bytes, 56, 4))
    guard epoch != 0, serial != 0, surface != 0, deadline != 0,
      (1...16384).contains(width), (1...16384).contains(height),
      op == 1 && source == 0 || op == 2 && source != 0 && color == 0
    else { return nil }
    self.bytes = bytes
  }
  func completion(_ phase: PresentPhase) -> [UInt8] {
    var out = Array("TMC1".utf8)
    little(&out, 1, 2)
    little(&out, phase.rawValue, 2)
    little(&out, epoch, 8)
    little(&out, serial, 8)
    little(&out, surface, 8)
    return out
  }
}

public enum PresentPhase: UInt64 {
  case gpuCompleted = 1
  case compositorReleased, failed
}
public enum PresentResult: Equatable {
  case rejected, submitted
  case failed([UInt8])
}
public enum PresentSubmission {
  case notSubmitted, accepted, indeterminate
}
public struct PresentBinding: Equatable, Sendable {
  public let guest, context, epoch: UInt64
  public init?(guest: UInt64, context: UInt64, epoch: UInt64) {
    guard guest != 0, context != 0, epoch != 0 else { return nil }
    self.guest = guest
    self.context = context
    self.epoch = epoch
  }
}
public struct PresentResource {
  public let binding: PresentBinding
  public let local, object: UInt64
  public let width, height: UInt32
  public let bgra8, renderPresent, readBlit: Bool
  public init(
    binding: PresentBinding, local: UInt64, object: UInt64, width: UInt32, height: UInt32,
    bgra8: Bool, renderPresent: Bool, readBlit: Bool
  ) {
    self.binding = binding
    self.local = local
    self.object = object
    self.width = width
    self.height = height
    self.bgra8 = bgra8
    self.renderPresent = renderPresent
    self.readBlit = readBlit
  }
}

/// All methods and completion events run on one serial service loop, without
/// reentry. The registry atomically pins the exact resolved grants, verifies
/// they are still live, and excludes writers/readers of aliasing resources.
public protocol PresentHost: AnyObject {
  func monotonicNow() -> UInt64
  func resolve(_ binding: PresentBinding, local: UInt64, surface: Bool) -> PresentResource?
  func pin(target: PresentResource, source: PresentResource?) -> UInt64?
  // Only return notSubmitted when no work was ever queued. Device failures
  // and timeouts with unknown ownership are indeterminate.
  func submit(_ command: MetalPresentCommand, lease: UInt64) -> PresentSubmission
  func unpin(_ lease: UInt64)
  func stopAndDrain(_ binding: PresentBinding) -> Bool
}

public final class MetalPresentation {
  private struct Flight {
    let command: MetalPresentCommand
    let lease: UInt64
    var gpuDone = false
  }
  public let binding: PresentBinding
  private let host: any PresentHost
  private let limit: Int
  private var last: UInt64 = 0
  private var active = [UInt64: Flight]()
  private var closed = false
  private var drained = false

  public init?(binding: PresentBinding, maxInFlight: Int, host: any PresentHost) {
    guard (1...4096).contains(maxInFlight) else { return nil }
    self.binding = binding
    self.limit = maxInFlight
    self.host = host
  }

  public func receive(_ bytes: [UInt8]) -> PresentResult {
    guard !closed, active.count < limit, let c = MetalPresentCommand(bytes),
      c.epoch == binding.epoch, host.monotonicNow() < c.deadline,
      c.serial > last, active[c.surface] == nil
    else { return .rejected }
    func resource(_ local: UInt64, _ target: Bool) -> PresentResource? {
      guard let r = host.resolve(binding, local: local, surface: target), r.binding == binding,
        r.local == local, r.object != 0, r.width == c.width, r.height == c.height, r.bgra8,
        target ? r.renderPresent : r.readBlit
      else { return nil }
      return r
    }
    guard let target = resource(c.surface, true) else { return .rejected }
    var source: PresentResource?
    if c.blit {
      guard let image = resource(c.source, false), image.object != target.object else {
        return .rejected
      }
      source = image
    }
    guard let lease = host.pin(target: target, source: source), lease != 0 else { return .rejected }
    guard host.monotonicNow() < c.deadline else {
      host.unpin(lease)
      return .rejected
    }
    last = c.serial
    switch host.submit(c, lease: lease) {
    case .notSubmitted:
      host.unpin(lease)
      return .rejected
    case .accepted:
      active[c.surface] = Flight(command: c, lease: lease)
      return .submitted
    case .indeterminate:
      active[c.surface] = Flight(command: c, lease: lease)
      closed = true
      return .failed(c.completion(.failed))
    }
  }

  // Trusted GPU/compositor event, never a guest acknowledgement. Stale
  // callbacks cannot release a newer frame. A failed channel stays pinned.
  public func completed(epoch: UInt64, serial: UInt64, surface: UInt64, phase: PresentPhase)
    -> [UInt8]?
  {
    guard !closed, epoch == binding.epoch, var frame = active[surface],
      frame.command.serial == serial
    else { return nil }
    switch phase {
    case .gpuCompleted:
      guard !frame.gpuDone else { return nil }
      frame.gpuDone = true
      active[surface] = frame
    case .compositorReleased:
      guard frame.gpuDone else {
        closed = true
        return frame.command.completion(.failed)
      }
      active.removeValue(forKey: surface)
      host.unpin(frame.lease)
    case .failed: closed = true
    }
    return frame.command.completion(phase)
  }

  /// Also used on grant revocation and client death. The service retains
  /// quarantined channels and retries; it must never unpin on a drain timeout.
  public func close() -> Bool {
    closed = true
    if drained { return true }
    guard host.stopAndDrain(binding) else { return false }
    for frame in active.values { host.unpin(frame.lease) }
    active.removeAll()
    drained = true
    return true
  }
}
