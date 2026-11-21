import TarwinLoader
import XCTest

func targetNote(_ target: String, _ features: [String], _ scale: UInt8) -> [UInt8] {
  func field(_ name: String) -> [UInt8] { [UInt8(name.utf8.count), 0] + Array(name.utf8) }
  return field(target) + [UInt8(features.count), 0] + features.flatMap(field) + [
    scale == 0 ? 0 : 1, scale,
  ]
}
let x64Features =
  "cx16 lahf_sahf popcnt sse3 sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 fma f16c lzcnt movbe xsave shstk ibt aes pclmul vaes vpclmulqdq rdrand rdseed erms"
  .split(separator: " ").map(String.init).sorted()
final class BaselineTests: XCTestCase {
  func testExactlyTheNamedBaseline() {
    let arm =
      "crc lse lse2 rdm rcpc rcpc2 jscvt fcma dotprod frintts flagm flagm2 sb ssbs bti pauth fp16"
    let rv =
      "v zba zbb zbs zicond zfa zfhmin zvfhmin zvbb zvkt zawrs zicboz zicbom zicbop zihintntl zihintpause zimop zcmop zcb supm zicfiss zicfilp"
    for (m, n, f, s): (UInt16, String, [String], UInt8) in [
      (183, "aarch64.base", arm.split(separator: " ").map(String.init).sorted(), 1),
      (62, "x64.v3", x64Features, 2),
      (243, "rv64.base", rv.split(separator: " ").map(String.init).sorted(), 0),
    ] {
      func accepts(_ note: [UInt8]) -> Bool {
        note.withUnsafeBytes { matchesW0Baseline($0, machine: m) }
      }
      let good = targetNote(n, f, s)
      XCTAssertTrue(accepts(good))
      XCTAssertFalse(accepts(good + [0]))
      for end in good.indices { XCTAssertFalse(accepts(Array(good[..<end]))) }
      for i in f.indices {
        var missing = f
        missing.remove(at: i)
        XCTAssertFalse(accepts(targetNote(n, missing, s)))
      }
      XCTAssertFalse(accepts(targetNote(n, [], s)))
      XCTAssertFalse(accepts(targetNote(n, f.reversed(), s)))
      XCTAssertFalse(accepts(targetNote(n, f + ["zzz"], s)))
      XCTAssertFalse(accepts(targetNote(n, f, s + 1)))
    }
  }
}
