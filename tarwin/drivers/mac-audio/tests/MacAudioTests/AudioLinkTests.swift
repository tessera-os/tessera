import Darwin
import Foundation
import XPC
import XCTest
import HostedDeviceWire
import MacAudioWire
import MacAudioDriver
import MacAudioHost

final class AudioLinkTests: XCTestCase {
  private let config = AudioConfiguration(sampleRate: 48000, channels: 2, format: .f32)!

  func testMappedLinkAndLifecycle() throws {
    let (a,b) = LoopbackChannel.pair()
    let driver = MacAudioDriver(channel: a)
    let host = MacAudioHost(channel: b, useHAL: false, automaticPositions: false)
    defer { host.shutdown() }
    XCTAssertNil(host.playback)
    XCTAssertThrowsError(try driver.configure(.playback))
    XCTAssertThrowsError(try driver.makeLink(.playback, configuration: config, capacity: 3))
    let object = try driver.makeLink(.playback, configuration: config, capacity: 1024)
    XCTAssertEqual(xpc_dictionary_get_uint64(object, "tw.endpoint"), 1)
    var mapped: UnsafeMutableRawPointer?
    let mappedCount = xpc_shmem_map(xpc_dictionary_get_value(object, "tw.shmem")!, &mapped)
    let mappedAddress = try XCTUnwrap(mapped)
    defer { munmap(mappedAddress, mappedCount) }
    XCTAssertEqual(mappedCount % Int(getpagesize()), 0)
    XCTAssertGreaterThanOrEqual(mappedCount, AudioRing.requiredBytes(capacity: 1024, configuration: config)!)
    let local = try XCTUnwrap(driver.snapshot(.playback).ring)
    XCTAssertEqual(UInt(bitPattern: local.region) % UInt(getpagesize()), 0)
    XCTAssertEqual(try host.attach(object), .playback)
    var remote: AudioProcessor? = try XCTUnwrap(host.playback)
    XCTAssertNotEqual(local.region, remote!.ring.region)
    weak let oldProcessor = remote
    for operation in [0,1,2] {
      if operation == 0 { try driver.open(.playback) }
      if operation == 1 { try driver.configure(.playback) }
      if operation == 2 { try driver.start(.playback) }
      XCTAssertEqual(driver.lastStatus, 0)
    }
    XCTAssertThrowsError(try driver.makeLink(.playback, configuration: config, capacity: 1024))
    let input: [Float] = [0.25,-0.5,0.75,-1]
    input.withUnsafeBufferPointer { XCTAssertEqual(local.write($0, frames: 2), 2) }
    var output = [Float](repeating: 99, count: 4)
    output.withUnsafeMutableBufferPointer { XCTAssertEqual(remote!.render(into: $0, frames: 2, timestampNs: 42), 2) }
    XCTAssertEqual(output, input); XCTAssertEqual(local.availableFrames, 0)
    host.flushPositions(); XCTAssertEqual(driver.playbackPosition, 2)
    try driver.stop(.playback)
    XCTAssertEqual(driver.lastStatus, 0)
    XCTAssertNil(driver.snapshot(.playback).ring); XCTAssertNil(host.playback)
    XCTAssertFalse(remote!.running.load(ordering: .acquiring))
    remote = nil; XCTAssertNil(oldProcessor)
    XCTAssertThrowsError(try driver.start(.playback))
    XCTAssertThrowsError(try driver.configure(.playback))
    driver.close(.playback)
    XCTAssertEqual(driver.snapshot(.playback).state, .closed)
    let replacement = try driver.makeLink(.playback, configuration: config, capacity: 2048)
    try host.attach(replacement)
    try driver.open(.playback); try driver.configure(.playback); try driver.start(.playback)
    XCTAssertEqual(driver.lastStatus, 0)
    weak let ring = driver.snapshot(.playback).ring
    weak let processor = host.playback
    driver.close(.playback)
    XCTAssertEqual(driver.lastStatus, 0)
    XCTAssertNil(ring); XCTAssertNil(processor); XCTAssertNil(host.playback)
    XCTAssertNil(driver.snapshot(.playback).ring)
  }

