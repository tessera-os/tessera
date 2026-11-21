import AppKit
import Dispatch
import XCTest
import HostedDeviceWire
import MacHIDCapture
import MacHIDDriver
import TarwinArchHosted

final class HIDTests: XCTestCase {
  func testHostedDeviceRegistryAndEndpoint() throws {
    let (host, channel) = LoopbackChannel.pair()
    let ring = InputRing(capacity: 8)!
    let driver = MacHIDDriver(channel: channel, ring: ring)
    let registry = HostDeviceRegistry()
    let provider = try MacHIDDeviceProvider(driver: driver)
    registry.register(provider)
    let registered = try XCTUnwrap(registry.lookup(kind: "hid"))
    let port = try registered.open(slot: 0)
    XCTAssertEqual(port.kind, .send)
    let second = try registered.open(slot: 0)
    XCTAssertEqual(port.rawName, second.rawName)
    XCTAssertThrowsError(try { let bad = try registered.open(slot: 1); _ = bad.rawName }())
    let received = expectation(description: "Mach endpoint ping reaches HID driver")
    host.onReceive = { bytes in
      if FrameView(bytes)?.kind == Wire.pong { received.fulfill() }
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    try bytes.withUnsafeMutableBytes { out in
      _ = FrameView.encode(family: 1, kind: Wire.ping, sequence: 1, timestampNs: 2,
        payload: .init(start: nil,count: 0), into: out)
      try HostedDriverEndpoint.send(frame: UnsafeRawBufferPointer(out), to: port)
    }
    wait(for: [received], timeout: 2)
    withExtendedLifetime((registry,provider,host)) {}
  }
  func testCodecAndMalformed() {
    var bytes = [UInt8](repeating: 0, count: 35)
    let payload: [UInt8] = [1,2,3]
    bytes.withUnsafeMutableBytes { out in
      payload.withUnsafeBytes { p in
        XCTAssertEqual(FrameView.encode(family: 3, kind: 12, flags: 5, sequence: .max,
          timestampNs: 42, payload: p, into: out), 35)
      }
    }
    bytes.withUnsafeBytes { p in
      let f = FrameView(p)!
      XCTAssertEqual(f.family, 3); XCTAssertEqual(f.sequence, .max)
      XCTAssertEqual(f.timestampNs, 42); XCTAssertEqual(Array(f.payload), payload)
      for n in 0..<35 { XCTAssertNil(FrameView(UnsafeRawBufferPointer(rebasing: p[..<n]))) }
    }
    for index in [0,4,12,15] {
      var bad = bytes; bad[index] = 0xff
      bad.withUnsafeBytes { XCTAssertNil(FrameView($0)) }
    }
    let huge = [UInt8](repeating: 0, count: 65537)
    bytes.withUnsafeMutableBytes { out in huge.withUnsafeBytes {
      XCTAssertNil(FrameView.encode(family: 1, kind: 1, sequence: 0, timestampNs: 0, payload: $0, into: out))
    } }
  }
  func testKeycodeCoverage() {
    let letters: [UInt16] = [0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6]
    for (i,k) in letters.enumerated() { XCTAssertEqual(HIDKeycodes.usage(for:k), UInt8(i+4)) }
    for (k,u) in zip([18,19,20,21,23,22,26,28,25,29], 30...39) {
      XCTAssertEqual(HIDKeycodes.usage(for: UInt16(k)), UInt8(u))
    }
    for (k,u) in zip([122,120,99,118,96,97,98,100,101,109,103,111], 58...69) {
      XCTAssertEqual(HIDKeycodes.usage(for: UInt16(k)), UInt8(u))
    }
    for (k,u) in [(123,80),(124,79),(125,81),(126,82),(59,224),(56,225),(58,226),(55,227),(62,228),(60,229),(61,230),(54,231)] {
      XCTAssertEqual(HIDKeycodes.usage(for: UInt16(k)), UInt8(u))
    }
    XCTAssertNil(HIDKeycodes.usage(for: 65535))
  }
  func testRingWrapOverrun() {
    XCTAssertNil(InputRing(capacity: 0))
    let ring = InputRing(capacity: 2)!
    XCTAssertNil(ring.pop())
    var r = InputReportRecord(); r.reportLength = 64; r.bytes[63] = 99
    XCTAssertTrue(ring.push(r)); XCTAssertTrue(ring.push(r)); XCTAssertFalse(ring.push(r))
    XCTAssertEqual(ring.overruns, 1)
    XCTAssertEqual(ring.pop()?.bytes[63], 99)
    XCTAssertTrue(ring.push(r)); XCTAssertNotNil(ring.pop()); XCTAssertNotNil(ring.pop()); XCTAssertNil(ring.pop())
    r.reportLength = 65; XCTAssertFalse(ring.push(r))
  }
  func testConcurrentRing() {
    let ring = InputRing(capacity: 64)!
    let done = DispatchGroup()
    done.enter()
    DispatchQueue.global().async {
      for i in 0..<10000 {
        var r = InputReportRecord(); r.timestampNs = UInt64(i)
        while !ring.push(r) {}
      }
      done.leave()
    }
    for i in 0..<10000 {
      var result = ring.pop()
      while result == nil { result = ring.pop() }
      XCTAssertEqual(result?.timestampNs, UInt64(i))
    }
    done.wait()
  }
  @MainActor func testHostDriverRoundTripAndFocus() {
    let (host, endpoint) = LoopbackChannel.pair()
    let ring = InputRing(capacity: 16)!
    let driver = MacHIDDriver(channel: endpoint, ring: ring)
    let translator = HIDEventTranslator(channel: host)
    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
    translator.translate(key, windowSize: .init(width: 100,height: 100))
    XCTAssertNil(ring.pop())
    translator.setFocused(true)
    translator.translate(key, windowSize: .init(width: 100,height: 100), timestampNs: 123)
    let report = ring.pop()!
    XCTAssertEqual(report.deviceId, 1); XCTAssertEqual(report.bytes[2], 4); XCTAssertEqual(report.timestampNs, 123)
    translator.setFocused(false, timestampNs: 124)
    XCTAssertEqual(ring.pop()?.bytes[2], 0)
    XCTAssertEqual(ring.pop()?.deviceId, 2); XCTAssertEqual(ring.pop()?.deviceId, 3)
    XCTAssertEqual(ring.pop()?.deviceId, 3)
    var leds: UInt8 = 0
    host.onReceive = { bytes in leds = FrameView(bytes)!.payload[0] }
    driver.setLEDs(2); XCTAssertEqual(leds, 2)
    host.close(); driver.setLEDs(0); XCTAssertEqual(leds, 2)
  }
  func testDriverMalformedAndHealth() {
    let (host, endpoint) = LoopbackChannel.pair()
    let ring = InputRing(capacity: 2)!
    let driver = MacHIDDriver(channel: endpoint, ring: ring)
    var pong = false
    host.onReceive = { bytes in pong = FrameView(bytes)?.kind == Wire.pong }
    var bytes = [UInt8](repeating: 0, count: 32)
    bytes.withUnsafeMutableBytes { out in
      _ = FrameView.encode(family: 1, kind: Wire.ping, sequence: 1, timestampNs: 7,
        payload: .init(start: nil,count: 0), into: out)
      host.send(frame: UnsafeRawBufferPointer(out))
    }
    XCTAssertTrue(pong)
    for kind: UInt16 in [1,2,3,4,900] {
      bytes.withUnsafeMutableBytes { out in
        _ = FrameView.encode(family: 1, kind: kind, sequence: 1, timestampNs: 7,
          payload: .init(start: nil,count: 0), into: out)
        driver.receive(UnsafeRawBufferPointer(out))
      }
    }
    XCTAssertNil(ring.pop())
  }
  @MainActor func testMouseAndModifierTranslation() {
    let (host, endpoint) = LoopbackChannel.pair()
    let ring = InputRing(capacity: 16)!
    let driver = MacHIDDriver(channel: endpoint, ring: ring)
    let translator = HIDEventTranslator(channel: host)
    translator.setFocused(true)
    let mouse = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50,y: 25),
      modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
      clickCount: 1, pressure: 1)!
    translator.translate(mouse, windowSize: CGSize(width: 100,height: 100), timestampNs: 99)
    XCTAssertEqual(ring.pop()?.bytes[0], 1)
    let absolute = ring.pop()!
    XCTAssertEqual(absolute.deviceId, 3)
    XCTAssertEqual(UInt16(absolute.bytes[1]) | UInt16(absolute.bytes[2]) << 8, 32768)
    XCTAssertEqual(UInt16(absolute.bytes[3]) | UInt16(absolute.bytes[4]) << 8, 16384)
    for flags: NSEvent.ModifierFlags in [.shift, []] {
      let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: 56)!
      translator.translate(event, windowSize: .zero)
      XCTAssertEqual(ring.pop()?.bytes[0], flags.isEmpty ? 0 : 2)
    }
    for flags: NSEvent.ModifierFlags in [.capsLock, []] {
      let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: 57)!
      translator.translate(event, windowSize: .zero)
      XCTAssertEqual(ring.pop()?.bytes[2], 57)
      XCTAssertEqual(ring.pop()?.bytes[2], 0)
    }
    let scroll = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
      wheelCount: 2, wheel1: 2, wheel2: -3, wheel3: 0)!)!
    translator.translate(scroll, windowSize: CGSize(width: 100,height: 100))
    XCTAssertNotNil(ring.pop()); XCTAssertNotNil(ring.pop())
    withExtendedLifetime(driver) {}
  }
  func testReportKindsAndFractionalScroll() {
    let (host, endpoint) = LoopbackChannel.pair()
    let ring = InputRing(capacity: 16)!
    let driver = MacHIDDriver(channel: endpoint, ring: ring)
    func send(_ kind: UInt16, _ payload: [UInt8]) {
      var bytes = [UInt8](repeating: 0, count: 32 + payload.count)
      bytes.withUnsafeMutableBytes { out in payload.withUnsafeBytes { p in
        _ = FrameView.encode(family: 1, kind: kind, flags: 1, sequence: 0, timestampNs: 123,
          payload: p, into: out)
        host.send(frame: UnsafeRawBufferPointer(out))
      } }
    }
    var pointer = [UInt8](repeating: 0, count: 17)
    pointer[7] = 0; pointer[6] = 0x80
    send(2, pointer)
    XCTAssertEqual(ring.pop()?.bytes[5], 0); XCTAssertNotNil(ring.pop())
    send(2, pointer)
    XCTAssertEqual(ring.pop()?.bytes[5], 1); XCTAssertNotNil(ring.pop())
    for (kind, size) in [(UInt16(3),13),(UInt16(4),17)] {
      var payload = [UInt8](repeating: 0, count: size); payload[0] = 3
      send(kind, payload)
      let report = ring.pop()!
      XCTAssertEqual(report.deviceId, UInt32(kind)); XCTAssertEqual(report.reportLength, UInt16(size))
      XCTAssertEqual(report.bytes[0], 3); XCTAssertEqual(report.timestampNs, 123)
      send(kind, Array(payload.dropLast())); XCTAssertNil(ring.pop())
    }
    withExtendedLifetime(driver) {}
  }
  func testDescriptorSizes() {
    for (descriptor, expected, output) in [(HIDDescriptors.keyboard,64,8),(HIDDescriptors.pointer,72,0),
      (HIDDescriptors.tablet,104,0),(HIDDescriptors.gestures,136,0)] {
      var index = 0, size = 0, count = 0, inputBits = 0, outputBits = 0, depth = 0
      while index < descriptor.count {
        let prefix = descriptor[index]; index += 1
        let n = Int(prefix & 3) == 3 ? 4 : Int(prefix & 3)
        XCTAssertLessThanOrEqual(index+n, descriptor.count)
        var value = 0
        for j in 0..<n { value |= Int(descriptor[index+j]) << (j*8) }
        switch prefix & 0xfc {
        case 0x74: size = value
        case 0x94: count = value
        case 0x80: inputBits += size*count
        case 0x90: outputBits += size*count
        case 0xa0: depth += 1
        case 0xc0: depth -= 1
        default: break
        }
        index += n
      }
      XCTAssertEqual(inputBits, expected); XCTAssertEqual(outputBits, output); XCTAssertEqual(depth, 0)
    }
  }
}
