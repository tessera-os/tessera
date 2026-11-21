public struct PowerEdge: Equatable {
  public let dependent: Int
  public let provider: Int

  public init(dependent: Int, provider: Int) {
    self.dependent = dependent
    self.provider = provider
  }
}
public enum SuspendPlan: Equatable {
  case invalid
  case order([Int])
}

// Topological order of dependents before providers. Refuse a broken power
// plane before suspending even the first device. Linear time and storage.
public func planSuspend(_ nodes: Int, _ edges: [PowerEdge]) -> SuspendPlan {
  if nodes < 0 { return .invalid }
  var counts: [Int] = []
  var first: [Int] = []
  var next: [Int] = []
  var order: [Int] = []
  for i in 0..<nodes {
    counts.append(0)
    first.append(-1)
  }
  for i in 0..<edges.count {
    let e = edges[i]
    if e.provider < 0 || e.dependent < 0 || e.provider >= nodes || e.dependent >= nodes {
      return .invalid
    }
    counts[e.provider] += 1
    next.append(first[e.dependent])
    first[e.dependent] = Int(i)
  }
  for node in 0..<nodes { if counts[node] == 0 { order.append(Int(node)) } }
  var at: Int = 0
  while at < order.count {
    var edge = first[order[at]]
    while edge >= 0 {
      let provider = edges[edge].provider
      counts[provider] -= 1
      if counts[provider] == 0 { order.append(provider) }
      edge = next[edge]
    }
    at += 1
  }
  if order.count != nodes { return .invalid }
  return .order(order)
}

// The controller holds the power-plane generation fixed during a transaction.
// A failed transition leaves that device in its previous state. Resume stops
// on an unavailable provider, retaining the cursor for recovery.
public struct SleepTransaction: Equatable {
  public let order: [Int]
  public internal(set) var asleep: Int = 0

  public mutating func quiesce(
    _ sleep: (Int) -> Bool, _ wakePending: () -> Bool, _ resume: (Int) -> Bool
  ) -> Bool {
    if asleep != 0 { return false }
    for node in order {
      if wakePending() || !sleep(node) {
        _ = restore(resume)
        return false
      }
      asleep += 1
    }
    if wakePending() {
      _ = restore(resume)
      return false
    }
    return true
  }

  public mutating func restore(_ resume: (Int) -> Bool) -> Bool {
    while asleep > 0 {
      if !resume(order[asleep - 1]) { return false }
      asleep -= 1
    }
    return true
  }

  public init(order: [Int]) {
    self.order = order
  }
}
