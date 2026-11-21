import AppKit
import HostedMetalGPU
import MacDisplay
import Metal
import TarwinGPU
import TvGpuGuest

@MainActor
private final class DemoAccounting: HostedGPUAccounting {
  private var charged: [UInt64: UInt64] = [:]

  func charge(_ allocation: inout GpuAllocation, client: UInt64) -> Bool {
    guard client == 1, charged[allocation.id] == nil,
      charged.values.reduce(0, +) + allocation.bytes <= 64 * 1024 * 1024
    else { return false }
    charged[allocation.id] = allocation.bytes
    return true
  }

  func release(_ allocation: inout GpuAllocation, client: UInt64) -> Bool {
    client == 1 && charged.removeValue(forKey: allocation.id) == allocation.bytes
  }
}

@MainActor
private final class DemoFence: HostedFenceSink {
  func signal(_ value: UInt64) -> Bool { true }
  func disconnect() {}
}

@MainActor
@main
private final class Demo: NSObject, NSApplicationDelegate, MacDisplayTransport {
  private let gpu: HostedMetalGPU
  private var output: MacDisplayOutput?
  private var window: NSWindow?
  private var mode: HostedOutputMode?
  private var sceneGeneration: UInt64 = 0
  private var active: UInt64?
  private var placements: [HostedPlacement] = []
  private var ready = 0
  private var copying = false
  private var configuredSurfaces: [MosaicGrant] = []

  static func main() {
    guard let device = MTLCreateSystemDefaultDevice(),
      let gpu = HostedMetalGPU(device: device, accounting: DemoAccounting())
    else { print("A Metal device is required"); return }
    let app = NSApplication.shared
    let demo = Demo(gpu: gpu)
    app.setActivationPolicy(.regular)
    app.delegate = demo
    withExtendedLifetime(demo) { app.run() }
  }

  init(gpu: HostedMetalGPU) { self.gpu = gpu }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let output = MacDisplayOutput(id: 1, device: gpu.device, transport: self) else { return }
    self.output = output
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 450),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "Tarwin Hosted — Metal Mosaic"
    window.contentMinSize = NSSize(width: 160, height: 100)
    window.contentView = output.makeView()
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate()
    self.window = window
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func modeChanged(_ mode: HostedOutputMode) {
    if gpu.configure(mode, compositor: 7) { self.mode = mode }
  }

  func outputRemoved(_ output: UInt64, generation: UInt64) {
    gpu.removeOutput(output, generation: generation)
    mode = nil
  }

  func presentationFinished(_ result: HostedPresentation) {
    if gpu.finishPresentation(result), case .presented(let id, let time) = result {
      print("Presented generation \(id.generation), frame \(id.serial) at \(time)")
      sceneGeneration = id.generation
    }
    active = nil
  }

  func timing(_ update: MacDisplayTiming) {
    ready += gpu.pollRenders().filter { $0.phase == .rendered }.count
    if copying {
      guard let result = gpu.collect(output: update.output) else { return }
      copying = false
      if let frame = result.frame {
        _ = output?.receive(frame)
      } else {
        active = nil
      }
      return
    }
    guard let mode, mode.generation == update.generation, mode.generation != sceneGeneration
    else { return }
    if let generation = active {
      guard !placements.isEmpty, ready >= placements.count else { return }
      if generation == mode.generation,
        gpu.compose(output: mode.output, generation: generation, compositor: 7, placements: placements)
      {
        copying = true
      } else {
        active = nil
      }
      placements.removeAll()
      return
    }
    configuredSurfaces.removeAll {
      gpu.retireSurface(client: $0.client, surface: $0.surface, epoch: $0.epoch)
    }
    guard configuredSurfaces.isEmpty else { return }
    let now = mach_absolute_time()
    guard now < update.deadline else { return }
    ready = 0
    let panels: [(Double, Double, Double, Double, UInt32)] = [
      (0.04, 0.06, 0.92, 0.88, 0xff19_2941),
      (0.10, 0.15, 0.56, 0.57, 0xff32_76b6),
      (0.36, 0.31, 0.53, 0.51, 0xff29_bda7),
      (0.16, 0.68, 0.23, 0.18, 0xfff7_bc62),
    ]
    for (index, panel) in panels.enumerated() {
      let (x, y, w, h, color) = panel
      guard let (grant, _) = gpu.register(
        client: 1, compositor: 7, epoch: mode.generation, surface: UInt64(index + 1),
        width: UInt32(Double(mode.width) * w), height: UInt32(Double(mode.height) * h),
        fence: DemoFence())
      else { continue }
      configuredSurfaces.append(grant)
      var lane = MetalPresentationLane(grant)
      if let command = lane.present(
        by: grant.client, epoch: grant.epoch, now: now, deadline: update.deadline,
        operation: .clear(color), canRead: { _ in false },
        submit: {
          gpu.submit(
            $0, client: grant.client, surface: grant.surface, now: now, deadline: update.deadline)
        })
      {
        placements.append(
          HostedPlacement(
            client: grant.client, command: command, x: Int32(Double(mode.width) * x),
            y: Int32(Double(mode.height) * y)))
      }
    }
    if !placements.isEmpty { active = mode.generation }
  }
}