  func testInvalidAttachAndMissingProcessorReplies() throws {
    let (a,b) = LoopbackChannel.pair()
    let host = MacAudioHost(channel: b, useHAL: false, automaticPositions: false)
    defer { host.shutdown() }
    XCTAssertThrowsError(try host.attach(xpc_string_create("not a link")))
    XCTAssertThrowsError(try host.attach(xpc_dictionary_create(nil,nil,0)))
    let link = try AudioLink(endpoint: .capture, configuration: config, capacity: 8)
    try host.attach(link.object)
    let original = host.capture
    let bad = xpc_copy(link.object)!
    xpc_dictionary_set_uint64(bad, "tw.capacity", 16)
    XCTAssertThrowsError(try host.attach(bad))
    XCTAssertTrue(host.capture === original)
    xpc_dictionary_set_uint64(bad, "tw.endpoint", UInt64.max)
    XCTAssertThrowsError(try host.attach(bad))
    xpc_dictionary_set_uint64(bad, "tw.endpoint", 2)
    xpc_dictionary_set_value(bad, "tw.shmem", xpc_string_create("not memory"))
    XCTAssertThrowsError(try host.attach(bad))
    host.detach(.capture); XCTAssertNil(host.capture)
    var statuses: [(UInt64,UInt32,UInt16,UInt16)] = []
    a.onReceive = { bytes in
      guard let frame = FrameView(bytes), frame.kind == AudioKind.status else { return }
      statuses.append((frame.sequence, UInt32(Wire.read(frame.payload,0,4)),
        UInt16(Wire.read(frame.payload,4,2)), UInt16(Wire.read(frame.payload,6,2))))
    }
    for kind in [AudioKind.open, AudioKind.configure, AudioKind.start, AudioKind.close] {
      AudioWire.send(a, kind: kind, sequence: 99, payloadSize: 4) { Wire.write(1,to:$0,at:0,width:4) }
      XCTAssertEqual(statuses.last?.0, 99); XCTAssertEqual(statuses.last?.1, 1)
      XCTAssertEqual(statuses.last?.2, kind); XCTAssertEqual(statuses.last?.3, 2)
    }
    AudioWire.send(a, kind: AudioKind.open, payloadSize: 0) { _ in }
    XCTAssertEqual(statuses.last?.3, 1)
    AudioWire.send(a, kind: AudioKind.open, payloadSize: 4) { Wire.write(99,to:$0,at:0,width:4) }
    XCTAssertEqual(statuses.last?.1, 99); XCTAssertEqual(statuses.last?.3, 1)
  }

  func testAttachReplacementAndManagedRestart() throws {
    let (a,b) = LoopbackChannel.pair()
    let driver = MacAudioDriver(channel: a)
    let original = MacAudioHost(channel: b, useHAL: false, automaticPositions: false)
    let object = try driver.makeLink(.playback, configuration: config, capacity: 8)
    try original.attach(object)
    var old: AudioProcessor? = original.playback
    weak let oldRing = driver.snapshot(.playback).ring
    try driver.open(.playback); try driver.configure(.playback); try driver.start(.playback)
    try driver.setVolume(0.25); try driver.setMuted(true)
    XCTAssertThrowsError(try driver.restore(on: a))
    XCTAssertTrue(old!.running.load(ordering: .acquiring))
    original.shutdown()
    let (c,d) = LoopbackChannel.pair()
    let replacement = MacAudioHost(channel: d, useHAL: false, automaticPositions: false)
    defer { replacement.shutdown() }
    var attached = 0
    try driver.restore(on: c) { object in attached += 1; try replacement.attach(object) }
    XCTAssertEqual(attached, 1); XCTAssertNil(oldRing)
    XCTAssertEqual(driver.snapshot(.playback).ring?.availableFrames, 0)
    XCTAssertEqual(driver.snapshot(.playback).state, .running)
    XCTAssertEqual(driver.lastStatus, 0)
    XCTAssertTrue(replacement.playback!.muted.load(ordering: .acquiring))
    XCTAssertEqual(Float(bitPattern: replacement.playback!.gainBits.load(ordering: .acquiring)), 0.25)
    old = nil
    let replacementObject = try AudioLink(endpoint: .playback, configuration: config, capacity: 16)
    weak let previous = replacement.playback
    try replacement.attach(replacementObject.object)
    XCTAssertNil(previous)
    XCTAssertFalse(replacement.playback!.running.load(ordering: .acquiring))
    driver.close(.playback)
    XCTAssertNil(driver.snapshot(.playback).ring); XCTAssertNil(replacement.playback)
  }

