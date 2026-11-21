import TarwinABI
import TarwinObject
import TarwinSyscall

/// Kernel-only services under the VM/domain lock. A successful pin owns the
/// resolved Memory pages (including COW and quota) until explicit unpin.
public protocol DmaCallPlatform: ~Copyable {
  mutating func size(of memory: UnsafePointer<ObjectHeader>) -> UInt64?
  mutating func randomWord() -> UInt64?
  mutating func pin(_ memory: UnsafePointer<ObjectHeader>, span: DmaSpan) -> UInt64
  mutating func mapPinned(domain: UInt64, address: UInt64, pin: UInt64, span: DmaSpan) -> Bool
  /// Supply a fresh Manage-only DmaBuffer with one initial reference. Its
  /// finalizer must find this domain even after group removal or process exit.
  mutating func allocateBuffer(job: UInt64, domain: UInt64) -> UnsafePointer<ObjectHeader>?
  mutating func reclaimUnpublished(_ buffer: UnsafePointer<ObjectHeader>)
  /// Infallibly record work, not a synchronous re-entry into the domain.
  mutating func quarantine(domain: UInt64, mapping: UInt64)
}

private func dmaError(_ code: UInt32) -> CallResult { CallResult(status: syscallStatus(code, 5)) }

public struct DmaCreateQuery {
  fileprivate let domainName: UInt64, memoryName: UInt64, span: DmaSpan

  public func issue<B: DmaCallPlatform & ~Copyable>(
    to process: inout ProcessExecution, tree: borrowing JobTree,
    registry: borrowing HardwareRegistry, platform: inout B,
    withDomain: (UnsafePointer<ObjectHeader>, (SlotDomainBinding, inout SlotDomain) -> CallResult)
      -> CallResult
  ) -> CallResult {
    let owner = process.member.id
    let job = process.header.pointee.ownerJob
    return process.withHandles(tree: tree) { table in
      switch table.reader.pinWithinEpoch(domainName, kind: TarwinKind.iommuDomain, need: 512) {
      case .invalidHandle: return dmaError(2)
      case .wrongType: return dmaError(3)
      case .accessDenied: return dmaError(4)
      case .found(let d):
        let header = d.header
        // Both table entries stay live under the process writer lock.
        d.drop { _ in preconditionFailure("domain lost its handle") }
        return withDomain(header) { binding, backing in
          guard !backing.revoking, binding.domain == header, backing.koid == header.pointee.koid,
            backing.group == binding.lease.group, backing.epoch == binding.lease.epoch
          else { return dmaError(70) }
          guard binding.lease.process == owner else { return dmaError(4) }
          guard
            let slot = registry.activeSlot(binding.lease, process: owner, node: binding.lease.node)
          else { return dmaError(70) }
          switch table.reader.pinWithinEpoch(
            memoryName, kind: TarwinKind.memory, need: span.access.memoryRights)
          {
          case .invalidHandle: return dmaError(2)
          case .wrongType: return dmaError(3)
          case .accessDenied: return dmaError(4)
          case .found(let m):
            let memory = m.header
            let rights = m.rights
            m.drop { _ in preconditionFailure("memory lost its handle") }
            guard deviceAligned(span.offset, backing.page), deviceAligned(span.bytes, backing.page)
            else { return dmaError(1) }
            guard let size = platform.size(of: memory) else { return dmaError(23) }
            guard span.offset < size, span.bytes <= size - span.offset,
              span.bytes <= backing.aperture.length
            else { return dmaError(6) }
            guard table.freeCount > 0 else { return dmaError(33) }
            guard backing.hasCapacity else { return dmaError(31) }
            guard let buffer = platform.allocateBuffer(job: job, domain: backing.koid)
            else { return dmaError(30) }
            defer {
              if buffer.pointee.release() == .destroy { platform.reclaimUnpublished(buffer) }
            }
            guard buffer.pointee.kind == TarwinKind.dmaBuffer, buffer.pointee.ownerJob == job,
              buffer.pointee.maximumRights == 512
            else { return dmaError(90) }
            let domainGrant = PinnedIoHandle(koid: backing.koid, kind: .iommuDomain, rights: 512)
            let memoryGrant = PinnedIoHandle(
              koid: memory.pointee.koid, kind: .memory, rights: rights)
            for _ in 0..<16 {
              guard let word = platform.randomWord() else { return dmaError(24) }
              switch backing.create(
                domainGrant, memoryGrant, slot, owner, size, span, word,
                { _, range in platform.pin(memory, span: range) },
                { platform.mapPinned(domain: $0, address: $1, pin: $2, span: $3) })
              {
              case .retry: continue
              case .refused: return dmaError(30)
              case .quarantined(let id):
                platform.quarantine(domain: backing.koid, mapping: id)
                return dmaError(70)
              case .mapped(let mapping):
                backing.bindLastMapping(mapping.id, buffer: buffer.pointee.koid)
                guard case .installed(let name) = table.install(buffer, rights: 512) else {
                  platform.quarantine(domain: backing.koid, mapping: mapping.id)
                  return dmaError(90)
                }
                return CallResult(first: name, second: mapping.address)
              }
            }
            return dmaError(24)
          }
        }
      }
    } ?? dmaError(23)
  }
}

extension SlotDomain {
  /// Called by the finalizer under the domain lock. Retain the payload and
  /// retry on a failed drain; never accept a driver-provided mapping ID.
  public mutating func retireBuffer(
    _ header: borrowing ObjectHeader,
    detach: (UInt64, UInt64, UInt64) -> Bool, invalidate: (UInt64, UInt64, UInt64) -> Bool,
    drainAtcs: (UInt64, UInt64, UInt64) -> Bool, drainWrites: (UInt64, UInt64, UInt64) -> Bool,
    releasePin: (UInt64) -> Bool
  ) -> Bool {
    guard header.kind == TarwinKind.dmaBuffer, let id = mapping(forBuffer: header.koid) else {
      return false
    }
    return retire(id, detach, invalidate, drainAtcs, drainWrites, releasePin)
  }
}

public protocol DmaCreateContext {
  /// Serialize current-process, job, registry, VM and domain access; the
  /// registry selects the backing using the retained domain object header.
  mutating func withLockedCaller(_ query: DmaCreateQuery) -> CallResult
}

public struct DmaCreateCall<C: DmaCreateContext>: CallProvider {
  public var context: C
  public init(_ context: C) { self.context = context }
  public func argumentCount(for number: UInt64) -> UInt32? {
    number == TarwinCall.dmaBufferCreate ? 5 : nil
  }
  public mutating func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool
  { false }
  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard number == TarwinCall.dmaBufferCreate else { return dmaError(10) }
    guard words.count == 5, words[3] != 0 else { return dmaError(1) }
    let access: DmaAccess
    switch words[4] {
    case 1: access = .deviceRead
    case 2: access = .deviceWrite
    case 3: access = .both
    default: return dmaError(1)
    }
    return context.withLockedCaller(
      .init(
        domainName: words[0], memoryName: words[1],
        span: .init(offset: words[2], bytes: words[3], access: access)))
  }
}
