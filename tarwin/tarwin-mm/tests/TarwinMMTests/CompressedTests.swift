import KCore
import TarwinMM

// Host fixture only. No heap access or scratch allocation in the codec.
struct TestBytes: ByteBuffer {
  var data: [UInt8]
  var size: UInt64
  func byteCount() -> UInt64 { size }
  func byteAt(_ offset: UInt64) -> UInt8 {
    precondition(offset < size)
    return data[Int(offset)]
  }
  mutating func putByte(_ offset: UInt64, value: UInt8) {
    precondition(offset < size)
    data[Int(offset)] = value
  }
}

func buffer(_ size: UInt64) -> TestBytes {
  TestBytes(data: Array(repeating: 0, count: Int(size)), size: size)
}

struct TestTable: MatchTable {
  var slots = [UInt16](repeating: 0, count: 4096)
  mutating func clear() { slots = Array(repeating: 0, count: 4096) }
  func previous(_ bucket: UInt16) -> UInt16 { slots[Int(bucket)] }
  mutating func record(_ bucket: UInt16, positionPlusOne: UInt16) {
    slots[Int(bucket)] = positionPlusOne
  }
}

func pageRoundTrip() -> Bool {
  var original = buffer(16384 + 512)
  var packed = buffer(17000)
  var restored = buffer(original.size)
  var table = TestTable()
  var i: UInt64 = 0
  while i < original.size {
    let byte = i < 16384 ? UInt8(i % 37) : UInt8(i & 255)
    original.putByte(i, value: byte)
    i += 1
  }
  let result = compressPage(original, output: &packed, table: &table)
  var ok =
    result.ok && result.count < original.size
    && decompressPage(packed, stored: result.count, output: &restored, logical: original.size)
  i = 0
  while i < original.size {
    if original.byteAt(i) != restored.byteAt(i) { ok = false }
    i += 1
  }
  if decompressPage(packed, stored: result.count - 1, output: &restored, logical: original.size) {
    ok = false
  }
  packed.size = 1
  if compressPage(original, output: &packed, table: &table).ok { ok = false }
  packed.size = 17000
  packed.putByte(0, value: 0)
  packed.putByte(1, value: 0)
  packed.putByte(2, value: 0)
  if decompressPage(packed, stored: 3, output: &restored, logical: 4) { ok = false }
  // liblz4 LZ4_compress_default on 4096 zero bytes (raw block).
  original.size = 4096
  original = buffer(4096)
  let zero = compressPage(original, output: &packed, table: &table)
  if !zero.ok || zero.count != 26 { ok = false }
  i = 0
  while i < 26 {
    var expected: UInt8 = 0
    if i == 0 { expected = 31 }
    if i == 2 { expected = 1 }
    if i >= 4 && i < 19 { expected = 255 }
    if i == 19 { expected = 246 }
    if i == 20 { expected = 80 }
    if packed.byteAt(i) != expected { ok = false }
    i += 1
  }
  return ok
}
