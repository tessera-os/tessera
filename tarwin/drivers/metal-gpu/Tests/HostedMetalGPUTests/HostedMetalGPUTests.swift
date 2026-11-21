import HostedMetalGPU
import Metal
import Synchronization
import TarwinArchHosted
import TarwinGPU
import TarwinObject
import TarwinSyscall
import TvGpuGuest
import XCTest

@MainActor
private final class Accounting: HostedGPUAccounting {
  var admit = true
  var charged: UInt64 = 0

  func charge(_ allocation: inout GpuAllocation, client: UInt64) -> Bool {
    guard admit, client == 3 else { return false }
    charged += allocation.bytes
    return true
  }

  func release(_ allocation: inout GpuAllocation, client: UInt64) -> Bool {
    guard client == 3, allocation.bytes <= charged else { return false }
    charged -= allocation.bytes
    return true
  }
}

private struct Scheduler: FenceScheduler {
  var wakes = 0
  mutating func park(_ ticket: FenceTicket) {}
  mutating func wake(_ ticket: FenceTicket, _ reason: FenceWake) { wakes += 1 }
  mutating func donate(fence: UInt64, priority: UInt32) {}
}

@MainActor
private final class KernelFence: HostedFenceSink {
  private let header: UnsafeMutablePointer<ObjectHeader>
  private let storage: UnsafeMutableBufferPointer<HandleCell>
  private let waiters: UnsafeMutableBufferPointer<FenceWait>
  private let word: UnsafeMutablePointer<Atomic<UInt64>>
  private var table: HandleTable
  private var fence: FenceObject
  private var scheduler = Scheduler()
  private let signalName, waitName: UInt64

  var value: UInt64 { word.pointee.load(ordering: .acquiring) }
  var wakes: Int { scheduler.wakes }

  init() {
    header = .allocate(capacity: 1)
    header.initialize(
      to: ObjectHeader(source: KoidSource(), ownerJob: 1, kind: TarwinKind.fence, maximumRights: 255)!)
    storage = .allocate(capacity: 2)
    table = HandleTable(storage: storage, salt: 18)!
    guard case .installed(let signal) = table.install(header, rights: 64),
      case .installed(let wait) = table.install(header, rights: 128)
    else { preconditionFailure("test fence rights not installed") }
    signalName = signal
    waitName = wait
    waiters = .allocate(capacity: 2)
    waiters.initialize(repeating: FenceWait(key: 0, target: 0, priority: 0))
    word = .allocate(capacity: 1)
    word.initialize(to: Atomic(0))
    fence = FenceObject(header: header, word: word, waiters: waiters)!
  }

  func wait(_ value: UInt64) -> FenceReply {
    fence.invoke(
      number: TarwinCall.fenceWait, name: waitName, value: value, priority: 0,
      table: table.reader, scheduler: &scheduler, retire: { _ in XCTFail("retired too early") })
  }

  func signal(_ value: UInt64) -> Bool {
    HostedRenderFence.signal(
      value, on: &fence, name: signalName, table: table.reader, scheduler: &scheduler,
      retire: { _ in XCTFail("retired too early") })
  }

  func disconnect() {
    fence.disconnect(scheduler: &scheduler, retire: { _ in XCTFail("retired too early") })
  }

  func close() {
    disconnect()
    table.drain { _ in XCTFail("retired too early") }
    XCTAssertEqual(header.pointee.release(), .destroy)
    header.deinitialize(count: 1)
    header.deallocate()
    storage.deinitialize()
    storage.deallocate()
    waiters.deinitialize()
    waiters.deallocate()
    word.deinitialize(count: 1)
    word.deallocate()
  }
}

final class HostedMetalGPUTests: XCTestCase {
  func testRegistersHostedDeviceKindsAndChecksReturnedRights() throws {
    let registry = HostDeviceRegistry()
    final class Service: Sendable {
      let inbox: HostPort
      init() throws { inbox = try HostPort.receive() }
    }
    let service = try Service()
    registry.register(HostedGraphicsDeviceProvider(kind: .metalGPU) { slot in
      guard slot == 1 else { throw HostError("open test slot", code: KERN_INVALID_NAME) }
      return try service.inbox.makeSend()
    })
    registry.register(HostedGraphicsDeviceProvider(kind: .macDisplay) { _ in try HostPort.receive() })
    XCTAssertNotNil(registry.lookup(kind: "gpu"))
    XCTAssertNotNil(registry.lookup(kind: "display"))
    let port = try HostedGraphicsDeviceProvider.Kind.metalGPU.open(in: registry, slot: 1)
    XCTAssertEqual(port.kind, .send)
    XCTAssertEqual(port.rawName, service.inbox.rawName)
    do {
      _ = try HostedGraphicsDeviceProvider.Kind.metalGPU.open(in: registry, slot: 2)
      XCTFail("unbound slot opened")
    } catch let error as HostError {
      XCTAssertEqual(error.code, KERN_INVALID_NAME)
    }
    do {
      _ = try HostedGraphicsDeviceProvider.Kind.macDisplay.open(in: registry, slot: 1)
      XCTFail("receive right escaped the display provider")
    } catch let error as HostError {
      XCTAssertEqual(error.code, KERN_INVALID_RIGHT)
    }
  }

