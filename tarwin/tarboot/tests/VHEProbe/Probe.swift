import TarwinArchAarch64

@_extern(c, "tarwin_w1_load_user_word")
private func load(_ address: UInt64, _ word: UnsafeMutablePointer<UInt64>) -> UInt32

@_extern(c, "tarwin_w1_store_user_word")
private func store(_ address: UInt64, _ word: UInt64) -> UInt32

// Called on a private host stack. The diagnostic never enters EL0.
@_cdecl("tarwin_vhe_copy_probe")
public func probe() -> Int32 {
  let base: UInt64 = 1 << 32
  var pair = InlineArray<2, UInt64>(repeating: .max)
  return withUnsafeMutableBytes(of: &pair) { bytes in
    let words = bytes.bindMemory(to: UInt64.self)
    func copy(_ at: UInt64) -> Bool {
      copyArmUserWords(from: at, range: base..<base + 5 * 16384, into: words) {
        load($0, $1) == 1
      }
    }
    func write(_ at: UInt64) -> Bool {
      writeArmUserWords(to: at, range: base..<base + 5 * 16384, from: .init(words)) {
        store($0, $1) == 1
      }
    }
    guard copy(base), words[0] == 0x1234, words[1] == 0x5678 else { return 1 }
    // Last word is readable; the next page faults. No partial result survives.
    guard !copy(base + 16384 - 8), words[0] == 0 && words[1] == 0 else { return 2 }
    guard !copy(base + 32768), words[0] == 0 && words[1] == 0 else { return 3 }
    words[0] = 0xabcd
    words[1] = 0x9876
    let rw = base + 3 * 16384
    guard write(rw), copy(rw), words[0] == 0xabcd, words[1] == 0x9876 else { return 4 }
    guard !write(base), !write(base + 16384), !write(base + 32768),
      copy(base), words[0] == 0x1234, words[1] == 0x5678
    else { return 5 }
    guard !write(rw + 16384 - 8), !write(rw + 3), !write(base - 8) else { return 6 }
    return 0
  }
}
