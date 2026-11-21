import AppKit
import HostedMetalGPU
@testable import MacDisplay
import Metal
import TarwinGPU
import TvGpuGuest
import XCTest

@MainActor
private final class Probe: MacDisplayTransport, HostedGPUAccounting, HostedFenceSink {
  private(set) var mode: HostedOutputMode?
  private(set) var update: MacDisplayTiming?
  private(set) var results: [HostedPresentation] = []
  private var charged: UInt64 = 0

  func modeChanged(_ mode: HostedOutputMode) { self.mode = mode }
  func outputRemoved(_ output: UInt64, generation: UInt64) { mode = nil }
  func timing(_ update: MacDisplayTiming) { self.update = update }
  func presentationFinished(_ result: HostedPresentation) { results.append(result) }

  func charge(_ allocation: inout GpuAllocation, client: UInt64) -> Bool {
    guard allocation.bytes + charged <= 1_048_576 else { return false }
    charged += allocation.bytes
    return true
  }

  func release(_ allocation: inout GpuAllocation, client: UInt64) -> Bool {
    charged -= allocation.bytes
    return true
  }

  func signal(_ value: UInt64) -> Bool { true }
  func disconnect() {}
}

final class PresentationTests: XCTestCase {
  @MainActor
  func testMetalCompositionPresentsInNSWindowAndResizeRejectsStaleFrame() async throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let probe = Probe()
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let gpu = try XCTUnwrap(HostedMetalGPU(device: device, accounting: probe))
    let output = try XCTUnwrap(MacDisplayOutput(id: 11, device: device, transport: probe))
    let window = NSWindow(
      contentRect: NSRect(x: 20, y: 20, width: 240, height: 180),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = output.makeView()
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate()
    defer {
      output.stop()
      window.close()
    }

    let mode = try await poll("No window mode") { probe.mode }
    let timing = try await poll("CAMetalDisplayLink did not publish timing") { probe.update }
    XCTAssertEqual(timing.generation, mode.generation)
    XCTAssertEqual(timing.output, mode.output)
    XCTAssertGreaterThan(timing.deadline, 0)
    XCTAssertGreaterThanOrEqual(timing.targetPresentation, timing.deadline)
    XCTAssertTrue(gpu.configure(mode, compositor: 7))

    let (grant, _) = try XCTUnwrap(gpu.register(
      client: 3, compositor: 7, epoch: 1, surface: 5, width: 24, height: 24, fence: probe))
    var lane = MetalPresentationLane(grant)
    let now = mach_absolute_time()
    let deadline = max(now + 1, timing.deadline)
    let command = try XCTUnwrap(lane.present(
      by: 3, epoch: 1, now: now, deadline: deadline, operation: .clear(0xff1c_cb70),
      canRead: { _ in false },
      submit: { gpu.submit($0, client: 3, surface: 5, now: now, deadline: deadline) }))
    let render = try await poll("Surface render did not complete") { gpu.pollRenders().first }
    XCTAssertEqual(render.phase, .rendered)
    XCTAssertTrue(lane.complete(render.bytes))
    XCTAssertFalse(lane.reusable)
    let placement = HostedPlacement(client: 3, command: command, x: 8, y: 9)
    XCTAssertTrue(gpu.compose(
      output: mode.output, generation: mode.generation, compositor: 7, placements: [placement]))
    let copy = try await poll("Composition did not complete") { gpu.collect(output: mode.output) }
    let frame = try XCTUnwrap(copy.frame)
    XCTAssertTrue(lane.complete(try XCTUnwrap(copy.receipts.first).bytes))
    XCTAssertTrue(lane.reusable)
    XCTAssertNil(gpu.hit(output: mode.output, generation: mode.generation, x: 8, y: 9))

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: mode.width, height: mode.height, mipmapped: false)
    descriptor.storageMode = .shared
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor, iosurface: frame.surface, plane: 0))
    func color(_ x: Int, _ y: Int, in texture: any MTLTexture) -> UInt32 {
      var value: UInt32 = 0
      texture.getBytes(&value, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
      return value
    }
    XCTAssertEqual(color(0, 0, in: texture), 0xff00_0000)
    XCTAssertEqual(color(8, 9, in: texture), 0xff1c_cb70)
    XCTAssertEqual(color(31, 32, in: texture), 0xff1c_cb70)
    XCTAssertEqual(color(32, 32, in: texture), 0xff00_0000)

    let readbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: 33, height: 33, mipmapped: false)
    readbackDescriptor.storageMode = .shared
    let readback = try XCTUnwrap(device.makeTexture(descriptor: readbackDescriptor))
    output.inspectDrawable = { blit, drawable in
      blit.copy(
        from: drawable, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
        sourceSize: MTLSize(width: 33, height: 33, depth: 1),
        to: readback, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
    }

    XCTAssertTrue(output.receive(frame))
    XCTAssertFalse(output.receive(frame))
    let result = try await poll("Drawable never presented") { probe.results.first }
    output.inspectDrawable = nil
    XCTAssertEqual(color(0, 0, in: readback), 0xff00_0000)
    XCTAssertEqual(color(8, 9, in: readback), 0xff1c_cb70)
    XCTAssertEqual(color(31, 32, in: readback), 0xff1c_cb70)
    XCTAssertEqual(color(32, 32, in: readback), 0xff00_0000)
    let presentationSkipReason: String?
    if let screen = window.screen?.localizedName {
      if screen.localizedCaseInsensitiveContains("virtual") {
        presentationSkipReason = "the window is on a virtual display (\(screen))"
      } else if !window.occlusionState.contains(.visible) {
        presentationSkipReason = "the window is not visible on \(screen)"
      } else {
        presentationSkipReason = nil
      }
    } else {
      presentationSkipReason = "the window has no screen"
    }
    switch result {
    case .presented(let id, let time):
      XCTAssertEqual(id, frame.id)
      if presentationSkipReason == nil { XCTAssertGreaterThan(time, 0) }
      XCTAssertTrue(gpu.finishPresentation(result))
      XCTAssertEqual(gpu.hit(output: mode.output, generation: mode.generation, x: 8, y: 9)?.surface, 5)
      print("CAMetalDrawable presented generation \(id.generation), frame \(id.serial), host time \(time)")
    case .discarded(let id):
      XCTAssertEqual(id, frame.id)
      XCTAssertNotNil(
        presentationSkipReason, "Visible physical display discarded drawable without presentation evidence")
      XCTAssertTrue(gpu.finishPresentation(result))
      XCTAssertNil(gpu.hit(output: mode.output, generation: mode.generation, x: 8, y: 9))
    }

    window.setContentSize(NSSize(width: 280, height: 200))
    let resized = try await poll("Resize did not publish a generation") {
      guard let candidate = probe.mode, candidate.generation > mode.generation else { return nil as HostedOutputMode? }
      return candidate
    }
    XCTAssertNotEqual(resized.width, mode.width)
    XCTAssertTrue(gpu.configure(resized, compositor: 7))
    XCTAssertFalse(output.receive(frame))
    XCTAssertEqual(probe.results.last, .discarded(frame.id))
    XCTAssertFalse(gpu.finishPresentation(result))
    XCTAssertNil(gpu.hit(output: mode.output, generation: mode.generation, x: 8, y: 9))
    print("NSWindow composed pixels and resize generation verified")
    if let presentationSkipReason {
      throw XCTSkip("Physical presentedTime evidence unavailable: \(presentationSkipReason); pixels and resize checked")
    }
  }

  @MainActor
  private func poll<T>(_ message: String, _ body: () -> T?) async throws -> T {
    let limit = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < limit {
      if let result = body() { return result }
      try await Task.sleep(for: .milliseconds(5))
    }
    return try XCTUnwrap(nil as T?, message)
  }
}
