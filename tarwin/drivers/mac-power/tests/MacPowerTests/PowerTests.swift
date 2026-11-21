import AppKit
import HostedDeviceWire
import MacPowerWire
import MacPowerHost
import MacPowerDriver
import TarwinPower
import TarwinArchHosted
import XCTest

final class PowerTests: XCTestCase {
  func testThermalMappingAndTimeConversion() {
    let values: [ProcessInfo.ThermalState] = [.nominal,.fair,.serious,.critical]
    let expected: [ThermalBand] = [.nominal,.fair,.serious,.critical]
    for (index,value) in values.enumerated() {
      XCTAssertEqual(MacPowerHost.thermalRawValue(value), UInt32(index))
      XCTAssertEqual(MacPowerDriver.thermalBand(rawValue: UInt32(index)), expected[index])
    }
    XCTAssertNil(MacPowerDriver.thermalBand(rawValue: 4))
    XCTAssertEqual(MacPowerHost.nanoseconds(minutes: 2), 120_000_000_000)
    XCTAssertEqual(MacPowerHost.nanoseconds(minutes: -1), 0)
    XCTAssertEqual(MacPowerHost.nanoseconds(minutes: Int.max), 0)
  }
  @MainActor func testPublicationAndNotificationFrames() {
    let page = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
    defer { page.deallocate() }
    let (a,b) = LoopbackChannel.pair()
    let driver = MacPowerDriver(channel: b, initializing: page)!
    let battery = PowerSourceSample(id: 1, kind: .battery, percent: 72, online: true,
      charging: true, timeToFull: 600_000_000_000)!
    let center = NotificationCenter(), workspace = NotificationCenter()
    var environment: (UInt32,Bool) = (2,true)
    let host = MacPowerHost(channel: a, center: center, workspaceCenter: workspace, sources: { [battery] },
      environment: { environment })
    defer { host.stop() }
    var publications = 0
    driver.onPublished = {
      publications += 1
      XCTAssertNotNil(readPowerPage(UnsafeRawBufferPointer(page)))
    }
    host.refresh()
    let sample = readPowerPage(UnsafeRawBufferPointer(page))!
    XCTAssertEqual(sample.percent, 72); XCTAssertEqual(sample.state, 2); XCTAssertEqual(sample.external, 4)
    XCTAssertEqual(sample.thermal, .serious); XCTAssertTrue(sample.lowPower)
    XCTAssertEqual(sample.timeToFull, 600_000_000_000)
    XCTAssertEqual(driver.source(at: 0), battery); XCTAssertNil(driver.source(at: 1))
    environment = (1,false)
    center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    XCTAssertEqual(readPowerPage(UnsafeRawBufferPointer(page))?.thermal, .fair)
    center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    XCTAssertFalse(readPowerPage(UnsafeRawBufferPointer(page))!.lowPower)
    var events: [PowerSystemEvent] = []
    driver.onSystemEvent = { event, time in events.append(event); XCTAssertGreaterThan(time, 0) }
    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    XCTAssertEqual(events, [.sleep,.wake]); XCTAssertGreaterThan(publications, 2)
  }
  @MainActor func testNoBatteryMainsAndRealHostSample() {
    XCTAssertEqual(MacPowerHost.normalizedSources([]), [.mains])
    let absent = PowerSourceSample(id: 1, kind: .battery, isPresent: false, online: false)!
    XCTAssertEqual(MacPowerHost.normalizedSources([absent]), [.mains])
    let page = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
    defer { page.deallocate() }
    let (a,b) = LoopbackChannel.pair()
    let driver = MacPowerDriver(channel: b, initializing: page)!
    let host = MacPowerHost(channel: a, sources: { [] }, observe: false)
    host.refresh()
    let sample = readPowerPage(UnsafeRawBufferPointer(page))!
    XCTAssertEqual(sample.percent, .max); XCTAssertEqual(sample.state, 0); XCTAssertEqual(sample.external, 4)
    let actual = MacPowerHost.readSources()
    XCTAssertFalse(actual.isEmpty)
    if actual.allSatisfy({ $0.kind == .mains }) { XCTAssertTrue(actual[0].online) }
    print("Power host sample: \(actual.count) source(s), kinds \(actual.map { $0.kind.rawValue })")
    withExtendedLifetime(driver) {}
  }
  func testMalformedAndStaleFrames() {
    let page = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
    defer { page.deallocate() }
    let (a,b) = LoopbackChannel.pair()
    let driver = MacPowerDriver(channel: b, initializing: page)!
    func environment(_ thermal: UInt32, time: UInt64, size: Int = 8) {
      var bytes = [UInt8](repeating: 0, count: size)
      bytes.withUnsafeMutableBytes { p in
        if size >= 4 { Wire.write(UInt64(thermal), to: p, at: 0, width: 4) }
        PowerWire.send(a, kind: PowerKind.environment, timestampNs: time, payload: UnsafeRawBufferPointer(p))
      }
    }
    environment(5,time: 10); environment(1,time: 11,size: 4)
    XCTAssertNil(readPowerPage(UnsafeRawBufferPointer(page)))
    environment(2,time: 100)
    XCTAssertEqual(readPowerPage(UnsafeRawBufferPointer(page))?.thermal, .serious)
    environment(0,time: 99)
    XCTAssertEqual(readPowerPage(UnsafeRawBufferPointer(page))?.updated, 100)
    let bad = [UInt8](repeating: 0xff, count: 4)
    bad.withUnsafeBytes { PowerWire.send(a, kind: PowerKind.sources, timestampNs: 101, payload: $0) }
    XCTAssertEqual(driver.sourceCount, 0)
    XCTAssertEqual(readPowerPage(UnsafeRawBufferPointer(page))?.updated, 100)
    var pong = false
    a.onReceive = { pong = FrameView($0)?.kind == Wire.pong }
    PowerWire.send(a, kind: Wire.ping, timestampNs: 102, payload: .init(start: nil,count: 0))
    XCTAssertTrue(pong)
  }
  func testHostedDeviceRegistryAndEndpoint() throws {
    let page = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
    defer { page.deallocate() }
    let (host, channel) = LoopbackChannel.pair()
    let driver = MacPowerDriver(channel: channel, initializing: page)!
    let registry = HostDeviceRegistry()
    let provider = try MacPowerDeviceProvider(driver: driver)
    registry.register(provider)
    let registered = try XCTUnwrap(registry.lookup(kind: "power"))
    let port = try registered.open(slot: 0)
    XCTAssertEqual(port.kind, .send)
    XCTAssertThrowsError(try { let bad = try registered.open(slot: 1); _ = bad.rawName }())
    let received = expectation(description: "Mach endpoint ping reaches power driver")
    host.onReceive = { if FrameView($0)?.kind == Wire.pong { received.fulfill() } }
    var bytes = [UInt8](repeating: 0, count: 32)
    try bytes.withUnsafeMutableBytes { out in
      _ = FrameView.encode(family: 3, kind: Wire.ping, sequence: 1, timestampNs: 2,
        payload: .init(start: nil,count: 0), into: out)
      try HostedDriverEndpoint.send(frame: UnsafeRawBufferPointer(out), to: port)
    }
    wait(for: [received], timeout: 2)
    withExtendedLifetime((registry,provider,host)) {}
  }
}
