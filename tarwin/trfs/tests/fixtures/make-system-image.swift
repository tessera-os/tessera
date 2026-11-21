// Independent hosted TRFS v1 vector. Run: swift make-system-image.swift OUTDIR
import CryptoKit
import Foundation

precondition(CommandLine.arguments.count == 2)
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let zero = Data(repeating: 0, count: 4096)
let count = 256
var sectors = Array(repeating: zero, count: count)

func le(_ n: Int) -> Data {
  withUnsafeBytes(of: UInt64(n).littleEndian) { Data($0) }
}

func ref(_ index: Int) -> Data {
  index == 0 ? Data(repeating: 0, count: 40) : le(index) + Data(SHA256.hash(data: sectors[index]))
}

func record(_ index: Int, tag: UInt8, subtype: UInt8 = 0, object: Int, value: Int = 0,
            previous: Int = 0, blob: Int = 0, name: String = "") {
  let bytes = Data(name.utf8)
  var p = zero
  p[0..<8] = Data([84, 82, 70, 78, 0, 0, 1, 0])
  p[8..<16] = le(object)
  p[24..<32] = le(value)
  p[32..<72] = ref(previous)
  p[72..<112] = ref(blob)
  p[112] = tag
  p[113] = subtype
  p[114] = UInt8(bytes.count)
  p[128..<(128 + bytes.count)] = bytes
  sectors[index] = p
}

func anchor(generation: Int, head: Int) {
  var p = zero
  p[0..<8] = Data([84, 82, 70, 83, 0, 0, 1, 0])
  p[8..<32] = le(generation) + le(head + 1) + le(count)
  p[32..<72] = ref(head)
  p[4064..<4096] = Data(SHA256.hash(data: p[..<4064]))
  sectors[generation % 2] = p
}

record(2, tag: 2, subtype: 1, object: 2)
record(3, tag: 1, object: 1, value: 2, previous: 2, name: "system-version")
anchor(generation: 2, head: 3)
sectors[4] = Data((0..<4096).map { UInt8(truncatingIfNeeded: ($0 >> 4) ^ $0) })
record(5, tag: 3, object: 2, previous: 3, blob: 4)
record(6, tag: 2, subtype: 1, object: 2, value: 4096, previous: 5)
anchor(generation: 3, head: 6)

let image = sectors.reduce(into: Data()) { $0.append($1) }
let root = Data(SHA256.hash(data: sectors[6]))
precondition(root.map { String(format: "%02x", $0) }.joined()
  == "acf8e329e980f5ea2530ad42c29d5343b05a7339f31883c6d60981d36e2321e3")
try image.write(to: output.appendingPathComponent("system.trfs"), options: .withoutOverwriting)
try root.write(to: output.appendingPathComponent("system.trfs.root"), options: .withoutOverwriting)
