import Synchronization
import TarwinDevice

public enum AdrenoGPUStatus: Error, Equatable, Sendable {
  /// Rejected before any state change.
  case invalidArgument, unknownHandle, outOfMemory
  /// The provider can no longer tell what the GPU retired.
  case deviceLost
  /// The wait ended without proving retirement.
  case cancelled
  case unsupported
  case system(Int32)
}

public struct AdrenoGPUFacts: Equatable, @unchecked Sendable {
  public let chipID: UInt64
  public let gpuAddresses: DeviceRange
  public let page: UInt64
  public let counterHz: UInt64?
}

public struct AdrenoGPUGrant: @unchecked Sendable {
  public let handle: UInt64
  public let gpuAddress: UInt64
  public let length: UInt64
  public let cpuAddress: UnsafeMutableRawPointer
}

public struct AdrenoGPUAccess: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let read = Self(rawValue: 1)
  public static let write = Self(rawValue: 2)
}

public struct AdrenoGPUJob: Sendable, Equatable {
  public struct Command: Sendable, Equatable {
    public var handle: UInt64, byteOffset: UInt32, dwordCount: UInt32
    public init(handle: UInt64, byteOffset: UInt32, dwordCount: UInt32) {
      self.handle = handle
      self.byteOffset = byteOffset
      self.dwordCount = dwordCount
    }
  }
  public struct Buffer: Sendable, Equatable {
    public var handle: UInt64, usage: AdrenoGPUAccess
    public init(handle: UInt64, usage: AdrenoGPUAccess) {
      self.handle = handle
      self.usage = usage
    }
  }
  public var commands: [Command]
  public var buffers: [Buffer]
  public init(commands: [Command], buffers: [Buffer]) {
    self.commands = commands
    self.buffers = buffers
  }
}

/// One ringbuffer on an admitted Adreno 740. Buffers are provider-owned Memory
/// objects pinned into the GPU's domain at provider-chosen addresses; jobs run
/// as indirect buffers in submission order and complete on a CACHE_FLUSH_TS
/// timeline in a private memstore. A closed buffer keeps its pin, address and
/// charge until every job naming it retires and `DmaRetirement` reaches
/// `.released`. After an indeterminate failure the referenced buffers stay
/// quarantined: nothing short of a trusted slot drain frees them.
public final class AdrenoGPUProvider: Sendable {
  private struct Buffer {
    var memory: AdrenoMemory
    var retirement: DmaRetirement
    var gpuReadOnly: Bool
    var lastUse: UInt64 = 0
    var closed = false
  }
  private struct State {
    var buffers: [UInt64: Buffer] = [:]
    var fixed: [DmaRetirement] = []
    var nextHandle: UInt64 = 0
    var submitted: UInt64 = 0
    var completed: UInt64 = 0
    var wptr: UInt32 = 0
    var lost = false
  }

  static let EIO: Int32 = 5
  private static let fenceDwords: UInt32 = 5
  private static let commandDwords: UInt32 = 4

  public let facts: AdrenoGPUFacts
  private let platform: any AdrenoPlatform
  private let profile: AdrenoProfile
  private let ring: AdrenoMemory
  private let ringAddress: UInt64
  private let memstore: AdrenoMemory
  private let memstoreAddress: UInt64
  private let state: Mutex<State>

