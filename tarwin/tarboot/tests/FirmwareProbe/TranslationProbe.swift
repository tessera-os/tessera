#if TARBOOT_TEST_TRANSLATION
  import TarwinArchAarch64

  @_extern(c, "tarboot_test_translation")
  private func walk(_ root: UInt64, _ va: UInt64, _ par: UnsafeMutablePointer<UInt64>) -> UInt64

  // Dedicated firmware allocation remains pinned after exit. No untrusted
  // code, user pointers or user instructions are involved in this test.
  func checkUserTranslation(base: UInt64, length: UInt64) -> Bool {
    let skip = (0 &- base) & 16383
    guard skip <= length, 6 * 16384 <= length - skip else { return false }
    let root = base + skip
    guard let p = UnsafeMutableRawPointer(bitPattern: UInt(root)),
      var tables = ArmUserTranslation(backing: .init(start: p, count: 4 * 16384), physical: root)
    else { return false }
    let va: UInt64 = 1 << 32
    let rx = root + 4 * 16384
    let rw = rx + 16384
    guard tables.insert(virtual: va, physical: rx, write: false, execute: true),
      tables.insert(virtual: va + 16384, physical: rw, write: true, execute: false)
    else { return false }
    var results = InlineArray<4, UInt64>(repeating: .max)
    guard
      withUnsafeMutableBytes(
        of: &results,
        {
          walk(root, va, $0.bindMemory(to: UInt64.self).baseAddress!) == 1
        })
    else { return false }
    let address: UInt64 = 0x0000_ffff_ffff_f000
    return results[0] & 1 == 0 && results[0] & address == rx
      && results[1] & 0x7f == 0x1f  // permission fault at level 3
      && results[2] & 1 == 0 && results[2] & address == rw
      && results[3] & 0x7f == 0x0f  // translation fault at level 3
  }
#endif
