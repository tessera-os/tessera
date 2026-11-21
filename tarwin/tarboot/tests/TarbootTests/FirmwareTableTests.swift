import KCore
import Testing

@testable import Tarboot

private struct Bytes: ByteSource {
  var data: [UInt8]
  func byteCount() -> UInt64 { UInt64(data.count) }
  func byteAt(_ i: UInt64) -> UInt8 { data[Int(i)] }
  mutating func seal(at i: Int, through n: Int) {
    data[i] = 0
    data[i] = 0 &- data.prefix(n).reduce(0, &+)
  }
}

@Test func acpiRootChecksBothChecksumsAndTableExtent() {
  var root = Bytes(data: Array(repeating: 0, count: 36))
  root.data.replaceSubrange(0..<8, with: "RSD PTR ".utf8)
  root.data[15] = 2
  root.data[20] = 36
  root.data[25] = 1
  root.seal(at: 8, through: 20)
  root.seal(at: 32, through: 36)
  #expect(xsdtAddress(root) == 256)
  for index in [0, 8, 15, 20, 25, 32, 35] {
    var bad = root
    bad.data[index] ^= 1
    #expect(xsdtAddress(bad) == nil)
  }
  root.data[25] = 0
  root.seal(at: 32, through: 36)
  #expect(xsdtAddress(root) == nil)
  var xsdt = Bytes(data: Array(repeating: 0, count: 44))
  xsdt.data.replaceSubrange(0..<4, with: "XSDT".utf8)
  xsdt.data[4] = 44
  xsdt.data[8] = 1
  xsdt.data[36] = 128
  xsdt.seal(at: 9, through: 44)
  #expect(validXSDT(xsdt))
  var truncated = xsdt
  truncated.data.removeLast()
  #expect(!validXSDT(truncated))
  for index in [0, 4, 9, 36] {
    var bad = xsdt
    bad.data[index] ^= 1
    #expect(!validXSDT(bad))
  }
  xsdt.data[36] = 0
  xsdt.seal(at: 9, through: 44)
  #expect(!validXSDT(xsdt))
}
