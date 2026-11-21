import TarwinBoot
import Testing

// hashlib.sha256(bytes(i % 256 for i in range(577))).digest()
private let expectedDigest: [UInt8] = [
  125, 24, 95, 227, 27, 66, 195, 87, 215, 172, 223, 224, 158, 76, 42, 135,
  136, 197, 155, 124, 179, 72, 182, 158, 235, 145, 108, 146, 118, 69, 126, 118,
]

private struct SequencePort: TpmPort {
  var bytes = Array(repeating: UInt8(0), count: 300)
  var consumed: [UInt8] = []
  var codes: [Int] = []
  let fault: Int
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ offset: UInt64) -> UInt8 { bytes[Int(offset)] }
  mutating func putByte(_ offset: UInt64, value: UInt8) { bytes[Int(offset)] = value }
  mutating func submit(_ n: UInt64) -> UInt64 {
    func be(_ at: Int, _ count: Int) -> Int {
      bytes[at..<at + count].reduce(0) { $0 << 8 | Int($1) }
    }
    let code = be(6, 4)
    codes.append(code)
    var result: [UInt8]
    guard be(2, 4) == n else { return 0 }
    switch code {
    case 0x186:
      guard n == 14, be(0, 2) == 0x8001, be(10, 4) == 0x10 else { return 0 }
      result = [0x80, 1, 0, 0, 0, 14, 0, 0, 0, 0, 0x80, 0, 0, 2]
      if fault == 1 { result[10] = 0x40 }
    case 0x15c, 0x185:
      let end = code == 0x185
      let s = end ? 14 : 10
      let at = end ? 42 : 29
      let pw: [UInt8] = [0x40, 0, 0, 9, 0, 0, 0, 0, 0]
      guard be(0, 2) == 0x8002, be(s, 4) == 0x8000_0002,
        be(s + 4, 4) == (end ? 18 : 9), Array(bytes[s + 8..<s + 17]) == pw,
        !end || (be(10, 4) == 10 && Array(bytes[s + 17..<s + 26]) == pw),
        be(at - 2, 2) == Int(n) - at
      else { return 0 }
      consumed += bytes[at..<Int(n)]
      let auth: [UInt8] = [0, 0, 1, 0, 0]
      if end {
        result =
          [0x80, 2, 0, 0, 0, 62, 0, 0, 0, 0, 0, 0, 0, 38, 0, 0, 0, 1, 0, 11] + expectedDigest + auth
          + auth
        if fault == 3 { result[13] = 0 }
        if fault == 4 { result[19] = 12 }
        if fault == 5 { result[61] = 1 }
      } else {
        result = [0x80, 2, 0, 0, 0, 19, 0, 0, 0, 0, 0, 0, 0, 0] + auth
        if fault == 2 { return 0 }
      }
    default: return 0
    }
    bytes.replaceSubrange(..<result.count, with: result)
    return UInt64(result.count)
  }
}

@Test func measuresExactlyOneImageAndNeverPublishesAnAmbiguousEvent() {
  let image = (0..<577).map { UInt8(truncatingIfNeeded: $0) }
  let spec =
    Array("Spec ID Event03".utf8) + [0] + [0, 0, 0, 0, 0, 2, 0, 2, 1, 0, 0, 0, 11, 0, 32, 0, 0]
  var header = [UInt8](repeating: 0, count: 32)
  header[4] = 3
  header[28] = UInt8(spec.count)
  header += spec
  for fault in 0...7 {
    var log = header + Array(repeating: UInt8(0xa5), count: fault == 6 ? 4 : 100)
    if fault == 7 { log[4] = 0 }
    let prefix = Array(log.prefix(header.count))
    var port = SequencePort(fault: fault)
    var state = MeasurementLog(used: UInt64(header.count), stopped: false)
    func run() -> Bool {
      image.withUnsafeBytes { im in
        log.withUnsafeMutableBytes {
          measureEarlyProcess(im, port: &port, state: &state, log: $0, label: "init probe")
        }
      }
    }
    let ok = run()
    #expect(ok == (fault == 0))
    #expect(Array(log.prefix(header.count)) == prefix)
    if ok {
      #expect(port.codes == [0x186, 0x15c, 0x15c, 0x185])
      #expect(port.consumed == image)
      let event = log.withUnsafeBytes { EventLogFormat($0)?.event($0, at: header.count) }
      #expect(event?.pcr == 10 && event?.payload.upperBound == Int(state.used))
      if let e = event { #expect(Array(log[e.sha256..<e.sha256 + 32]) == expectedDigest) }
    } else {
      #expect(state.stopped && state.used == header.count)
      let operations = port.codes
      #expect(!run())
      #expect(port.codes == operations)
      if fault >= 6 { #expect(operations.isEmpty) }
    }
  }
}
