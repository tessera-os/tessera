import KCore
import Testing

@testable import Tarboot

@Test func armPSCIRequiresValidFADTAndUnambiguousBootFlags() {
  var s = Bytes(data: Array(repeating: 0, count: 268))
  s.data.replaceSubrange(0..<4, with: "FACP".utf8)
  s.data[4] = 12
  s.data[5] = 1
  s.data[8] = 5
  s.data[131] = 1
  for (flag, expected): (UInt8, PSCIConduit?) in [(1,.smc),(3,.hvc),(0,nil),(2,nil),(5,nil)] {
    s.data[129] = flag
    s.seal(at: 9, through: 268)
    #expect(fadtPSCI(s) == expected)
  }
  s.data[129] = 1
  s.data[131] = 0
  s.seal(at: 9, through: 268)
  #expect(fadtPSCI(s) == nil)
  s.data[131] = 1 // checksum now stale
  #expect(fadtPSCI(s) == nil)
  s.data.removeLast()
  #expect(fadtPSCI(s) == nil)
}

private struct Bytes: ByteSource {
  var data: [UInt8]
  func byteCount() -> UInt64 { UInt64(data.count) }
  func byteAt(_ i: UInt64) -> UInt8 { data[Int(i)] }
  mutating func seal(at i: Int, through n: Int) {
    data[i] = 0
    data[i] = 0 &- data.prefix(n).reduce(0, &+)
  }
}

@Test func q35GenerationRejectsAlteredAddressMethodEvenWithValidChecksum() {
  // q35 11.1.3 etc/acpi/tables, relocated to a synthetic reserved page.
  let dump = """
    53 53 44 54 ca 00 00 00 01 00 42 4f 43 48 53 20 56 4d 47 45 4e 49 44 00 01 00 00 00
    42 58 50 43 01 00 00 00 08 56 47 49 41 0c 00 20 00 00 10 41 08 5c 5f 53 42 5f 5b 82
    48 07 56 47 45 4e 08 5f 48 49 44 0d 51 45 4d 55 56 47 49 44 00 08 5f 43 49 44 0d 56
    4d 5f 47 65 6e 5f 43 6f 75 6e 74 65 72 00 08 5f 44 44 4e 0d 56 4d 5f 47 65 6e 5f 43
    6f 75 6e 74 65 72 00 14 17 5f 53 54 41 00 70 0a 0f 60 a0 0a 93 56 47 49 41 00 70 00
    60 a4 60 14 20 41 44 44 52 00 70 12 02 02 60 70 72 56 47 49 41 0a 28 00 88 60 00 00
    70 00 88 60 01 00 a4 60 14 19 5c 2e 5f 47 50 45 5f 45 30 35 00 86 5c 2e 5f 53 42 5f
    56 47 45 4e 0a 80
    """
  var table = Bytes(data: dump.split(whereSeparator: { $0.isWhitespace }).map { UInt8($0, radix: 16)! })
  table.seal(at: 9, through: 202)
  #expect(q35GenerationBase(table) == 0x2000)
  for i in [0,4,8,16,36,41,42,65,123,141,162,193,201] {
    var wrong = table
    wrong.data[i] ^= 1
    wrong.seal(at: 9, through: 202)
    #expect(q35GenerationBase(wrong) == nil)
  }
  table.data[9] ^= 1
  #expect(q35GenerationBase(table) == nil)
  table.data.removeLast()
  #expect(q35GenerationBase(table) == nil)
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