  init(candidate: AdrenoCandidate, profile: AdrenoProfile, platform: any AdrenoPlatform)
    throws(AdrenoGPUStatus)
  {
    let ringBytes = profile.ringBytes
    guard candidate.chipID == profile.chipID, profile.gpuAddresses.valid(), profile.page >= 4096,
      profile.page & (profile.page - 1) == 0, ringBytes >= 4096, ringBytes & (ringBytes - 1) == 0,
      UInt64(ringBytes) % profile.page == 0, ringBytes / 8 <= 1 << 31
    else { throw .invalidArgument }
    guard platform.mapRegisters(candidate.registers) else { throw .system(Self.EIO) }
    self.platform = platform
    self.profile = profile
    facts = AdrenoGPUFacts(
      chipID: profile.chipID, gpuAddresses: profile.gpuAddresses, page: profile.page,
      counterHz: profile.counterHz)
    var fixed: [DmaRetirement] = []
    let ringMap = try Self.map(
      platform, profile, occupied: [], bytes: UInt64(ringBytes), cache: .writeCombined,
      access: .deviceRead)
    fixed.append(ringMap.1)
    let storeMap = try Self.map(
      platform, profile, occupied: [Self.range(ringMap.1)], bytes: profile.page, cache: .uncached,
      access: .both)
    fixed.append(storeMap.1)
    ring = ringMap.0
    ringAddress = ringMap.1.base
    memstore = storeMap.0
    memstoreAddress = storeMap.1.base
    memstore.cpuAddress.initializeMemory(as: UInt8.self, repeating: 0, count: Int(memstore.bytes))
    state = Mutex(State(fixed: fixed))

    platform.write32(AdrenoRegister.CP_RB_BASE, UInt32(truncatingIfNeeded: ringAddress))
    platform.write32(AdrenoRegister.CP_RB_BASE_HI, UInt32(truncatingIfNeeded: ringAddress >> 32))
    platform.write32(AdrenoRegister.CP_RB_CNTL, AdrenoPM4.ringControl(bytes: ringBytes))
    platform.write32(AdrenoRegister.CP_RB_WPTR, 0)
    platform.write32(AdrenoRegister.RBBM_INT_CLEAR_CMD, ~0)
    platform.write32(AdrenoRegister.RBBM_INT_0_MASK, AdrenoInterrupt.enabled)
  }

  private static func range(_ r: DmaRetirement) -> DeviceRange {
    DeviceRange(base: r.base, length: r.bytes)
  }

  /// Creates, charges, pins and maps one Memory object. On failure everything
  /// acquired is undone, except a mapping whose retirement could not finish.
  private static func map(
    _ platform: any AdrenoPlatform, _ profile: AdrenoProfile, occupied: [DeviceRange],
    bytes: UInt64, cache: AdrenoCacheMode, access: DmaAccess
  ) throws(AdrenoGPUStatus) -> (AdrenoMemory, DmaRetirement) {
    guard let memory = platform.createMemory(bytes: bytes, cache: cache) else {
      throw .outOfMemory
    }
    guard memory.bytes == bytes, platform.charge(memory.koid, bytes: bytes) else {
      platform.closeMemory(memory.koid)
      throw .outOfMemory
    }
    var address: UInt64?
    for _ in 0..<4 {
      if case .selected(let iova) = chooseDmaAddress(
        profile.gpuAddresses, bytes, profile.page, platform.randomWord(), occupied)
      {
        address = iova
        break
      }
    }
    let span = DmaSpan(offset: 0, bytes: bytes, access: access)
    guard let address else {
      platform.refund(memory.koid, bytes: bytes)
      platform.closeMemory(memory.koid)
      throw .outOfMemory
    }
    let pin = platform.pin(memory.koid, span)
    guard pin != 0 else {
      platform.refund(memory.koid, bytes: bytes)
      platform.closeMemory(memory.koid)
      throw .outOfMemory
    }
    var retirement = DmaRetirement(
      domain: profile.domain, pin: pin, base: address, bytes: bytes, phase: .mapped)
    guard platform.mapPinned(profile.domain, address, pin, span) else {
      // A partial install retires like any mapping; if that fails the pin and
      // charge stay held for the slot drain.
      let p = platform
      if retirement.retire(p.detach, p.invalidateIo, p.invalidateAtcs, p.drainWrites, p.releasePin) {
        platform.closeMemory(memory.koid)
        platform.refund(memory.koid, bytes: bytes)
      }
      throw .system(EIO)
    }
    return (memory, retirement)
  }

  private func occupied(_ state: State) -> [DeviceRange] {
    state.fixed.map(Self.range) + state.buffers.values.map { Self.range($0.retirement) }
  }

  public func createBuffer(length: UInt64, cache: AdrenoCacheMode, gpuReadOnly: Bool)
    throws(AdrenoGPUStatus) -> AdrenoGPUGrant
  {
    let page = profile.page
    guard length > 0, length <= profile.gpuAddresses.length - (page - 1) else {
      throw .invalidArgument
    }
    let bytes = (length + page - 1) & ~(page - 1)
    return try state.withLock { (state) throws(AdrenoGPUStatus) -> AdrenoGPUGrant in
      guard !state.lost else { throw .deviceLost }
      guard state.nextHandle < .max else { throw .outOfMemory }
      let (memory, retirement) = try Self.map(
        platform, profile, occupied: occupied(state), bytes: bytes, cache: cache,
        access: gpuReadOnly ? .deviceRead : .both)
      state.nextHandle += 1
      let handle = state.nextHandle
      state.buffers[handle] = Buffer(memory: memory, retirement: retirement, gpuReadOnly: gpuReadOnly)
      return AdrenoGPUGrant(
        handle: handle, gpuAddress: retirement.base, length: bytes, cpuAddress: memory.cpuAddress)
    }
  }

