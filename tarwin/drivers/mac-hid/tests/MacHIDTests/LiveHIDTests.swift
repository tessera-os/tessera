import AppKit
import CoreGraphics
import XCTest
import HostedDeviceWire
import MacHIDCapture
import MacHIDDriver
import TarwinArchHosted

private let liveEventTag: Int64 = 0x54415257494e

private final class LiveMachChannel: HostedDeviceChannel {
  var onReceive: ((UnsafeRawBufferPointer) -> Void)?
  private let port: HostPort
  var failure: Error?
  var flags: [UInt16] = []
  init(port: consuming HostPort) { self.port = port }
  func send(frame: UnsafeRawBufferPointer) {
    flags.append(FrameView(frame)!.flags)
    do { try HostedDriverEndpoint.send(frame: frame, to: port) }
    catch { failure = error }
  }
  func close() { onReceive = nil }
}

@MainActor private final class LiveInputView: NSView {
  var translator: HIDEventTranslator?
  var events: [NSEvent] = []
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  private func receive(_ event: NSEvent) {
    guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) == liveEventTag else { return }
    events.append(event)
    translator?.translate(event, windowSize: bounds.size)
  }
  override func keyDown(with event: NSEvent) { receive(event) }
  override func keyUp(with event: NSEvent) { receive(event) }
  override func flagsChanged(with event: NSEvent) { receive(event) }
  override func mouseMoved(with event: NSEvent) { receive(event) }
  override func mouseDown(with event: NSEvent) { receive(event) }
  override func mouseUp(with event: NSEvent) { receive(event) }
  override func mouseDragged(with event: NSEvent) { receive(event) }
  override func scrollWheel(with event: NSEvent) { receive(event) }
}

final class LiveHIDTests: XCTestCase {
  @MainActor func testCGEventsThroughFocusedViewAndMachEndpoint() throws {
    guard ProcessInfo.processInfo.environment["TARWIN_HID_LIVE"] == "1" else { return }
    print("Live HID runner: \(ProcessInfo.processInfo.arguments[0])")
    guard CGPreflightPostEventAccess() else {
      XCTFail("Grant Accessibility/PostEvent access to the test runner before TARWIN_HID_LIVE=1")
      return
    }
    let ring = InputRing(capacity: 64)!
    let driver = MacHIDDriver(channel: LoopbackChannel(), ring: ring)
    let registry = HostDeviceRegistry()
    let provider = try MacHIDDeviceProvider(driver: driver)
    registry.register(provider)
    let registered = try XCTUnwrap(registry.lookup(kind: "hid"))
    let channel = LiveMachChannel(port: try registered.open(slot: 0))
    let translator = HIDEventTranslator(channel: channel)
    let app = NSApplication.shared
    XCTAssertTrue(app.setActivationPolicy(.regular))
    app.finishLaunching()
    let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 420, height: 280),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Tarwin live HID — CGEvent → NSEvent → Mach → InputRing"
    window.acceptsMouseMovedEvents = true
    let view = LiveInputView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    view.translator = translator
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    app.activate(ignoringOtherApps: true)
    defer {
      translator.setFocused(false)
      window.close()
      withExtendedLifetime((provider, registry, driver)) {}
    }
    func pump(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
      let deadline = Date(timeIntervalSinceNow: timeout)
      repeat {
        if condition() { return true }
        if let event = app.nextEvent(matching: .any,
          until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) {
          app.sendEvent(event)
        }
        app.updateWindows()
      } while Date() < deadline
      return condition()
    }
    guard pump(timeout: 3, until: { window.isKeyWindow && app.isActive }) else {
      XCTFail("The live HID window must be the real focused foreground window: key=\(window.isKeyWindow), active=\(app.isActive), policy=\(app.activationPolicy().rawValue), frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")")
      return
    }
    XCTAssertTrue(window.firstResponder === view)
    translator.setFocused(window.isKeyWindow && app.isActive)
    let start = HIDEventTranslator.nowNs()
    var lastTimestamp = start
    let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
    source.localEventsSuppressionInterval = 0
    let screenPoint = window.convertPoint(toScreen: NSPoint(x: 180, y: 120))
    let screen = try XCTUnwrap(NSScreen.screens.first)
    let point = CGPoint(x: screenPoint.x, y: screen.frame.maxY - screenPoint.y)

