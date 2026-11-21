import TarwinABI
import TarwinDevice
import TarwinObject
import TarwinSyscall
import XCTest

private final class Backend: DmaCallPlatform {
  let ids = KoidSource()
  var memory: UnsafePointer<ObjectHeader>?
  var next: UInt64? = 0, samples = 0, pins = 0, allocations = 0, freed = 0
  var accept = true, quarantineID: UInt64?, mapped: [DmaAccess] = []
  func size(of memory: UnsafePointer<ObjectHeader>) -> UInt64? {
    memory == self.memory ? 8192 : nil
  }
  func randomWord() -> UInt64? {
    samples += 1
    return next
  }
  func pin(_ memory: UnsafePointer<ObjectHeader>, span: DmaSpan) -> UInt64 {
    guard memory == self.memory else { return 0 }
    XCTAssertLessThanOrEqual(span.offset + span.bytes, 8192)
    pins += 1
    return UInt64(pins)
  }
  func mapPinned(domain: UInt64, address: UInt64, pin: UInt64, span: DmaSpan) -> Bool {
    mapped.append(span.access)
    return accept
  }
  func allocateBuffer(job: UInt64, domain: UInt64) -> UnsafePointer<ObjectHeader>? {
    let h = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
    h.initialize(
      to: ObjectHeader(source: ids, ownerJob: job, kind: TarwinKind.dmaBuffer, maximumRights: 512)!)
    allocations += 1
    return .init(h)
  }
  func reclaimUnpublished(_ buffer: UnsafePointer<ObjectHeader>) { free(buffer) }
  func free(_ buffer: UnsafePointer<ObjectHeader>) {
    let h = UnsafeMutablePointer(mutating: buffer)
    h.deinitialize(count: 1)
    h.deallocate()
    freed += 1
  }
  func quarantine(domain: UInt64, mapping: UInt64) { quarantineID = mapping }
}
private struct Teardown: GroupTeardown {
  func maskInterrupts(group: UInt64) -> Bool { true }
  func revokeMaps(group: UInt64) -> Bool { true }
  func retireDma(group: UInt64) -> Bool { true }
  func reset(group: UInt64) -> Bool { true }
}
private final class Caller: DmaCreateContext {
  var process: ProcessExecution, domain: SlotDomain, platform: Backend
  var registry: HardwareRegistry
  let tree: JobTree, binding: SlotDomainBinding
  init(
    process: consuming ProcessExecution, tree: consuming JobTree,
    registry: consuming HardwareRegistry,
    domain: consuming SlotDomain, binding: SlotDomainBinding, platform: Backend
  ) {
    self.process = consume process
    self.tree = consume tree
    self.registry = consume registry
    self.domain = consume domain
    self.binding = binding
    self.platform = platform
  }
  func withLockedCaller(_ q: DmaCreateQuery) -> CallResult {
    q.issue(to: &process, tree: tree, registry: registry, platform: &platform) { _, body in
      body(binding, &domain)
    }
  }
}

