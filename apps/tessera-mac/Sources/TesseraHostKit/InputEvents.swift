import AppKit
import MacHIDCapture

@MainActor public enum InputEvents {
    public static func translate(_ event: NSEvent, using translator: HIDEventTranslator, windowSize: CGSize) {
        translator.translate(event.type == .pressure ? PressurePoint(event) : event, windowSize: windowSize)
    }
}

private final class PressurePoint: NSEvent {
    let original: NSEvent
    init(_ original: NSEvent) { self.original = original; super.init() }
    required init?(coder: NSCoder) { nil }
    override var type: NSEvent.EventType { .tabletPoint }
    override var locationInWindow: NSPoint { original.locationInWindow }
    override var pressure: Float { original.pressure }
    override var tilt: NSPoint { .zero }
    override var rotation: Float { 0 }
}
