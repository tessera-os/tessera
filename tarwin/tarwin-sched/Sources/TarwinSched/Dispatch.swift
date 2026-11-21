public enum SchedClass {
  public static let idle: UInt8 = 0
  public static let background: UInt8 = 1
  public static let utility: UInt8 = 2
  public static let normal: UInt8 = 3
  public static let initiated: UInt8 = 4
  public static let interactive: UInt8 = 5
  public static let deadline: UInt8 = 6
}

public struct DispatchKey {
  public let qos: UInt8
  public let readySince: UInt64
  public let virtualStart: UInt64
  public let virtualDeadline: UInt64
  public let classVirtualTime: UInt64
  public let absoluteDeadline: UInt64
  public let remainingBudget: UInt64
  public let threadId: UInt64

  public func effective() -> UInt8 {
    if qos == SchedClass.deadline && remainingBudget == 0 { return SchedClass.interactive }
    return qos
  }

  public func starvationWait(_ now: UInt64) -> UInt64 {
    var bound: UInt64 = 0
    if qos == SchedClass.normal { bound = 100_000_000 }
    if qos == SchedClass.utility { bound = 250_000_000 }
    if qos == SchedClass.background { bound = 1_000_000_000 }
    if bound == 0 || now < readySince || now - readySince < bound { return 0 }
    // Oldest violated bound first. Nonzero includes an exact-bound wait.
    return now - readySince - bound + 1
  }

  public init(
    qos: UInt8, readySince: UInt64, virtualStart: UInt64, virtualDeadline: UInt64,
    classVirtualTime: UInt64, absoluteDeadline: UInt64, remainingBudget: UInt64, threadId: UInt64
  ) {
    self.qos = qos
    self.readySince = readySince
    self.virtualStart = virtualStart
    self.virtualDeadline = virtualDeadline
    self.classVirtualTime = classVirtualTime
    self.absoluteDeadline = absoluteDeadline
    self.remainingBudget = remainingBudget
    self.threadId = threadId
  }
}

// Strict ordering on runnable candidates on one CPU. The selected thread's
// readySince resets after its quantum. Class clocks come from the run queue.
public func dispatchBefore(_ a: DispatchKey, _ b: DispatchKey, _ now: UInt64) -> Bool {
  let aq = a.effective()
  let bq = b.effective()
  if aq == SchedClass.deadline || bq == SchedClass.deadline {
    if aq != bq { return aq == SchedClass.deadline }
    if a.absoluteDeadline != b.absoluteDeadline { return a.absoluteDeadline < b.absoluteDeadline }
    return a.threadId < b.threadId
  }
  let aw = a.starvationWait(now)
  let bw = b.starvationWait(now)
  if aw != bw { return aw > bw }
  if aq != bq { return aq > bq }
  let ae = a.virtualStart <= a.classVirtualTime
  let be = b.virtualStart <= b.classVirtualTime
  if ae != be { return ae }
  // If no one is eligible, advance to the first candidate's start.
  if !ae && a.virtualStart != b.virtualStart { return a.virtualStart < b.virtualStart }
  if a.virtualDeadline != b.virtualDeadline { return a.virtualDeadline < b.virtualDeadline }
  return a.threadId < b.threadId
}

// Nanoseconds charged in a single 1–20 ms request, scaled by base weight 17.
// Relative priorities −16…15 map monotonically to weights 1…32.
public func virtualSlice(_ sliceNs: UInt64, _ relativePriority: Int) -> UInt64 {
  if sliceNs < 1_000_000 || sliceNs > 20_000_000 { return 0 }
  if relativePriority < -16 || relativePriority > 15 { return 0 }
  let weight = UInt64(relativePriority + 17)
  return (sliceNs * 17 + weight - 1) / weight
}
