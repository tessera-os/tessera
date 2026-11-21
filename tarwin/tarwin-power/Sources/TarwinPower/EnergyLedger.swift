private func energySum(_ a: UInt64, _ b: UInt64) -> UInt64 {
  let (n, overflow) = a.addingReportingOverflow(b)
  return overflow ? .max : n
}

public enum EnergySource { case gpu, display, radio }

public struct EnergyUsage: Equatable {
  public fileprivate(set) var cpu = ProcessEnergy()
  public fileprivate(set) var runtimeNs: UInt64 = 0, unmodelledNs: UInt64 = 0
  public fileprivate(set) var gpu: UInt64 = 0, display: UInt64 = 0, radio: UInt64 = 0
  public fileprivate(set) var lostReports: UInt64 = 0
  public var microjoules: UInt64 {
    energySum(energySum(cpu.microjoules, gpu), energySum(display, radio))
  }
  fileprivate mutating func add(_ amount: UInt64, from source: EnergySource) {
    switch source {
    case .gpu: gpu = energySum(gpu, amount)
    case .display: display = energySum(display, amount)
    case .radio: radio = energySum(radio, amount)
    }
  }
}

/// Tokens are kernel-private. The object table retains the account for each
/// process and resolves the reporting port to a counter; wire IDs grant no access.
public struct EnergyAccount: Equatable {
  fileprivate let book: UInt64, generation: UInt64, slot: Int
}
public struct EnergyCounter: Equatable {
  fileprivate let book: UInt64, generation: UInt64, slot: Int
}
public struct EnergyAccountSlot {
  fileprivate var generation: UInt64 = 0, usage: EnergyUsage?
  public init() {}
}
public struct EnergyCPUSlot {
  fileprivate var account: EnergyAccount?, last: UInt64 = 0, microwatts: UInt32?
  public init() {}
}
public struct EnergyCounterSlot {
  fileprivate var generation: UInt64 = 0, account: EnergyAccount?, source = EnergySource.gpu
  fileprivate var sequence: UInt64 = 0, total: UInt64 = 0
  public init() {}
}

