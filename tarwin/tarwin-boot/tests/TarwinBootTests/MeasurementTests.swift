import Foundation
import KCore
import TarwinBoot
import Testing

struct HostBytes: ByteBuffer {
  var bytes: [UInt8]
  init(_ bytes: [UInt8]) { self.bytes = bytes }
  init(count: Int) { self.init(Array(repeating: 0, count: count)) }
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ offset: UInt64) -> UInt8 { bytes[Int(offset)] }
  mutating func putByte(_ offset: UInt64, value: UInt8) { bytes[Int(offset)] = value }
}

struct TestPort: TpmPort {
  var buffer = HostBytes(count: 65)
  var submits = 0
  var responds = true
  static let success: [UInt8] = [128, 2, 0, 0, 0, 19, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0]
  func byteCount() -> UInt64 { buffer.byteCount() }
  func byteAt(_ offset: UInt64) -> UInt8 { buffer.byteAt(offset) }
  mutating func putByte(_ offset: UInt64, value: UInt8) { buffer.putByte(offset, value: value) }
  mutating func submit(_ count: UInt64) -> UInt64 {
    precondition(count == 65 && buffer.byteAt(9) == 130)
    submits += 1
    guard responds else { return 0 }
    buffer.bytes.replaceSubrange(0..<19, with: Self.success)
    return 19
  }
}

@Test func measuredBoot() {
  let digest = HostBytes(Array(0..<32))
  let event = HostBytes(Array("abc".utf8))
  var log = HostBytes(count: 54)
  var port = TestPort()
  var cursor = MeasurementLog(used: 1, stopped: false)
  #expect(extendAndRecord(&port, state: &cursor, log: &log, pcr: 8, digest: digest, event: event))
  #expect(cursor.used == 54)
  #expect(!cursor.stopped)
  #expect(Array(log.bytes[1..<15]) == [8, 0, 0, 0, 13, 0, 0, 0, 1, 0, 0, 0, 11, 0])
  #expect(Array(log.bytes[15..<47]) == digest.bytes)
  #expect(Array(log.bytes[47...]) == [3, 0, 0, 0, 97, 98, 99])
  #expect(!extendAndRecord(&port, state: &cursor, log: &log, pcr: 9, digest: digest, event: event))
  #expect(cursor.stopped)
  #expect(port.submits == 1)
  cursor = MeasurementLog(used: 0, stopped: false)
  port.responds = false
  #expect(!extendAndRecord(&port, state: &cursor, log: &log, pcr: 9, digest: digest, event: event))
  #expect(cursor.stopped)
  #expect(cursor.used == 0)
  port.responds = true
  #expect(!extendAndRecord(&port, state: &cursor, log: &log, pcr: 9, digest: digest, event: event))
  #expect(port.submits == 2)
  var short = HostBytes(count: 64)
  #expect(encodePcrExtend(8, digest: digest, command: &short) == 0)
  #expect(stagePcrEvent(7, digest: digest, event: event, log: &log, pos: 0) == 0)
  #expect(pcrExtendSucceeded(HostBytes(TestPort.success)))
  var bad = TestPort.success
  bad[8] = 1
  #expect(!pcrExtendSucceeded(HostBytes(bad)))
  #expect(!pcrExtendSucceeded(HostBytes(Array(bad.prefix(10)))))
}