    func post(_ event: CGEvent, type: NSEvent.EventType, count: Int) throws -> [InputReportRecord] {
      let before = view.events.count
      event.setIntegerValueField(.eventSourceUserData, value: liveEventTag)
      event.post(tap: .cghidEventTap)
      guard pump(timeout: 3, until: { view.events.count > before }) else {
        XCTFail("Posted \(type) did not reach the focused NSView; check Accessibility permissions")
        throw NSError(domain: "LiveHID", code: 1)
      }
      XCTAssertEqual(view.events.count, before + 1)
      XCTAssertEqual(view.events.last?.type, type)
      XCTAssertNil(channel.failure)
      var reports: [InputReportRecord] = []
      XCTAssertTrue(pump(timeout: 2, until: {
        while let report = ring.pop() { reports.append(report) }
        return reports.count >= count
      }), "Mach endpoint must deliver every report for \(type)")
      XCTAssertEqual(reports.count, count)
      for report in reports {
        XCTAssertGreaterThanOrEqual(report.timestampNs, lastTimestamp)
        XCTAssertLessThanOrEqual(report.timestampNs, HIDEventTranslator.nowNs())
        XCTAssertGreaterThan(report.timestampNs, 0)
        lastTimestamp = report.timestampNs
      }
      return reports
    }
    func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, type: CGEventType) throws {
      let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down))
      event.type = type; event.flags = flags
      let reports = try post(event, type: type == .flagsChanged ? .flagsChanged : down ? .keyDown : .keyUp, count: 1)
      let report = try XCTUnwrap(reports.first)
      XCTAssertEqual(report.deviceId, UInt32(HIDKind.keyboard)); XCTAssertEqual(report.reportLength, 8)
      let expected: [UInt8] = [flags.contains(.maskShift) ? 2 : 0, 0, code == 0 && down ? 4 : 0, 0, 0, 0, 0, 0]
      XCTAssertEqual((0..<8).map { report.bytes[$0] }, expected)
    }
    func signed(_ report: InputReportRecord, _ offset: Int) -> Int16 {
      Int16(bitPattern: UInt16(report.bytes[offset]) | UInt16(report.bytes[offset+1]) << 8)
    }
    func pointer(_ event: CGEvent, type: NSEvent.EventType, buttons: UInt8,
      dx: Int16 = 0, dy: Int16 = 0, wheel: Int16 = 0, pan: Int16 = 0) throws {
      let reports = try post(event, type: type, count: 2)
      guard reports.count == 2 else { return }
      let relative = reports[0], absolute = reports[1]
      XCTAssertEqual(relative.deviceId, UInt32(HIDKind.pointer)); XCTAssertEqual(relative.reportLength, 9)
      XCTAssertEqual(relative.bytes[0], buttons)
      XCTAssertEqual(signed(relative, 1), dx); XCTAssertEqual(signed(relative, 3), dy)
      XCTAssertEqual(signed(relative, 5), wheel); XCTAssertEqual(signed(relative, 7), pan)
      XCTAssertEqual(absolute.deviceId, UInt32(HIDKind.tablet)); XCTAssertEqual(absolute.reportLength, 13)
      XCTAssertEqual(absolute.bytes[0], 2)
      XCTAssertEqual(absolute.timestampNs, relative.timestampNs)
      let received = try XCTUnwrap(view.events.last)
      let expectedX = UInt16((received.locationInWindow.x / view.bounds.width * 65535).rounded())
      let expectedY = UInt16((received.locationInWindow.y / view.bounds.height * 65535).rounded())
      XCTAssertEqual(UInt16(bitPattern: signed(absolute, 1)), expectedX)
      XCTAssertEqual(UInt16(bitPattern: signed(absolute, 3)), expectedY)
    }
    func mouse(_ type: CGEventType, dx: Int64 = 0, dy: Int64 = 0) throws -> CGEvent {
      let event = try XCTUnwrap(CGEvent(mouseEventSource: source, mouseType: type,
        mouseCursorPosition: point, mouseButton: .left))
      event.flags = []
      event.setIntegerValueField(.mouseEventDeltaX, value: dx)
      event.setIntegerValueField(.mouseEventDeltaY, value: dy)
      event.setIntegerValueField(.mouseEventClickState, value: 1)
      return event
    }
    try key(56, down: true, flags: .maskShift, type: .flagsChanged)
    try key(0, down: true, flags: .maskShift, type: .keyDown)
    try key(0, down: false, flags: .maskShift, type: .keyUp)
    try key(56, down: false, flags: [], type: .flagsChanged)
    try pointer(mouse(.mouseMoved, dx: 7, dy: -4), type: .mouseMoved, buttons: 0, dx: 7, dy: -4)
    try pointer(mouse(.leftMouseDown), type: .leftMouseDown, buttons: 1)
    try pointer(mouse(.leftMouseUp), type: .leftMouseUp, buttons: 0)
    try pointer(mouse(.leftMouseDown), type: .leftMouseDown, buttons: 1)
    try pointer(mouse(.leftMouseDragged, dx: 11, dy: 6), type: .leftMouseDragged, buttons: 1, dx: 11, dy: 6)
    try pointer(mouse(.leftMouseUp), type: .leftMouseUp, buttons: 0)
    for (unit, vertical, horizontal) in [(CGScrollEventUnit.line, Int32(3), Int32(-2)), (.pixel, 5, -4)] {
      let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: source, units: unit,
        wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0))
      event.location = point; event.flags = []
      try pointer(event, type: .scrollWheel, buttons: 0, wheel: Int16(vertical), pan: Int16(horizontal))
      XCTAssertEqual(view.events.last?.hasPreciseScrollingDeltas, unit == .pixel)
      XCTAssertEqual(channel.flags.last, unit == .pixel ? 1 : 0)
    }
    XCTAssertNil(ring.pop()); XCTAssertEqual(ring.overruns, 0)
    XCTAssertEqual(view.events.count, 12)
    print("Live HID: 12 posted CGEvents received by focused NSView; 20 ordered Mach HID reports verified")
    print("Live HID: public CGEvent APIs expose no magnify/rotate/swipe constructor or gesture fields; live gesture synthesis not exercised")
  }
}