  @MainActor
  func testChargedRenderFenceReleaseAndPresentationAreSeparate() async throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let accounting = Accounting()
    let gpu = try XCTUnwrap(HostedMetalGPU(device: device, accounting: accounting))
    let sink = KernelFence()
    defer { sink.close() }

    func register() -> (MosaicGrant, HostedRenderFence)? {
      gpu.register(client: 3, compositor: 7, epoch: 9, surface: 5, width: 15, height: 16, fence: sink)
    }
    accounting.admit = false
    XCTAssertNil(register())
    XCTAssertEqual(accounting.charged, 0)
    accounting.admit = true
    let (grant, fence) = try XCTUnwrap(register())
    XCTAssertGreaterThan(accounting.charged, 15 * 16 * 4)

    func mode(_ generation: UInt64) throws -> HostedOutputMode {
      try XCTUnwrap(
        HostedOutputMode(output: 1, generation: generation, width: 32, height: 24, scale: 1, refreshHz: 60))
    }
    XCTAssertTrue(gpu.configure(try mode(1), compositor: 7))
    var lane = MetalPresentationLane(grant)
    guard case .parked = sink.wait(1) else { return XCTFail("Fence wait did not park") }
    let command = try XCTUnwrap(lane.present(
      by: 3, epoch: 9, now: 1, deadline: 5, operation: .clear(0xff12_34ab), canRead: { _ in false },
      submit: { gpu.submit($0, client: 3, surface: 5, now: 1, deadline: 5) }))
    XCTAssertEqual(fence.completedValue, 0)
    XCTAssertEqual(sink.value, 0)
    let placement = HostedPlacement(client: 3, command: command, x: 1, y: 2)
    XCTAssertFalse(gpu.compose(output: 1, generation: 1, compositor: 7, placements: [placement]))
    let render = try await poll { gpu.pollRenders().first }
    XCTAssertEqual(render.phase, .rendered)
    XCTAssertTrue(lane.complete(render.bytes))
    XCTAssertFalse(lane.reusable)
    XCTAssertEqual(fence.completedValue, 1)
    XCTAssertEqual(sink.value, 1)
    XCTAssertEqual(sink.wakes, 1)

    XCTAssertTrue(gpu.compose(output: 1, generation: 1, compositor: 7, placements: [placement]))
    let copy = try await poll { gpu.collect(output: 1) }
    XCTAssertEqual(copy.receipts.map(\.phase), [.released])
    XCTAssertTrue(lane.complete(try XCTUnwrap(copy.receipts.first).bytes))
    XCTAssertTrue(lane.reusable)
    XCTAssertNil(gpu.hit(output: 1, generation: 1, x: 2, y: 3))
    let old = try XCTUnwrap(copy.frame).id
    XCTAssertTrue(gpu.configure(try mode(2), compositor: 7))
    XCTAssertFalse(gpu.configure(try mode(1), compositor: 7))
    XCTAssertFalse(gpu.finishPresentation(.presented(old, time: 1)))
    XCTAssertNil(gpu.hit(output: 1, generation: 2, x: 2, y: 3))
    XCTAssertEqual(sink.value, 1)
    XCTAssertTrue(gpu.retireSurface(client: 3, surface: 5, epoch: 9))
    XCTAssertEqual(accounting.charged, 0)
    XCTAssertNil(register())
    XCTAssertEqual(sink.wait(2), .deviceRemoved)
  }

  @MainActor
  private func poll<T>(_ body: () -> T?) async throws -> T {
    let end = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < end {
      if let result = body() { return result }
      try await Task.sleep(for: .milliseconds(2))
    }
    return try XCTUnwrap(nil as T?, "Metal operation timed out")
  }
}