  /// Drops the client's reference. Storage, pin, address and charge stay until
  /// every job naming the buffer has retired.
  public func closeBuffer(_ handle: UInt64) throws(AdrenoGPUStatus) {
    try state.withLock { (state) throws(AdrenoGPUStatus) in
      guard var buffer = state.buffers[handle], !buffer.closed else { throw .unknownHandle }
      buffer.closed = true
      state.buffers[handle] = buffer
      reap(&state)
    }
  }

  /// Retires closed buffers whose jobs are done. A step that fails leaves the
  /// buffer in place (phase kept, address reserved, charge held) for the next pass.
  private func reap(_ state: inout State) {
    for (handle, var buffer) in state.buffers
    where buffer.closed && buffer.lastUse <= state.completed {
      let p = platform
      let released = buffer.retirement.retire(
        p.detach, p.invalidateIo, p.invalidateAtcs, p.drainWrites, p.releasePin)
      if released {
        state.buffers[handle] = nil
        p.closeMemory(buffer.memory.koid)
        p.refund(buffer.memory.koid, bytes: buffer.memory.bytes)
      } else {
        state.buffers[handle] = buffer
      }
    }
  }

  private func validate(_ job: AdrenoGPUJob, _ state: State) throws(AdrenoGPUStatus) {
    guard !job.commands.isEmpty else { throw .invalidArgument }
    var usage: [UInt64: AdrenoGPUAccess] = [:]
    for access in job.buffers {
      guard let buffer = state.buffers[access.handle], !buffer.closed else { throw .unknownHandle }
      guard !access.usage.isEmpty, access.usage.rawValue & ~UInt32(3) == 0,
        !(access.usage.contains(.write) && buffer.gpuReadOnly),
        usage.updateValue(access.usage, forKey: access.handle) == nil
      else { throw .invalidArgument }
    }
    for command in job.commands {
      guard let buffer = state.buffers[command.handle], !buffer.closed else { throw .unknownHandle }
      let (bytes, overflow) = UInt64(command.dwordCount).multipliedReportingOverflow(by: 4)
      guard usage[command.handle]?.contains(.read) == true, command.byteOffset % 4 == 0,
        command.dwordCount > 0, command.dwordCount <= AdrenoPM4.maxIBDwords, !overflow,
        UInt64(command.byteOffset) < buffer.memory.bytes,
        bytes <= buffer.memory.bytes - UInt64(command.byteOffset)
      else { throw .invalidArgument }
    }
  }

  /// Writes the job into the ring and returns its timeline value. The value
  /// increases by one per accepted job.
  public func submit(_ job: AdrenoGPUJob) throws(AdrenoGPUStatus) -> UInt64 {
    try state.withLock { (state) throws(AdrenoGPUStatus) -> UInt64 in
      guard !state.lost else { throw .deviceLost }
      try validate(job, state)
      let ringDwords = profile.ringBytes / 4
      guard job.commands.count <= Int((ringDwords - Self.fenceDwords) / Self.commandDwords) / 2
      else { throw .invalidArgument }
      var words: [UInt32] = []
      words.reserveCapacity(job.commands.count * 4 + 5)
      for command in job.commands {
        let address = state.buffers[command.handle]!.retirement.base + UInt64(command.byteOffset)
        words += [
          AdrenoPM4.pkt7(AdrenoPM4.CP_INDIRECT_BUFFER, count: 3),
          UInt32(truncatingIfNeeded: address), UInt32(truncatingIfNeeded: address >> 32),
          command.dwordCount,
        ]
      }
      let value = state.submitted + 1
      words += [
        AdrenoPM4.pkt7(AdrenoPM4.CP_EVENT_WRITE7, count: 4), AdrenoPM4.fenceEvent,
        UInt32(truncatingIfNeeded: memstoreAddress), UInt32(truncatingIfNeeded: memstoreAddress >> 32),
        UInt32(truncatingIfNeeded: value),
      ]
      let count = UInt32(words.count)
      let rptr = platform.read32(AdrenoRegister.CP_RB_RPTR)
      guard rptr < ringDwords else {
        state.lost = true
        throw .deviceLost
      }
      let tail = ringDwords - state.wptr
      let pad = count > tail ? tail : 0
      let used = (state.wptr &+ ringDwords &- rptr) % ringDwords
      guard used + pad + count < ringDwords else { throw .outOfMemory }

      var wptr = state.wptr
      if pad > 0 {
        store(AdrenoPM4.pkt7(AdrenoPM4.CP_NOP, count: pad - 1), at: wptr)
        wptr = 0
      }
      for word in words {
        store(word, at: wptr)
        wptr = (wptr + 1) % ringDwords
      }
      for access in job.buffers { state.buffers[access.handle]!.lastUse = value }
      state.submitted = value
      state.wptr = wptr
      atomicMemoryFence(ordering: .sequentiallyConsistent)
      platform.write32(AdrenoRegister.CP_RB_WPTR, wptr)
      guard platform.read32(AdrenoRegister.CP_RB_WPTR) == wptr else {
        state.lost = true
        quarantine(&state)
        throw .deviceLost
      }
      return value
    }
  }

