import Testing
import TarwinBoot

private struct CounterPort: TpmPort {
  var data = [UInt8](repeating: 0xaa, count: 64)
  var replies: [[UInt8]]
  var commands: [[UInt8]] = []
  func byteCount() -> UInt64 { UInt64(data.count) }
  func byteAt(_ offset: UInt64) -> UInt8 { data[Int(offset)] }
  mutating func putByte(_ offset: UInt64, value: UInt8) { data[Int(offset)] = value }
  mutating func submit(_ size: UInt64) -> UInt64 {
    commands.append(Array(data[..<Int(size)]))
    let r = replies.removeFirst()
    data.replaceSubrange(0..<r.count, with: r)
    return UInt64(r.count)
  }
}

@Test func requireNamedCounterAndExactAuthenticatedRead() {
  let name = (0..<32).map(UInt8.init)
  let pub: [UInt8] = [128,1,0,0,0,62,0,0,0,0,0,14,1,128,240,1,0,11,98,4,0,17,0,0,0,8,0,34,0,11] + name
  let value: [UInt8] = [128,2,0,0,0,29,0,0,0,0,0,0,0,10,0,8,1,2,3,4,5,6,7,8,0,0,1,0,0]
  func run(_ publicReply: [UInt8], _ valueReply: [UInt8], index: UInt32 = 0x0180_f001,
    capacity: Int = 64) -> (UInt64?, [[UInt8]]) {
    var p = CounterPort(data: .init(repeating: 0xaa, count: capacity), replies: [publicReply, valueReply])
    let floor = name.withUnsafeBytes { readTPMSecurityFloor(&p, index: index, name: $0) }
    return (floor, p.commands)
  }
  let (floor, commands) = run(pub, value)
  #expect(floor == 0x0102_0304_0506_0708)
  #expect(commands == [[128,1,0,0,0,14,0,0,1,105,1,128,240,1],
    [128,2,0,0,0,35,0,0,1,78,1,128,240,1,1,128,240,1,0,0,0,9,64,0,0,9,0,0,0,0,0,0,8,0,0]])
  #expect(run(pub, value, index: 0).1.isEmpty)
  #expect(run(pub, value, capacity: 61).1.isEmpty)
  #expect(run(Array(pub.dropLast()), value).0 == nil)
  for i in pub.indices {
    var bad = pub
    bad[i] ^= 1
    let (v, issued) = run(bad, value)
    #expect(v == nil && issued.count == 1)
  }
  #expect(run(pub, value + [0]).0 == nil)
  for i in value.indices where !(16...23).contains(i) {
    var bad = value
    bad[i] ^= 2
    #expect(run(pub, bad).0 == nil)
  }
}
