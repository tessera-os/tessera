import AppKit
import Metal
import QuartzCore
import IOSurface
import TesseraHostKit

final class DisplayView: NSView {
    let metal = CAMetalLayer()
    let device = MTLCreateSystemDefaultDevice()!
    lazy var queue = device.makeCommandQueue()!
    var output: DisplayOutput
    var send: ((HostEvent) -> Void)?
    var resized: ((DisplayOutput) -> Void)?
    var rawEvent: ((NSEvent, CGSize) -> Void)?
    let console = NSTextField(wrappingLabelWithString: "Starting Tessera…")
    init(output: DisplayOutput) {
        self.output = output
        super.init(frame: NSRect(x: 0, y: 0, width: output.width, height: output.height))
        wantsLayer = true; metal.device = device; metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = false; layer = metal
        console.textColor = .white; console.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        console.backgroundColor = NSColor.black.withAlphaComponent(0.8); console.drawsBackground = true
        addSubview(console)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout(); metal.drawableSize = CGSize(width: bounds.width, height: bounds.height)
        console.frame = bounds.insetBy(dx: 24, dy: 24)
        output.width = Int(bounds.width); output.height = Int(bounds.height)
        output.scale = Double(window?.backingScaleFactor ?? 1)
        resized?(output)
    }
    func present(_ surface: IOSurface) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: surface.width, height: surface.height, mipmapped: false)
        descriptor.usage = [.shaderRead]; descriptor.storageMode = .shared
        guard let source = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
              let drawable = metal.nextDrawable(), let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: min(source.width, drawable.texture.width),
                                      height: min(source.height, drawable.texture.height), depth: 1),
                  to: drawable.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding(); command.addCompletedHandler { _ in _ = surface }
        command.present(drawable); command.commit()
    }
    func forward(_ event: NSEvent) {
        rawEvent?(event, bounds.size)
    }
    override func keyDown(with event: NSEvent) { forward(event) }
    override func keyUp(with event: NSEvent) { forward(event) }
    override func flagsChanged(with event: NSEvent) { forward(event) }
    private func pointer(_ event: NSEvent, kind: String) {
        forward(event)
        let point = convert(event.locationInWindow, from: nil)
        send?(HostEvent(kind: kind, x: point.x, y: point.y))
    }
    override func mouseMoved(with event: NSEvent) { pointer(event, kind: "pointer") }
    override func mouseDragged(with event: NSEvent) { pointer(event, kind: "pointer") }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, kind: "pointerDown") }
    override func mouseUp(with event: NSEvent) { pointer(event, kind: "pointerUp") }
    override func scrollWheel(with event: NSEvent) { forward(event) }
}
