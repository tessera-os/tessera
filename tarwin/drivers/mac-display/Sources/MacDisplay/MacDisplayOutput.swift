import AppKit
import HostedMetalGPU
import Metal
import QuartzCore

public struct MacDisplayTiming: Sendable {
  public let output, generation: UInt64
  public let deadline, targetPresentation: UInt64
}

@MainActor
public protocol MacDisplayTransport: AnyObject {
  func modeChanged(_ mode: HostedOutputMode)
  func outputRemoved(_ output: UInt64, generation: UInt64)
  func timing(_ update: MacDisplayTiming)
  func presentationFinished(_ result: HostedPresentation)
}

@MainActor
public final class MacDisplayOutput: NSObject, @preconcurrency CAMetalDisplayLinkDelegate {
  public let id: UInt64
  public let layer: CAMetalLayer
  public private(set) var mode: HostedOutputMode?
  var inspectDrawable: ((any MTLBlitCommandEncoder, any MTLTexture) -> Void)?
  private let queue: any MTLCommandQueue
  private weak var transport: (any MacDisplayTransport)?
  private var link: CAMetalDisplayLink?
  private var pending: HostedOutputFrame?
  private lazy var presentation = PresentationTracker { [weak self] result in
    self?.transport?.presentationFinished(result)
  }
  private var generation: UInt64 = 0
  private var highestSerial: UInt64 = 0

  public init?(id: UInt64, device: any MTLDevice, transport: any MacDisplayTransport) {
    guard id > 0, let queue = device.makeCommandQueue() else { return nil }
    self.id = id
    self.queue = queue
    self.transport = transport
    layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.isOpaque = true
    super.init()
  }

  public func makeView() -> NSView { OutputView(output: self) }

  public func start() {
    guard link == nil else { return }
    let displayLink = CAMetalDisplayLink(metalLayer: layer)
    displayLink.delegate = self
    displayLink.preferredFrameLatency = 2
    displayLink.add(to: .main, forMode: .common)
    link = displayLink
  }

  public func stop() {
    link?.invalidate()
    link = nil
    guard let mode else { return }
    self.mode = nil
    discardStaleFrames()
    transport?.outputRemoved(id, generation: mode.generation)
  }

  @discardableResult
  public func updateMode(width: Int, height: Int, scale: Double, refreshHz: Int) -> Bool {
    if let mode, mode.width == width, mode.height == height, mode.scale == scale,
      mode.refreshHz == refreshHz
    {
      return true
    }
    guard generation < .max, let next = HostedOutputMode(
      output: id, generation: generation + 1, width: width, height: height,
      scale: scale, refreshHz: refreshHz)
    else { return false }
    generation = next.generation
    highestSerial = 0
    mode = next
    layer.contentsScale = scale
    layer.drawableSize = CGSize(width: width, height: height)
    discardStaleFrames()
    transport?.modeChanged(next)
    return true
  }

  @discardableResult
  public func receive(_ frame: HostedOutputFrame) -> Bool {
    if pending?.id == frame.id || presentation.inFlight == frame.id { return false }
    guard let mode, frame.id.output == id, frame.id.generation == mode.generation,
      frame.id.serial > highestSerial, pending == nil, presentation.inFlight == nil,
      frame.surface.width == mode.width, frame.surface.height == mode.height,
      frame.surface.pixelFormat == 0x42475241, frame.surface.planeCount == 0,
      frame.surface.bytesPerElement == 4
    else {
      transport?.presentationFinished(.discarded(frame.id))
      return false
    }
    highestSerial = frame.id.serial
    pending = frame
    return true
  }

  public func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
    guard link === self.link, let mode else { return }
    if let deadline = Self.hostTicks(update.targetTimestamp),
      let presentation = Self.hostTicks(update.targetPresentationTimestamp)
    {
      transport?.timing(
        MacDisplayTiming(
          output: id, generation: mode.generation, deadline: deadline,
          targetPresentation: presentation))
    }
    guard self.mode == mode, let frame = pending else { return }
    let drawable = update.drawable
    guard drawable.texture.width == mode.width, drawable.texture.height == mode.height
    else { return }
    pending = nil
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: mode.width, height: mode.height, mipmapped: false)
    descriptor.storageMode = .shared
    guard let source = queue.device.makeTexture(descriptor: descriptor, iosurface: frame.surface, plane: 0),
      let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder()
    else {
      transport?.presentationFinished(.discarded(frame.id))
      return
    }
    blit.copy(from: source, to: drawable.texture)
    inspectDrawable?(blit, drawable.texture)
    blit.endEncoding()

    presentation.begin(frame.id, events: MetalPresentationEvents(buffer: buffer, drawable: drawable))
    buffer.commit()
    drawable.present()
  }

  private func discardStaleFrames() {
    if let frame = pending {
      pending = nil
      transport?.presentationFinished(.discarded(frame.id))
    }
    presentation.setGeneration(mode?.generation)
  }

  private static func hostTicks(_ time: Double) -> UInt64? {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer != 0 else { return nil }
    let ticks = time * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
    guard ticks.isFinite, ticks >= 1, ticks < Double(UInt64.max) else { return nil }
    return UInt64(ticks)
  }
}

@MainActor
private final class OutputView: NSView {
  private weak var output: MacDisplayOutput?

  init(output: MacDisplayOutput) {
    self.output = output
    super.init(frame: .zero)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  override func makeBackingLayer() -> CALayer { output?.layer ?? super.makeBackingLayer() }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
    guard let window else {
      output?.stop()
      return
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(refreshMode), name: NSWindow.didChangeScreenNotification, object: window)
    refreshMode()
    output?.start()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    refreshMode()
  }

  override func layout() {
    super.layout()
    refreshMode()
  }

  @objc private func refreshMode() {
    guard let window else { return }
    let pixels = convertToBacking(bounds).size
    guard pixels.width.isFinite, pixels.height.isFinite,
      (1...16384).contains(pixels.width), (1...16384).contains(pixels.height)
    else { return }
    let refresh = window.screen?.maximumFramesPerSecond ?? 60
    output?.updateMode(
      width: Int(pixels.width.rounded()), height: Int(pixels.height.rounded()),
      scale: window.backingScaleFactor, refreshHz: refresh > 0 ? refresh : 60)
  }
}
