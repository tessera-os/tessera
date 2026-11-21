/// Trusted DeviceKit/Mosaic registration; a wire ID is not authority.
public struct MosaicGrant: Equatable, Sendable {
  public let client, compositor, epoch, surface: UInt64
  public let width, height: UInt32
  public init?(
    client: UInt64, compositor: UInt64, epoch: UInt64, surface: UInt64,
    width: UInt32, height: UInt32, chargedBytes: UInt64
  ) {
    guard client != 0, compositor != 0, epoch != 0, surface != 0,
      width > 0, height > 0, width <= 16384, height <= 16384,
      UInt64(width) * UInt64(height) * 4 <= chargedBytes
    else { return nil }
    self.client = client
    self.compositor = compositor
    self.epoch = epoch
    self.surface = surface
    self.width = width
    self.height = height
  }
}

public enum MetalSurfaceOp: Equatable, Sendable {
  /// Little-endian BGRA8 (B in bits 0…7), linear unorm.
  case clear(UInt32)
  /// Already retained read grant on this context. No host pointer or GPU VA.
  case blit(UInt64)
}

private func putWord(
  _ n: UInt64, _ size: Int, at offset: Int, in bytes: UnsafeMutableRawBufferPointer
) {
  for i in 0..<size { bytes[offset + i] = UInt8(truncatingIfNeeded: n >> (8 * i)) }
}

private func getWord(_ b: UnsafeRawBufferPointer, _ at: Int, _ width: Int) -> UInt64 {
  var v: UInt64 = 0
  for i in 0..<width { v |= UInt64(b[at + i]) << (8 * i) }
  return v
}

public struct MetalSurfaceCommand: Equatable, Sendable {
  public let epoch, serial, surface, deadline: UInt64
  public let width, height: UInt32
  public let operation: MetalSurfaceOp
  fileprivate init(_ g: MosaicGrant, _ serial: UInt64, _ deadline: UInt64, _ op: MetalSurfaceOp) {
    epoch = g.epoch
    surface = g.surface
    width = g.width
    height = g.height
    self.serial = serial
    self.deadline = deadline
    operation = op
  }

  #if !hasFeature(Embedded)
    public var bytes: [UInt8] {
      var b = [UInt8](repeating: 0, count: 64)
      _ = b.withUnsafeMutableBytes { encode(into: $0) }
      return b
    }
    public init?(bytes b: [UInt8], grant g: MosaicGrant) {
      guard let value = b.withUnsafeBytes({ Self(buffer: $0, grant: g) }) else { return nil }
      self = value
    }
  #endif
  @discardableResult public func encode(into b: UnsafeMutableRawBufferPointer) -> Bool {
    guard b.count == 64 else { return false }
    b.initializeMemory(as: UInt8.self, repeating: 0)
    putWord(0x3153_4d54, 4, at: 0, in: b)
    putWord(1, 2, at: 4, in: b)
    switch operation {
    case .clear(let c):
      putWord(1, 2, at: 6, in: b)
      putWord(UInt64(c), 4, at: 48, in: b)
    case .blit(let image):
      putWord(2, 2, at: 6, in: b)
      putWord(image, 8, at: 32, in: b)
    }
    putWord(epoch, 8, at: 8, in: b)
    putWord(serial, 8, at: 16, in: b)
    putWord(surface, 8, at: 24, in: b)
    putWord(deadline, 8, at: 40, in: b)
    putWord(UInt64(width), 4, at: 52, in: b)
    putWord(UInt64(height), 4, at: 56, in: b)
    return true
  }
  /// g is the receiving context's retained grant, not parsed from b.
  public init?(buffer b: UnsafeRawBufferPointer, grant g: MosaicGrant) {
    guard b.count == 64, getWord(b, 0, 4) == 0x3153_4d54, getWord(b, 4, 2) == 1,
      getWord(b, 8, 8) == g.epoch, getWord(b, 24, 8) == g.surface, getWord(b, 52, 4) == g.width,
      getWord(b, 56, 4) == g.height, getWord(b, 60, 4) == 0, getWord(b, 16, 8) != 0,
      getWord(b, 40, 8) != 0
    else { return nil }
    let image = getWord(b, 32, 8)
    let color = UInt32(getWord(b, 48, 4))
    let op: MetalSurfaceOp
    switch getWord(b, 6, 2) {
    case 1 where image == 0: op = .clear(color)
    case 2 where image != 0 && color == 0: op = .blit(image)
    default: return nil
    }
    self.init(g, getWord(b, 16, 8), getWord(b, 40, 8), op)
  }
}

