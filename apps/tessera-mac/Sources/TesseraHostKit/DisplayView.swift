import AppKit
import IOSurface

public final class ConsoleOverlay: NSTextField {
    public override var acceptsFirstResponder: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

public final class DisplayView: NSView {
    public let display: PreviewDisplay?
    private let displayView: NSView?
    public var output: DisplayOutput
    public var rawEvent: ((NSEvent, CGSize) -> Void)?
    public let console = ConsoleOverlay(wrappingLabelWithString: "Starting Tessera…")
    public init(output: DisplayOutput, displayEvent: @escaping (Data) -> Void = { _ in }) {
        self.output = output
        display = PreviewDisplay(id: output.id, send: displayEvent)
        displayView = display?.makeView()
        super.init(frame: NSRect(x: 0, y: 0, width: output.width, height: output.height))
        if let displayView { addSubview(displayView) }
        console.textColor = .white; console.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        console.backgroundColor = NSColor.black.withAlphaComponent(0.8); console.drawsBackground = true
        console.isEditable = false; console.isSelectable = false
        addSubview(console)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self))
    }
    public required init?(coder: NSCoder) { fatalError() }
    public override var acceptsFirstResponder: Bool { true }
    public override func layout() {
        super.layout(); displayView?.frame = bounds
        console.frame = bounds.insetBy(dx: 24, dy: 24)
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
