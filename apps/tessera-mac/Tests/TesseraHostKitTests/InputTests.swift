import AppKit
import XCTest
import MacHIDCapture
@testable import TesseraHostKit

private final class InputEvent: NSEvent {
    let eventType: NSEvent.EventType
    init(_ type: NSEvent.EventType) { eventType = type; super.init() }
    required init?(coder: NSCoder) { nil }
    override var type: NSEvent.EventType { eventType }
    override var locationInWindow: NSPoint { NSPoint(x: 50, y: 25) }
    override var buttonNumber: Int { eventType == .rightMouseDown || eventType == .rightMouseUp ? 1 : 2 }
    override var deltaX: CGFloat { 2 }
    override var deltaY: CGFloat { 3 }
    override var magnification: CGFloat { 0.25 }
    override var rotation: Float { 15 }
    override var phase: NSEvent.Phase { .changed }
    override var momentumPhase: NSEvent.Phase { [] }
    override var pressure: Float { 0.5 }
    override var tilt: NSPoint { .zero }
    override var isEnteringProximity: Bool { true }
}

final class InputTests: XCTestCase {
    @MainActor func testEachViewOverrideForwardsExactlyOneFrame() {
        _ = NSApplication.shared
        let view = DisplayView(output: DisplayOutput(width: 100, height: 100))
        var frames: [Data] = []
        let translator = HIDEventTranslator(channel: DeviceFrameChannel { frames.append($0) })
        translator.setFocused(true)
        view.rawEvent = { InputEvents.translate($0, using: translator, windowSize: $1) }
        let cases: [(NSEvent.EventType, (NSEvent) -> Void)] = [
            (.mouseMoved, view.mouseMoved), (.leftMouseDown, view.mouseDown), (.leftMouseUp, view.mouseUp),
            (.leftMouseDragged, view.mouseDragged), (.rightMouseDown, view.rightMouseDown),
            (.rightMouseUp, view.rightMouseUp), (.rightMouseDragged, view.rightMouseDragged),
            (.otherMouseDown, view.otherMouseDown), (.otherMouseUp, view.otherMouseUp),
            (.otherMouseDragged, view.otherMouseDragged), (.magnify, view.magnify),
            (.rotate, view.rotate), (.swipe, view.swipe), (.smartMagnify, view.smartMagnify),
            (.tabletPoint, view.tabletPoint), (.tabletProximity, view.tabletProximity), (.pressure, view.pressureChange)
        ]
        for (type, handle) in cases {
            frames.removeAll(); handle(InputEvent(type))
            XCTAssertEqual(frames.count, 1, "\(type)")
        }
        translator.setFocused(false); frames.removeAll()
        view.mouseMoved(with: InputEvent(.mouseMoved))
        XCTAssertTrue(frames.isEmpty)
    }
    @MainActor func testConsoleCannotInterceptMouseOrKeyboard() {
        _ = NSApplication.shared
        let view = DisplayView(output: DisplayOutput())
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.console.isEditable); XCTAssertFalse(view.console.isSelectable)
        XCTAssertFalse(view.console.acceptsFirstResponder)
        XCTAssertNil(view.console.hitTest(.zero))
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertTrue(window.firstResponder === view)
        view.mouseDown(with: InputEvent(.leftMouseDown))
        XCTAssertTrue(window.firstResponder === view)
    }
    @MainActor func testDriverPointerAndOtherReportsSurviveKeyboardConsumption() throws {
        let devices = try HostedServiceDevices(registry: .init(), send: { _ in })
        let translator = HIDEventTranslator(channel: DeviceFrameChannel { try! devices.receive($0) })
        translator.setFocused(true)
        for type: NSEvent.EventType in [.mouseMoved, .magnify, .tabletPoint] {
            InputEvents.translate(InputEvent(type), using: translator, windowSize: CGSize(width: 100, height: 100))
        }
        let events = devices.inputEvents(output: DisplayOutput(width: 100, height: 100))
        XCTAssertEqual(events.filter { $0.kind.hasPrefix("hidReport.") }.count, 4)
        XCTAssertEqual(events.filter { $0.kind == "hidReport.4" }.count, 1)
        let pointer = try XCTUnwrap(events.first { $0.kind == "pointer" })
        XCTAssertEqual(pointer.x, 50, accuracy: 0.01); XCTAssertEqual(pointer.y, 25, accuracy: 0.01)
        XCTAssertTrue(devices.inputEvents(output: DisplayOutput()).isEmpty)
    }
}
