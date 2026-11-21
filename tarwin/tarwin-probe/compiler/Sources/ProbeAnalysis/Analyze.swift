import TarwinProbe

// Compiler-side view of verified TIR, not a guest wire format. The structured
// control-flow pass supplies a postorder DAG. Bounds come from range analysis,
// not from untrusted module annotations. A leaf is one decoded instruction.
public struct ByteRead {
  public let offset: UInt64
  public let width: UInt64

  public init(offset: UInt64, width: UInt64) {
    self.offset = offset
    self.width = width
  }
}
public struct Edges {
  public let a: Int
  public let b: Int

  public init(a: Int, b: Int) {
    self.a = a
    self.b = b
  }
}
public struct Bound {
  public let body: Int
  public let bound: UInt64

  public init(body: Int, bound: UInt64) {
    self.body = body
    self.bound = bound
  }
}
public enum ProbeTerm {
  case definedScalar
  case context(ByteRead)
  case helper(ProbeEffect)
  case sequence(Edges)
  case choice(Edges)
  case counted(Bound)
  case directCall(Int)
  case unprovenLoop, unsupported
}
public enum AnalysisFailure: Error {
  case empty, invalidGraph, bounds, hookEffect, forbidden, budget
}

public func worstCase(
  _ terms: [ProbeTerm], _ contextBytes: UInt64,
  _ hook: ProbeHook
) -> Result<UInt64, AnalysisFailure> {
  if terms.count == 0 { return .failure(.empty) }
  if terms.count > 1_000_000 { return .failure(.budget) }
  var costs: [UInt64] = []
  for i in 0..<terms.count {
    let n: UInt64
    switch terms[i] {
    case .definedScalar: n = 1
    case .context(let read):
      let offset = read.offset
      let width = read.width
      if width == 0 || offset > contextBytes || width > contextBytes - offset {
        return .failure(.bounds)
      }
      n = UInt64(1)

    case .helper(let action):
      if !effectAllowed(hook, action) { return .failure(.hookEffect) }
      n = UInt64(1)

    case .sequence(let edges):
      let a = edges.a
      let b = edges.b
      if a < 0 || b < 0 || a >= i || b >= i { return .failure(.invalidGraph) }
      n = sequentialCost(costs[a], costs[b])

    case .choice(let edges):
      let a = edges.a
      let b = edges.b
      if a < 0 || b < 0 || a >= i || b >= i { return .failure(.invalidGraph) }
      n = branchCost(costs[a], costs[b])

    case .directCall(let callee):
      if callee < 0 || callee >= i { return .failure(.invalidGraph) }
      n = sequentialCost(1, costs[callee])

    case .counted(let loopInfo):
      let body = loopInfo.body
      let bound = loopInfo.bound
      if body < 0 || body >= i { return .failure(.invalidGraph) }
      n = loopCost(costs[body], bound)

    case .unprovenLoop: return .failure(.bounds)
    case .unsupported: return .failure(.forbidden)
    }
    if n > ProbeLimit.instructions { return .failure(.budget) }
    costs.append(n)
  }
  return .success(costs[costs.count - 1])
}
