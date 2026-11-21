import Dispatch
import Foundation
import XCTest
import HostedDeviceWire
import MacAudioWire
import MacAudioHost
import MacAudioDriver
import TarwinArchHosted

private final class HALPositions {
  private let lock = NSLock()
  private var values: [UInt32: (count: Int, first: UInt64, last: UInt64, time: UInt64)] = [:]
  func receive(_ bytes: UnsafeRawBufferPointer) {
    guard let frame = FrameView(bytes), frame.family == 2, frame.kind == AudioKind.position,
      frame.payload.count == 28 else { return }
    let endpoint = UInt32(Wire.read(frame.payload,0,4))
    let position = Wire.read(frame.payload,4,8), time = Wire.read(frame.payload,12,8)
    lock.lock(); defer { lock.unlock() }
    let old = values[endpoint]
    values[endpoint] = ((old?.count ?? 0) + 1, old?.first ?? position, position, time)
  }
  func snapshot(_ endpoint: AudioEndpoint) -> (count: Int, first: UInt64, last: UInt64, time: UInt64)? {
    lock.lock(); defer { lock.unlock() }; return values[endpoint.rawValue]
  }
}

final class AudioTests: XCTestCase {
  func testHostedDeviceRegistryAndEndpoint() throws {
    let (host, channel) = LoopbackChannel.pair()
    let driver = MacAudioDriver(channel: channel)
    let registry = HostDeviceRegistry()
    let provider = try MacAudioDeviceProvider(driver: driver)
    registry.register(provider)
    let registered = try XCTUnwrap(registry.lookup(kind: "audio"))
    let port = try registered.open(slot: 0)
    XCTAssertEqual(port.kind, .send)
    XCTAssertThrowsError(try { let bad = try registered.open(slot: .max); _ = bad.rawName }())
    let received = expectation(description: "Mach endpoint ping reaches audio driver")
    host.onReceive = { if FrameView($0)?.kind == Wire.pong { received.fulfill() } }
    var bytes = [UInt8](repeating: 0, count: 32)
    try bytes.withUnsafeMutableBytes { out in
      _ = FrameView.encode(family: 2, kind: Wire.ping, sequence: 1, timestampNs: 2,
        payload: .init(start: nil,count: 0), into: out)
      try HostedDriverEndpoint.send(frame: UnsafeRawBufferPointer(out), to: port)
    }
    wait(for: [received], timeout: 2)
    withExtendedLifetime((registry,provider,host)) {}
  }
  func config(_ format: PCMFormat = .f32, channels: UInt32 = 2) -> AudioConfiguration {
    AudioConfiguration(sampleRate: 48000, channels: channels, format: format)!
  }
  func testConversionAndConfiguration() {
    XCTAssertEqual(PCMConversion.toFloat(-32768), -1)
    XCTAssertEqual(PCMConversion.toInt16(-1), -32768)
    XCTAssertEqual(PCMConversion.toInt16(1), 32767)
    XCTAssertEqual(PCMConversion.toInt16(.nan), 0)
    XCTAssertEqual(PCMConversion.toInt16(.infinity), 0)
    for value in stride(from: Int16(-32000), through: 32000, by: 1000) {
      XCTAssertEqual(PCMConversion.toInt16(PCMConversion.toFloat(value)), value)
    }
    for rate: UInt32 in [44100,48000] { for ch: UInt32 in [1,2] {
      XCTAssertNotNil(AudioConfiguration(sampleRate: rate, channels: ch, format: .i16))
    } }
    XCTAssertNil(AudioConfiguration(sampleRate: 96000, channels: 2, format: .f32))
    XCTAssertNil(AudioConfiguration(sampleRate: 48000, channels: 3, format: .f32))
  }
  func testRingWrapAndSharedView() {
    for format: PCMFormat in [.f32,.i16] {
      let ring = AudioRing(capacity: 4, configuration: config(format))!
      let view = AudioRing(region: ring.region, byteCount: ring.byteCount)!
      let input: [Float] = [-1,0.5,0.25,-0.25,0.75,0,0.125,-0.5]
      var output = [Float](repeating: 99, count: 12)
      input.withUnsafeBufferPointer { XCTAssertEqual(ring.write($0, frames: 4), 4) }
      XCTAssertEqual(view.availableFrames, 4)
      input.withUnsafeBufferPointer { XCTAssertEqual(ring.write($0, frames: 1), 0) }
      XCTAssertEqual(view.overruns, 1)
      output.withUnsafeMutableBufferPointer { XCTAssertEqual(view.read(into: $0, frames: 3), 3) }
      XCTAssertEqual(Array(output.prefix(6)), Array(input.prefix(6)))
      input.withUnsafeBufferPointer { XCTAssertEqual(ring.write($0, frames: 3), 3) }
      output.withUnsafeMutableBufferPointer { XCTAssertEqual(view.read(into: $0, frames: 6), 4) }
      XCTAssertEqual(Array(output.prefix(8)), Array(input.suffix(2)) + Array(input.prefix(6)))
      XCTAssertEqual(Array(output.suffix(4)), [0,0,0,0]); XCTAssertEqual(ring.underruns, 1)
      XCTAssertEqual(ring.latencyNs, 0)
      XCTAssertNil(AudioRing(region: ring.region, byteCount: 63))
    }
    XCTAssertNil(AudioRing(capacity: 3, configuration: config()))
    XCTAssertNil(AudioRing(capacity: 0, configuration: config()))
    let invalid = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 64)
    defer { invalid.deallocate() }
    invalid.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
    XCTAssertNil(AudioRing(region: invalid, byteCount: 64))
  }
  func testConcurrentProducerConsumer() {
    let ring = AudioRing(capacity: 64, configuration: config(channels: 1))!
    let group = DispatchGroup(); group.enter()
    DispatchQueue.global().async {
      for i in 0..<10000 {
        var sample = Float(i)
        withUnsafePointer(to: &sample) { p in
          while ring.write(UnsafeBufferPointer(start: p, count: 1), frames: 1) == 0 {}
        }
      }
      group.leave()
    }
    for i in 0..<10000 {
      var sample: Float = -1
      withUnsafeMutablePointer(to: &sample) { p in
        while ring.read(into: UnsafeMutableBufferPointer(start: p, count: 1), frames: 1) == 0 {}
      }
      XCTAssertEqual(sample, Float(i))
    }
    group.wait()
  }
  func testOfflineRenderCaptureAndPosition() throws {
    let (driverChannel, hostChannel) = LoopbackChannel.pair()
    let playback = AudioRing(capacity: 1024, configuration: config())!
    let capture = AudioRing(capacity: 1024, configuration: config(.i16))!
    let host = MacAudioHost(channel: hostChannel, playback: playback, capture: capture,
      useHAL: false, automaticPositions: false)
    defer { host.shutdown() }
    let driver = MacAudioDriver(channel: driverChannel)
    XCTAssertThrowsError(try driver.start(.playback))
    for endpoint in AudioEndpoint.allCases {
      try driver.open(endpoint); try driver.configure(endpoint, ring: endpoint == .playback ? playback : capture)
      try driver.start(endpoint)
    }
    let input = [Float](repeating: 0.5, count: 960)
    input.withUnsafeBufferPointer { XCTAssertEqual(playback.write($0, frames: 480), 480) }
    try driver.setVolume(0.5)
    var output = [Float](repeating: 99, count: 960)
    output.withUnsafeMutableBufferPointer { XCTAssertEqual(host.playback!.render(into: $0, frames: 480, timestampNs: 123), 480) }
    XCTAssertTrue(output.allSatisfy { $0 == 0.25 })
    XCTAssertEqual(host.playback!.ring.latencyNs, 0)
    host.flushPositions(); XCTAssertEqual(driver.playbackPosition, 480)
    input.withUnsafeBufferPointer { XCTAssertEqual(host.capture!.capture($0, frames: 480, timestampNs: 124), 480) }
    host.flushPositions(); XCTAssertEqual(driver.capturePosition, 480); XCTAssertEqual(driver.hostTimeNs, 124)
    XCTAssertEqual(driver.latencyNs, 10_000_000)
    output.withUnsafeMutableBufferPointer { XCTAssertEqual(capture.read(into: $0, frames: 480), 480) }
    XCTAssertTrue(output.allSatisfy { $0 == 0.5 })
    var gap = false
    driver.onGap = { endpoint, _, under in if endpoint == .playback && under > 0 { gap = true } }
    try driver.setMuted(true)
    output.withUnsafeMutableBufferPointer { XCTAssertEqual(host.playback!.render(into: $0, frames: 480, timestampNs: 125), 0) }
    XCTAssertTrue(output.allSatisfy { $0 == 0 }); host.flushPositions(); XCTAssertTrue(gap)
    try driver.drain()
    output.withUnsafeMutableBufferPointer { _ = host.playback!.render(into: $0, frames: 480, timestampNs: 126) }
    host.flushPositions(); XCTAssertEqual(driver.snapshot(.playback).state, .stopped)
    try driver.stop(.capture)
    XCTAssertThrowsError(try driver.drain(.capture))
    XCTAssertThrowsError(try driver.setVolume(.nan))
    driver.close(.capture); XCTAssertEqual(driver.snapshot(.capture).state, .closed)
  }
  func testRestartRestoresStream() throws {
    let (a,b) = LoopbackChannel.pair()
    let ring = AudioRing(capacity: 1024, configuration: config())!
    let driver = MacAudioDriver(channel: a)
    let original = MacAudioHost(channel: b, playback: ring, capture: nil, useHAL: false, automaticPositions: false)
    try driver.open(.playback); try driver.configure(.playback, ring: ring)
    try driver.setVolume(0.25); try driver.setMuted(true); try driver.start(.playback)
    original.shutdown()
    let (c,d) = LoopbackChannel.pair()
    let replacement = MacAudioHost(channel: d, playback: ring, capture: nil, useHAL: false, automaticPositions: false)
    defer { replacement.shutdown() }
    try driver.restore(on: c)
    XCTAssertEqual(driver.snapshot(.playback).configuration, config())
    XCTAssertEqual(driver.snapshot(.playback).state, .running)
    XCTAssertTrue(replacement.playback!.muted.load(ordering: .relaxed))
    XCTAssertEqual(Float(bitPattern: replacement.playback!.gainBits.load(ordering: .relaxed)), 0.25)
  }
  func testMalformedFramesAndPing() {
    let (a,b) = LoopbackChannel.pair()
    let ring = AudioRing(capacity: 8, configuration: config())!
    let host = MacAudioHost(channel: b, playback: ring, capture: nil, useHAL: false, automaticPositions: false)
    defer { host.shutdown() }
    var kind: UInt16 = 0, status: UInt16 = 0
    a.onReceive = { bytes in
      let frame = FrameView(bytes)!; kind = frame.kind
      if frame.kind == AudioKind.status { status = UInt16(Wire.read(frame.payload,6,2)) }
    }
    AudioWire.send(a, kind: Wire.ping, payloadSize: 0) { _ in }
    XCTAssertEqual(kind, Wire.pong)
    AudioWire.send(a, kind: AudioKind.configure, payloadSize: 4) {
      Wire.write(1, to: $0, at: 0, width: 4)
    }
    XCTAssertEqual(status, 1)
    AudioWire.send(a, kind: AudioKind.start, payloadSize: 4) { Wire.write(1,to:$0,at:0,width:4) }
    XCTAssertEqual(status, 3)
    AudioWire.send(a, kind: AudioKind.open, payloadSize: 4) { Wire.write(1,to:$0,at:0,width:4) }
    XCTAssertEqual(status, 0)
    AudioWire.send(a, kind: AudioKind.configure, payloadSize: 20) { p in
      Wire.write(1,to:p,at:0,width:4); Wire.write(96000,to:p,at:4,width:4)
      Wire.write(2,to:p,at:8,width:4); Wire.write(1,to:p,at:12,width:4)
      Wire.write(8,to:p,at:16,width:4)
    }
    XCTAssertEqual(status, 2)
    [UInt8](repeating: 0, count: 5).withUnsafeBytes { a.send(frame: $0) }
    XCTAssertFalse(host.playback!.running.load(ordering: .relaxed))
  }
  func testCaptureMuteAndOverrun() {
    let ring = AudioRing(capacity: 4, configuration: config(.i16, channels: 1))!
    let processor = AudioProcessor(ring: ring)
    processor.running.store(true, ordering: .releasing)
    processor.muted.store(true, ordering: .releasing)
    let input = [Float](repeating: 0.5, count: 8)
    input.withUnsafeBufferPointer { XCTAssertEqual(processor.capture($0, frames: 8, timestampNs: 77), 4) }
    XCTAssertEqual(ring.overruns, 1)
    XCTAssertEqual(processor.position.load(ordering: .relaxed), 4)
    var output = [Float](repeating: 99, count: 4)
    output.withUnsafeMutableBufferPointer { XCTAssertEqual(ring.read(into:$0,frames:4), 4) }
    XCTAssertTrue(output.allSatisfy { $0 == 0 })
    processor.running.store(false, ordering: .releasing)
    input.withUnsafeBufferPointer { XCTAssertEqual(processor.capture($0, frames: 8, timestampNs: 78), 0) }
  }
  func testHALSmokeOrOfflineCallback() throws {
    guard ProcessInfo.processInfo.environment["TARWIN_AUDIO_HAL"] == "1" else {
      let ring = AudioRing(capacity: 1024, configuration: config())!
      let processor = AudioProcessor(ring: ring)
      processor.running.store(true, ordering: .releasing)
      var output = [Float](repeating: 1, count: 960)
      output.withUnsafeMutableBufferPointer { XCTAssertEqual(processor.render(into:$0,frames:480,timestampNs:1), 0) }
      XCTAssertTrue(output.allSatisfy { $0 == 0 }); return
    }
    _ = try XCTUnwrap(MacAudioHost.hasDefaultDevice(.playback) ? true : nil, "HAL loopback requires a default output")
    _ = try XCTUnwrap(MacAudioHost.hasDefaultDevice(.capture) ? true : nil, "HAL loopback requires a default input")
    let (a,b) = LoopbackChannel.pair()
    let positions = HALPositions()
    a.onReceive = { positions.receive($0) }
    let playback = AudioRing(capacity: 131072, configuration: config())!
    let capture = AudioRing(capacity: 131072, configuration: config())!
    let lead = 4096, markerLength = 2048, sineLength = 48000, tail = 2048
    let frames = lead + markerLength + sineLength + tail
    var signal = [Float](repeating: 0, count: frames * 2)
    var random: UInt32 = 0x48564c50
    for frame in 0..<markerLength {
      random = random &* 1664525 &+ 1013904223
      let value: Float = random & 0x80000000 == 0 ? -0.25 : 0.25
      signal[(lead + frame)*2] = value; signal[(lead + frame)*2+1] = -0.5 * value
    }
    for frame in 0..<sineLength {
      let value = Float(0.15 * sin(2 * Double.pi * 1000 * Double(frame) / 48000))
      signal[(lead + markerLength + frame)*2] = value
      signal[(lead + markerLength + frame)*2+1] = -0.5 * value
    }
    let host = MacAudioHost(channel: b, playback: playback, capture: capture)
    defer { host.shutdown(); withExtendedLifetime(a) {} }
    try host.startHardware(.capture)
    try host.startHardware(.playback)
    let primed = expectation(description: "HAL loopback startup silence")
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) { primed.fulfill() }
    wait(for: [primed], timeout: 2)
    signal.withUnsafeBufferPointer { XCTAssertEqual(playback.write($0, frames: frames), frames) }
    let elapsed = expectation(description: "HAL loopback recording")
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1800)) { elapsed.fulfill() }
    wait(for: [elapsed], timeout: 5)
    host.stopHardware(.playback); host.stopHardware(.capture)
    XCTAssertEqual(playback.availableFrames, 0, "HAL must consume the complete known signal")
    XCTAssertEqual(capture.overruns, 0, "A dropped capture block would invalidate alignment")
    let recordedFrames = capture.availableFrames
    var recorded = [Float](repeating: 0, count: recordedFrames * 2)
    recorded.withUnsafeMutableBufferPointer { XCTAssertEqual(capture.read(into: $0, frames: recordedFrames), recordedFrames) }
    let markerStart = try XCTUnwrap((0..<recordedFrames).first { abs(recorded[$0*2]) > 0.2 },
      "No marker captured: route the same loopback device to default input and output")
    _ = try XCTUnwrap(markerStart + markerLength + sineLength <= recordedFrames ? true : nil,
      "The recording must contain the entire marker and sine")
    var dot = 0.0, expectedEnergy = 0.0, observedEnergy = 0.0
    for frame in 0..<markerLength {
      let expected = Double(signal[(lead+frame)*2]), observed = Double(recorded[(markerStart+frame)*2])
      dot += expected * observed; expectedEnergy += expected * expected; observedEnergy += observed * observed
    }
    let correlation = dot / sqrt(max(Double.leastNonzeroMagnitude, expectedEnergy * observedEnergy))
    XCTAssertGreaterThan(correlation, 0.99, "Pseudorandom marker must survive the HAL loopback")
    var error = 0.0
    var firstMismatch: Int?, lastMismatch: Int?, mismatchCount = 0
    for frame in 0..<sineLength {
      for channel in 0..<2 {
        let expected = Double(signal[(lead+markerLength+frame)*2+channel])
        let observed = Double(recorded[(markerStart+markerLength+frame)*2+channel])
        error += (expected-observed) * (expected-observed)
        if abs(expected-observed) > 0.005 {
          if firstMismatch == nil { firstMismatch = frame }
          lastMismatch = frame; mismatchCount += 1
        }
      }
    }
    let rmsError = sqrt(error / Double(sineLength * 2))
    if let firstMismatch, let lastMismatch {
      print("HAL sine mismatches: frames \(firstMismatch)...\(lastMismatch), \(mismatchCount) channel samples")
    }
    XCTAssertLessThan(rmsError, 0.005, "Both channels must retain the known 1 kHz waveform and gain")
    for endpoint in AudioEndpoint.allCases {
      let position = try XCTUnwrap(positions.snapshot(endpoint))
      XCTAssertGreaterThan(position.count, 2); XCTAssertGreaterThan(position.last, position.first)
      XCTAssertGreaterThan(position.time, 0)
      print("HAL loopback \(endpoint): position \(position.first)->\(position.last), \(position.count) position frames")
    }
    print("HAL loopback: recorded \(recordedFrames) frames, marker at \(markerStart), correlation \(correlation), sine RMS error \(rmsError)")
  }
}
