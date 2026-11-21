import AppKit
import Metal
import QuartzCore
import IOSurface

public final class ConsoleOverlay: NSTextField {
    public override var acceptsFirstResponder: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

public final class DisplayView: NSView {
    let metal = CAMetalLayer()
    let device = MTLCreateSystemDefaultDevice()!
    lazy var queue = device.makeCommandQueue()!
    public var output: DisplayOutput
    public var resized: ((DisplayOutput) -> Void)?
    public var rawEvent: ((NSEvent, CGSize) -> Void)?
    public let console = ConsoleOverlay(wrappingLabelWithString: "Starting Tessera…")
    public init(output: DisplayOutput) {
        self.output = output
        super.init(frame: NSRect(x: 0, y: 0, width: output.width, height: output.height))
        wantsLayer = true; metal.device = device; metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = false; layer = metal
        console.textColor = .white; console.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        console.backgroundColor = NSColor.black.withAlphaComponent(0.8); console.drawsBackground = true
        console.isEditable = false; console.isSelectable = false
        addSubview(console)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self))
    }
    public required init?(coder: NSCoder) { fatalError() }
    public override var acceptsFirstResponder: Bool { true }
    public override func layout() {
        super.layout(); metal.drawableSize = CGSize(width: bounds.width, height: bounds.height)
        console.frame = bounds.insetBy(dx: 24, dy: 24)
        output.width = Int(bounds.width); output.height = Int(bounds.height)
        output.scale = Double(window?.backingScaleFactor ?? 1)
        resized?(output)
    }
    public func present(_ surface: IOSurface) {
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
    public override func keyDown(with event: NSEvent) { forward(event) }
    public override func keyUp(with event: NSEvent) { forward(event) }
    public override func flagsChanged(with event: NSEvent) { forward(event) }
    public override func mouseMoved(with event: NSEvent) { forward(event) }
    public override func mouseDragged(with event: NSEvent) { forward(event) }
    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); forward(event) }
    public override func mouseUp(with event: NSEvent) { forward(event) }
    public override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); forward(event) }
    public override func rightMouseUp(with event: NSEvent) { forward(event) }
    public override func rightMouseDragged(with event: NSEvent) { forward(event) }
    public override func otherMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); forward(event) }
    public override func otherMouseUp(with event: NSEvent) { forward(event) }
    public override func otherMouseDragged(with event: NSEvent) { forward(event) }
    public override func scrollWheel(with event: NSEvent) { forward(event) }
    public override func magnify(with event: NSEvent) { forward(event) }
    public override func rotate(with event: NSEvent) { forward(event) }
    public override func swipe(with event: NSEvent) { forward(event) }
    public override func smartMagnify(with event: NSEvent) { forward(event) }
    public override func tabletPoint(with event: NSEvent) { forward(event) }
    public override func tabletProximity(with event: NSEvent) { forward(event) }
    public override func pressureChange(with event: NSEvent) { forward(event) }
}