/// Single serialized ledger. Supply disjoint, initialized, zero-state slabs,
/// pinned until shutdown, and a fresh non-reused kernel instance identity.
public struct EnergyLedger: ~Copyable {
  private let book: UInt64, accounts: UnsafeMutableBufferPointer<EnergyAccountSlot>
  private let cpus: UnsafeMutableBufferPointer<EnergyCPUSlot>,
    counters: UnsafeMutableBufferPointer<EnergyCounterSlot>
  public init?(
    id: UInt64, accounts: UnsafeMutableBufferPointer<EnergyAccountSlot>,
    cpus: UnsafeMutableBufferPointer<EnergyCPUSlot>,
    counters: UnsafeMutableBufferPointer<EnergyCounterSlot>
  ) {
    guard id != 0, accounts.count > 0, cpus.count > 0 else { return nil }
    for i in 0..<accounts.count where accounts[i].generation != 0 || accounts[i].usage != nil {
      return nil
    }
    for i in 0..<cpus.count where cpus[i].account != nil || cpus[i].last != 0 { return nil }
    for i in 0..<counters.count where counters[i].generation != 0 || counters[i].account != nil {
      return nil
    }
    book = id
    self.accounts = accounts
    self.cpus = cpus
    self.counters = counters
  }
  private func live(_ a: EnergyAccount) -> Bool {
    a.book == book && accounts.indices.contains(a.slot)
      && accounts[a.slot].generation == a.generation
      && accounts[a.slot].usage != nil
  }
  public mutating func openProcess(at slot: Int) -> EnergyAccount? {
    guard accounts.indices.contains(slot), accounts[slot].usage == nil,
      accounts[slot].generation != .max
    else { return nil }
    accounts[slot].generation += 1
    accounts[slot].usage = EnergyUsage()
    return EnergyAccount(book: book, generation: accounts[slot].generation, slot: slot)
  }
  private mutating func settle(_ i: Int, to now: UInt64) {
    if let a = cpus[i].account {
      let ns = now - cpus[i].last
      var u = accounts[a.slot].usage!
      u.runtimeNs = energySum(u.runtimeNs, ns)
      if let rate = cpus[i].microwatts {
        u.cpu.addCpu(ns, rate)
      } else {
        u.unmodelledNs = energySum(u.unmodelledNs, ns)
      }
      accounts[a.slot].usage = u
    }
    cpus[i].last = now
  }
  /// Call on dispatch, observed frequency change and entry to idle. An unknown
  /// OPP records unmodelled time instead of silently using the previous rate.
  public mutating func switchCPU(
    _ i: Int, at now: UInt64, to next: EnergyAccount?,
    frequencyHz: UInt64, model: (Int, UInt64) -> UInt32?
  ) -> Bool {
    if let next, !live(next) { return false }
    guard cpus.indices.contains(i), now >= cpus[i].last,
      next != nil || frequencyHz == 0
    else { return false }
    settle(i, to: now)
    cpus[i].account = next
    cpus[i].microwatts = next == nil || frequencyHz == 0 ? nil : model(i, frequencyHz)
    return true
  }
  /// The caller validates both the driver slot and the retained process's
  /// work context. Bind a cumulative, per-context microjoule counter; never
  /// attribute an entire device's shared energy counter to a single process.
  public mutating func bindCounter(
    at i: Int, for a: EnergyAccount, source: EnergySource, baseline: UInt64
  ) -> EnergyCounter? {
    guard live(a), counters.indices.contains(i), counters[i].account == nil,
      counters[i].generation != .max
    else { return nil }
    counters[i].generation += 1
    counters[i].account = a
    counters[i].source = source
    counters[i].sequence = 0
    counters[i].total = baseline
    return EnergyCounter(book: book, generation: counters[i].generation, slot: i)
  }
  private func liveCounter(_ c: EnergyCounter) -> Bool {
    c.book == book && counters.indices.contains(c.slot)
      && counters[c.slot].generation == c.generation
      && counters[c.slot].account != nil
  }
  public mutating func report(_ c: EnergyCounter, sequence: UInt64, cumulative: UInt64) -> Bool {
    guard liveCounter(c) else { return false }
    let s = counters[c.slot]
    guard sequence > s.sequence, cumulative >= s.total, let a = s.account else { return false }
    accounts[a.slot].usage!.add(cumulative - s.total, from: s.source)
    counters[c.slot].sequence = sequence
    counters[c.slot].total = cumulative
    return true
  }
  /// A terminal report is folded exactly once; if it is malformed, retain
  /// the binding. On slot loss the trusted teardown path records the gap.
  public mutating func finish(_ c: EnergyCounter, sequence: UInt64, cumulative: UInt64) -> Bool {
    guard report(c, sequence: sequence, cumulative: cumulative) else { return false }
    counters[c.slot].account = nil
    return true
  }
  public mutating func lost(_ c: EnergyCounter) -> Bool {
    guard liveCounter(c), let a = counters[c.slot].account else { return false }
    let gaps = accounts[a.slot].usage!.lostReports
    accounts[a.slot].usage!.lostReports = energySum(gaps, 1)
    counters[c.slot].account = nil
    return true
  }
  public mutating func sample(_ a: EnergyAccount, at now: UInt64) -> EnergyUsage? {
    guard live(a) else { return nil }
    for i in 0..<cpus.count where cpus[i].account == a && cpus[i].last > now { return nil }
    for i in cpus.indices where cpus[i].account == a { settle(i, to: now) }
    return accounts[a.slot].usage
  }
  /// Archive the returned summary before recycling the process slot. A live
  /// device binding or CPU interval prevents reuse even after process exit.
  public mutating func close(_ a: EnergyAccount) -> EnergyUsage? {
    guard live(a) else { return nil }
    for i in 0..<cpus.count where cpus[i].account == a { return nil }
    for i in 0..<counters.count where counters[i].account == a { return nil }
    let u = accounts[a.slot].usage
    accounts[a.slot].usage = nil
    return u
  }
}