public enum MosaicPhase: UInt16, Sendable {
  case rendered = 1
  case released = 2
  case failed = 3
}
public struct MosaicReceipt: Equatable, Sendable {
  public let phase: MosaicPhase
  public let epoch, serial, surface: UInt64
  public init(_ phase: MosaicPhase, command: MetalSurfaceCommand) {
    self.phase = phase
    epoch = command.epoch
    serial = command.serial
    surface = command.surface
  }
  #if !hasFeature(Embedded)
    public var bytes: [UInt8] {
      var b = [UInt8](repeating: 0, count: 32)
      _ = b.withUnsafeMutableBytes { encode(into: $0) }
      return b
    }
    public init?(bytes b: [UInt8]) {
      guard let value = b.withUnsafeBytes({ Self(buffer: $0) }) else { return nil }
      self = value
    }
  #endif
  @discardableResult public func encode(into b: UnsafeMutableRawBufferPointer) -> Bool {
    guard b.count == 32 else { return false }
    b.initializeMemory(as: UInt8.self, repeating: 0)
    putWord(0x3143_4d54, 4, at: 0, in: b)
    putWord(1, 2, at: 4, in: b)
    putWord(UInt64(phase.rawValue), 2, at: 6, in: b)
    putWord(epoch, 8, at: 8, in: b)
    putWord(serial, 8, at: 16, in: b)
    putWord(surface, 8, at: 24, in: b)
    return true
  }
  public init?(buffer b: UnsafeRawBufferPointer) {
    guard b.count == 32, getWord(b, 0, 4) == 0x3143_4d54, getWord(b, 4, 2) == 1,
      let p = MosaicPhase(rawValue: UInt16(getWord(b, 6, 2)))
    else { return nil }
    phase = p
    epoch = getWord(b, 8, 8)
    serial = getWord(b, 16, 8)
    surface = getWord(b, 24, 8)
    guard epoch != 0 && serial != 0 && surface != 0 else { return nil }
  }
}

public enum MosaicSubmission { case accepted, notSubmitted, indeterminate }
/// One guest-driver lane; never copy sequence numbers or mutable ownership.
/// Serialize channel completions and slot revocation. The kernel binds caller,
/// deadline and source access from retained handles before entering the lane.
public struct MetalPresentationLane: ~Copyable {
  private let grant: MosaicGrant
  private var issued: UInt64 = 0, current: MetalSurfaceCommand?, rendered = false, retired = false
  public var reusable: Bool { !retired && current == nil }
  public init(_ g: MosaicGrant) { grant = g }

  #if !hasFeature(Embedded)
    public mutating func present(
      by client: UInt64, epoch: UInt64, now: UInt64, deadline: UInt64,
      operation: MetalSurfaceOp, canRead: (UInt64) -> Bool,
      submit: ([UInt8]) -> MosaicSubmission
    ) -> MetalSurfaceCommand? {
      var b = [UInt8](repeating: 0, count: 64)
      return b.withUnsafeMutableBytes { storage in
        present(
          by: client, epoch: epoch, now: now, deadline: deadline, operation: operation,
          into: storage, canRead: canRead
        ) { submit(Array($0)) }
      }
    }
    public mutating func complete(_ b: [UInt8]) -> Bool {
      b.withUnsafeBytes { complete($0) }
    }
  #endif

  /// On acceptance the transport has copied the command; it must not retain the pointer.
  public mutating func present(
    by client: UInt64, epoch: UInt64, now: UInt64, deadline: UInt64,
    operation: MetalSurfaceOp, into buffer: UnsafeMutableRawBufferPointer,
    canRead: (UInt64) -> Bool, submit: (UnsafeRawBufferPointer) -> MosaicSubmission
  ) -> MetalSurfaceCommand? {
    guard reusable, client == grant.client, epoch == grant.epoch, now < deadline, issued != .max,
      buffer.count == 64
    else { return nil }
    if case .blit(let image) = operation, image == 0 || !canRead(image) { return nil }
    issued += 1
    let c = MetalSurfaceCommand(grant, issued, deadline, operation)
    guard c.encode(into: buffer) else { return nil }
    switch submit(.init(buffer)) {
    case .notSubmitted: return nil
    case .indeterminate:
      retired = true
      current = c
      return nil
    case .accepted:
      current = c
      rendered = false
      return c
    }
  }
  /// Only the bound authenticated completion channel may call this method.
  public mutating func complete(_ b: UnsafeRawBufferPointer) -> Bool {
    guard !retired, let c = current, let r = MosaicReceipt(buffer: b),
      r.epoch == c.epoch, r.serial == c.serial, r.surface == c.surface
    else { return false }
    switch r.phase {
    case .rendered where !rendered: rendered = true
    case .released where rendered:
      current = nil
      rendered = false
    case .failed: retired = true
    default: return false
    }
    return true
  }
  /// Teardown owns any referenced resources until both GPU and scanout drain.
  public mutating func revoke() { retired = true }
}