  private func store(_ word: UInt32, at dword: UInt32) {
    ring.cpuAddress.storeBytes(of: word.littleEndian, toByteOffset: Int(dword) * 4, as: UInt32.self)
  }

  /// Every buffer named by a job that has not provably retired stays pinned
  /// and charged until a trusted drain of the whole slot.
  private func quarantine(_ state: inout State) {
    for (handle, buffer) in state.buffers where buffer.lastUse > state.completed {
      state.buffers[handle]!.lastUse = .max
    }
  }

  private func refresh(_ state: inout State) {
    guard !state.lost else { return }
    atomicMemoryFence(ordering: .sequentiallyConsistent)
    let seen = UInt32(littleEndian: memstore.cpuAddress.load(as: UInt32.self))
    let behind = UInt64(UInt32(truncatingIfNeeded: state.submitted) &- seen)
    guard behind <= state.submitted - state.completed else {
      state.lost = true
      quarantine(&state)
      return
    }
    state.completed = state.submitted - behind
  }

  /// `false` only on timeout. `true` once the job with `value` and all earlier
  /// ones have written their fence, so their GPU writes are visible.
  public func waitTimeline(reaching value: UInt64, timeoutNanoseconds: UInt64)
    throws(AdrenoGPUStatus) -> Bool
  {
    while true {
      let done = try state.withLock { (state) throws(AdrenoGPUStatus) -> Bool in
        guard value > 0, value <= state.submitted else { throw .invalidArgument }
        refresh(&state)
        guard !state.lost else { throw .deviceLost }
        guard state.completed >= value else { return false }
        reap(&state)
        return true
      }
      if done { return true }
      switch platform.waitInterrupt(timeoutNanoseconds: timeoutNanoseconds) {
      case .raised:
        let fatal = state.withLock { state in
          let status = platform.read32(AdrenoRegister.RBBM_INT_0_STATUS)
          platform.write32(AdrenoRegister.RBBM_INT_CLEAR_CMD, status)
          if status & AdrenoInterrupt.fatal != 0 {
            refresh(&state)
            state.lost = true
            quarantine(&state)
          }
          return state.lost
        }
        platform.completeInterrupt()
        if fatal { throw .deviceLost }
      case .timedOut:
        return try state.withLock { (state) throws(AdrenoGPUStatus) -> Bool in
          refresh(&state)
          guard !state.lost else { throw .deviceLost }
          guard state.completed >= value else { return false }
          reap(&state)
          return true
        }
      case .cancelled:
        throw .cancelled
      case .disconnected:
        state.withLock { state in
          state.lost = true
          quarantine(&state)
        }
        throw .deviceLost
      }
    }
  }

  /// Raw CP_ALWAYS_ON_COUNTER ticks, only when the profile knows the counter.
  public func readCounter() throws(AdrenoGPUStatus) -> UInt64 {
    guard facts.counterHz != nil else { throw .unsupported }
    return try state.withLock { (state) throws(AdrenoGPUStatus) -> UInt64 in
      guard !state.lost else { throw .deviceLost }
      for _ in 0..<3 {
        let high = platform.read32(AdrenoRegister.CP_ALWAYS_ON_COUNTER_HI)
        let low = platform.read32(AdrenoRegister.CP_ALWAYS_ON_COUNTER)
        if platform.read32(AdrenoRegister.CP_ALWAYS_ON_COUNTER_HI) == high {
          return UInt64(high) << 32 | UInt64(low)
        }
      }
      throw .system(Self.EIO)
    }
  }
}