  func testFailedRestartAttachReleasesLinks() throws {
    let (a,b) = LoopbackChannel.pair()
    let driver = MacAudioDriver(channel: a)
    let original = MacAudioHost(channel: b, useHAL: false, automaticPositions: false)
    try original.attach(driver.makeLink(.playback, configuration: config, capacity: 8))
    try driver.open(.playback); try driver.configure(.playback); try driver.start(.playback)
    weak let oldRing = driver.snapshot(.playback).ring
    original.shutdown()
    let (c,d) = LoopbackChannel.pair()
    let replacement = MacAudioHost(channel: d, useHAL: false, automaticPositions: false)
    defer { replacement.shutdown() }
    var called = false
    XCTAssertThrowsError(try driver.restore(on: c) { _ in called = true; throw AudioError.configuration })
    XCTAssertTrue(called); XCTAssertNil(oldRing)
    XCTAssertNil(driver.snapshot(.playback).ring)
    try replacement.attach(driver.makeLink(.playback, configuration: config, capacity: 8))
    try driver.open(.playback); try driver.configure(.playback); try driver.start(.playback)
    XCTAssertEqual(driver.lastStatus, 0)
    try driver.stop(.playback)
    try driver.restore(on: c)
    XCTAssertEqual(driver.snapshot(.playback).state, .stopped)
    XCTAssertNil(driver.snapshot(.playback).ring)
  }

  func testEmptyLinkedPlaybackAndCaptureRoundTrip() throws {
    let (a,b) = LoopbackChannel.pair()
    let driver = MacAudioDriver(channel: a)
    let host = MacAudioHost(channel: b, useHAL: false, automaticPositions: false)
    defer { host.shutdown() }
    for endpoint in AudioEndpoint.allCases {
      try host.attach(driver.makeLink(endpoint, configuration: config, capacity: 8))
      try driver.open(endpoint); try driver.configure(endpoint); try driver.start(endpoint)
      XCTAssertEqual(driver.lastStatus, 0)
    }
    var output = [Float](repeating: 99, count: 4)
    output.withUnsafeMutableBufferPointer { XCTAssertEqual(host.playback!.render(into: $0, frames: 2, timestampNs: 10), 0) }
    XCTAssertEqual(output, [0,0,0,0])
    let input: [Float] = [0.25,-0.25,0.5,-0.5]
    input.withUnsafeBufferPointer { XCTAssertEqual(host.capture!.capture($0, frames: 2, timestampNs: 11), 2) }
    output.withUnsafeMutableBufferPointer { XCTAssertEqual(driver.snapshot(.capture).ring!.read(into: $0, frames: 2), 2) }
    XCTAssertEqual(output, input)
    host.flushPositions(); XCTAssertEqual(driver.capturePosition, 2)
    try driver.drain()
    output.withUnsafeMutableBufferPointer { _ = host.playback!.render(into: $0, frames: 2, timestampNs: 12) }
    host.flushPositions()
    XCTAssertNil(host.playback); XCTAssertNil(driver.snapshot(.playback).ring)
    XCTAssertEqual(driver.snapshot(.playback).state, .stopped)
  }
}