final class DmaCreateTests: XCTestCase {
  func testCapabilityCreationQuarantineAndFinalClose() {
    let backend = Backend()
    let jobs = UnsafeMutableBufferPointer<JobNode>.allocate(capacity: 1)
    let members = UnsafeMutableBufferPointer<JobMember>.allocate(capacity: 1)
    let threads = UnsafeMutableBufferPointer<ThreadSlot>.allocate(capacity: 1)
    let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 9)
    let entries = UnsafeMutableBufferPointer<DomainEntry>.allocate(capacity: 3)
    let h = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 6)
    jobs.initialize(repeating: .init())
    members.initialize(repeating: .init())
    threads.initialize(repeating: .init())
    entries.initialize(repeating: .vacant)
    for (i, kind) in [
      TarwinKind.job, TarwinKind.process, TarwinKind.deviceSlot,
      TarwinKind.iommuDomain, TarwinKind.memory, TarwinKind.iommuDomain,
    ].enumerated() {
      (h + i).initialize(
        to: ObjectHeader(
          source: backend.ids, ownerJob: i == 0 ? 0 : h.pointee.koid,
          kind: kind, maximumRights: 0x7ff)!)
    }
    defer {
      for i in 0..<6 { XCTAssertEqual((h + i).pointee.release(), .destroy) }
      h.deinitialize(count: 6)
      h.deallocate()
      entries.deinitialize()
      entries.deallocate()
      cells.deinitialize()
      cells.deallocate()
      threads.deinitialize()
      threads.deallocate()
      jobs.deinitialize()
      jobs.deallocate()
      members.deinitialize()
      members.deallocate()
      XCTAssertEqual(backend.freed, backend.allocations)
    }
    var limits = JobLimits(
      processes: 1, threadsPerProcess: 1, handlesPerProcess: 9,
      footprint: 1 << 20, cpuShare: 1, maxQos: 5, jetsamBand: 1, ioRank: 1, entitlements: 0,
      denials: 0, killOnClose: false)
    let tree = JobTree(jobs: jobs, members: members, root: h.pointee, limits: limits)!
    let p = ProcessExecution(
      header: .init(h + 1), job: tree.root, tree: tree, slots: threads, cells: cells, salt: 89)!
    let dev = HardwareDevice(
      location: .firmware(1), parent: nil, stable: .init(high: 7, low: 2),
      identity: 11, deviceClass: 0, group: 7, mmio: [], wiredInterrupts: 0, powerStates: 1,
      wakeCapable: false)
    var registry = HardwareRegistry(limit: 1)!
    var teardown = Teardown()
    XCTAssertTrue(registry.stage([dev], reason: .orderly))
    XCTAssertTrue(registry.commit(&teardown))
    let lease = registry.assign(deviceRoot: true, node: 1, process: p.member.id) { _, _ in true }!
    let d = SlotDomain(
      group: 7, koid: (h + 3).pointee.koid, epoch: lease.epoch,
      aperture: .init(base: 0x10000, length: 8192), page: 4096, storage: entries)
    let binding = SlotDomainBinding(
      slot: .init(h + 2), domain: .init(h + 3), lease: lease, backing: d)!
    backend.memory = .init(h + 4)
    let c = Caller(
      process: consume p, tree: consume tree, registry: consume registry, domain: consume d,
      binding: binding, platform: backend)
    var provider = DmaCreateCall(c)
    func install(_ i: Int, _ rights: UInt64) -> UInt64 {
      guard
        case .installed(let name)? = c.process.withHandles(
          tree: c.tree, { $0.install(h + i, rights: rights) })
      else {
        XCTFail()
        return 0
      }
      return name
    }
    let domain = install(3, 512)
    let weak = install(3, 4)
    let foreign = install(5, 512)
    let read = install(4, 4)
    let write = install(4, 8)
    let both = install(4, 12)
    func call(
      _ dom: UInt64, _ mem: UInt64, _ dir: UInt64, _ off: UInt64 = 0, _ len: UInt64 = 4096,
      _ isa: CallISA = .x64
    ) -> CallResult {
      withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 5) {
        switch dispatchCall(
          isa: isa, savedPC: isa == .rv64 ? 0x1000 : 0x1000 + isa.instructionWidth,
          libraryCode: 0x1000..<0x2000, userRange: 0..<0, number: TarwinCall.dmaBufferCreate,
          registers: .init(dom, mem, off, len, dir), scratch: $0, provider: &provider)
        {
        case .returned(let r): return r
        default:
          XCTFail()
          return CallResult(status: .max)
        }
      }
    }
    XCTAssertEqual(call(0, read, 1).code, 2)
    XCTAssertEqual(call(weak, read, 1).code, 4)
    XCTAssertEqual(call(foreign, read, 1).code, 70)
    XCTAssertEqual(call(domain, domain, 1).code, 3)
    XCTAssertEqual(call(domain, 0, 1).code, 2)
    XCTAssertEqual(call(domain, read, 2).code, 4)
    XCTAssertEqual(call(domain, write, 1).code, 4)
    XCTAssertEqual(call(domain, read, 3).code, 4)
    XCTAssertEqual(call(domain, both, 4).code, 1)
    XCTAssertEqual(call(domain, both, 1, 0, 0).code, 1)
    XCTAssertEqual(call(domain, both, 1, 1).code, 1)
    XCTAssertEqual(call(domain, both, 1, .max - 4095).code, 6)
    XCTAssertEqual(call(domain, both, 1, 4096, 8192).code, 6)
    XCTAssertEqual(backend.pins, 0)
    let ok: (UInt64, UInt64, UInt64) -> Bool = { _, _, _ in true }
    var unpinned: [UInt64] = []
    func finish(_ buffer: UnsafePointer<ObjectHeader>) {
      XCTAssertTrue(
        c.domain.retireBuffer(
          buffer.pointee, detach: ok, invalidate: ok, drainAtcs: ok, drainWrites: ok,
          releasePin: { unpinned.append($0); return true })
      )
      backend.free(buffer)
    }
    for (isa, mem, dir, access) in [
      (CallISA.x64, read, UInt64(1), DmaAccess.deviceRead),
      (.rv64, write, 2, .deviceWrite), (.aarch64, both, 3, .both),
    ] {
      let r = call(domain, mem, dir, 4096, 4096, isa)
      XCTAssertEqual(r.code, 0)
      XCTAssertEqual(r.second, 0x10000)
      XCTAssertEqual(backend.mapped.last, access)
      guard
        case .found(let pin) = c.process.handleReader.pinWithinEpoch(
          r.first, kind: TarwinKind.dmaBuffer, need: 512)
      else { return XCTFail() }
      XCTAssertEqual(pin.rights, 512)
      XCTAssertTrue(
        c.process.withHandles(tree: c.tree) { $0.close(r.first) { _ in XCTFail() } } == true)
      let n = backend.pins
      let s = backend.samples
      let collision = call(domain, mem, dir)
      XCTAssertEqual(collision.code, 24)
      XCTAssertEqual(collision.first | collision.second, 0)
      XCTAssertEqual(backend.samples - s, 16)
      XCTAssertEqual(backend.pins, n)
      pin.drop { header in
        XCTAssertFalse(
          c.domain.retireBuffer(
            header.pointee, detach: ok, invalidate: ok, drainAtcs: { _, _, _ in false },
            drainWrites: { _, _, _ in XCTFail(); return false },
            releasePin: { _ in XCTFail(); return false }))
        XCTAssertEqual(c.domain.count, 1)
        finish(header)
      }
    }
    backend.accept = false
    let failed = call(domain, read, 1)
    XCTAssertEqual(failed.code, 70)
    XCTAssertEqual(failed.first | failed.second, 0)
    XCTAssertEqual(c.domain.count, 1)
    backend.accept = true
    XCTAssertEqual(call(domain, read, 1).code, 24)
    XCTAssertTrue(c.domain.retire(backend.quarantineID!, ok, ok, ok, ok) {
      unpinned.append($0); return true
    })
    backend.next = nil
    XCTAssertEqual(call(domain, read, 1).code, 24)
    backend.next = 1
    let final = call(domain, both, 3)
    XCTAssertEqual(final.code, 0)
    XCTAssertEqual(final.second, 0x11000)
    limits.handlesPerProcess = 7
    XCTAssertTrue(c.tree.tighten(c.tree.root, to: limits))
    XCTAssertEqual(call(domain, read, 1).code, 33)
    c.registry.freeze()
    XCTAssertEqual(call(domain, read, 1).code, 70)
    XCTAssertTrue(c.process.requestExit(.init(.exited, code: 0), tree: c.tree) { _ in XCTFail() })
    XCTAssertEqual(call(domain, read, 1).code, 23)
    XCTAssertTrue(c.process.beginCleanup(invalidate: { _ in }, retire: finish))
    XCTAssertTrue(c.process.finishCleanup(tree: c.tree) { _ in })
    XCTAssertEqual(c.domain.count, 0)
    XCTAssertEqual(unpinned, [1, 2, 3, 4, 5])
  }
}
