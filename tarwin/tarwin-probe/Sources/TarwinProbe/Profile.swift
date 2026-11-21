// §27 conservative cost algebra over compiler-verified structured TIR. Zero
// is a valid empty block; values above limit poison the enclosing expression.
public enum ProbeLimit {
  public static let instructions: UInt64 = 1_000_000
  public static let invalid: UInt64 = 1_000_001
  public static let entries: UInt64 = 16_777_216
}
public func sequentialCost(_ a: UInt64, _ b: UInt64) -> UInt64 {
  if a > ProbeLimit.instructions || b > ProbeLimit.instructions - a { return ProbeLimit.invalid }
  return a + b
}
public func branchCost(_ yes: UInt64, _ no: UInt64) -> UInt64 {
  return sequentialCost(1, yes > no ? yes : no)
}
public func loopCost(_ body: UInt64, _ provenBound: UInt64) -> UInt64 {
  let iteration = sequentialCost(body, 1)
  if iteration > ProbeLimit.instructions || provenBound > (ProbeLimit.instructions - 1) / iteration
  {
    return ProbeLimit.invalid
  }
  return 1 + iteration * provenBound
}
public enum ProbeHook {
  case tracepoint, entry, exit, scheduler, sysEnter, sysExit, block, fileEvent, packet, endpoint,
    audit
}
public enum ProbeEffect { case readContext, mapAccess, ringWrite, pass, drop, redirect, mark }
public func effectAllowed(_ hook: ProbeHook, _ action: ProbeEffect) -> Bool {
  if action == .readContext { return true }
  if hook == .packet {
    return action == .pass || action == .drop || action == .redirect || action == .mark
  }
  if hook == .endpoint { return action == .pass || action == .drop }
  return action == .mapAccess || action == .ringWrite
}
public enum ProbeMapKind { case arrayMap, hashTable, perCpu, ring }
public struct ProbeMapShape {
  public let kind: ProbeMapKind
  public let capacity: UInt64
  public let elementSize: UInt64

  public init(kind: ProbeMapKind, capacity: UInt64, elementSize: UInt64) {
    self.kind = kind
    self.capacity = capacity
    self.elementSize = elementSize
  }
}
public func validMap(_ shape: ProbeMapShape, _ cpus: UInt64, _ byteQuota: UInt64) -> Bool {
  if shape.capacity == 0 || shape.capacity > ProbeLimit.entries || shape.elementSize == 0 {
    return false
  }
  let copies = shape.kind == .perCpu ? cpus : UInt64(1)
  return copies != 0 && copies <= 4096 && shape.elementSize <= byteQuota / copies / shape.capacity
}

// A declared map is an already resolved immutable kernel object, never an unchecked probe address.
public func mapOffset(
  _ shape: ProbeMapShape, _ cpu: UInt64, _ cpus: UInt64, _ index: UInt64,
  _ byteQuota: UInt64
) -> UInt64 {
  if !validMap(shape, cpus, byteQuota) || index >= shape.capacity || cpu >= cpus
    || (shape.kind != .perCpu && cpu != 0)
  {
    return 0xffff_ffff_ffff_ffff
  }
  return (cpu * shape.capacity + index) * shape.elementSize
}

public struct ProbeAttachment {
  public internal(set) var image: UInt64 = 0
  public internal(set) var hookToken: UInt64 = 0

  public init() {}

  // The verifier callback authenticates the immutable image, device key/probe role,
  // train, architecture, hook schema, map handles and hardening before returning a pin.
  public mutating func attach(
    _ hasProbeResource: Bool, _ module: UInt64, _ hook: UInt64,
    _ verifyAndPin: (UInt64, UInt64) -> UInt64,
    _ publish: (UInt64, UInt64) -> Bool, _ unpin: (UInt64) -> Void
  ) -> Bool {
    if !hasProbeResource || image != 0 || module == 0 || hook == 0 { return false }
    let verified = verifyAndPin(module, hook)
    if verified == 0 { return false }
    if !publish(hook, verified) {
      unpin(verified)
      return false
    }
    image = verified
    hookToken = hook
    return true
  }
  public mutating func detach(
    _ unpublishAndDrain: (UInt64, UInt64) -> Bool,
    _ unpin: (UInt64) -> Void
  ) -> Bool {
    if image == 0 || !unpublishAndDrain(hookToken, image) { return false }
    unpin(image)
    image = 0
    hookToken = 0
    return true
  }
}
