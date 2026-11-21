#if TARBOOT_TEST_TRANSLATION
  import TarwinArchAarch64

  @_extern(c, "tarboot_test_sign_ia")
  private func signIA(_ target: UInt64, _ modifier: UInt64, _ lo: UInt64, _ hi: UInt64) -> UInt64
  @_extern(c, "tarboot_test_auth_ia")
  private func authIA(_ signed: UInt64, _ modifier: UInt64, _ lo: UInt64, _ hi: UInt64) -> UInt64

  @_extern(c, "tarboot_test_translation")
  private func walk(
    _ root: UInt64, _ va: UInt64, _ par: UnsafeMutablePointer<UInt64>,
    _ kernel: UInt64, _ kva: UInt64
  ) -> UInt64

  // Dedicated firmware allocation remains pinned after exit. No untrusted
  // code, user pointers or user instructions are involved in this test.
  func checkUserTranslation(base: UInt64, length: UInt64) -> Bool {
    let skip = (0 &- base) & 16383
    guard skip <= length, 13 * 16384 <= length - skip else { return false }
    let root = base + skip
    guard let p = UnsafeMutableRawPointer(bitPattern: UInt(root)),
      var tables = ArmUserTranslation(backing: .init(start: p, count: 4 * 16384), physical: root)
    else { return false }
    let va: UInt64 = 1 << 32
    let rx = root + 4 * 16384
    let rw = rx + 16384
    guard tables.insert(virtual: va, physical: rx, write: false, execute: true),
      tables.insert(virtual: va + 16384, physical: rw, write: true, execute: false),
      tables.insert(virtual: va + 32768, physical: root + 12 * 16384, write: true, execute: false)
    else { return false }
    let target = va + 16, slot = va + 32776
    let modifier = slot | (0x5678 << 48)
    let frame = UnsafeMutableRawBufferPointer(start: p + 12 * 16384, count: 16384)
    frame.storeBytes(of: UInt64(0), toByteOffset: 8, as: UInt64.self)
    // Public test constants, NOT process keys or a signed framework image.
    let lo: UInt64 = 0x1318_faec_4190_9843, hi: UInt64 = 0xd46c_d810_33b4_9281
    guard tables.bindPrivateImport(slot: slot, target: target, modifier: modifier,
      libraryCode: va..<va+20, relro: va+32768..<va+49152, frame: frame,
      physical: root + 12 * 16384, sign: { signIA($0, $1, lo, hi) }),
      frame.load(fromByteOffset: 8, as: UInt64.self) != target,
      authIA(frame.load(fromByteOffset: 8, as: UInt64.self), modifier, lo, hi) == target
    else { return false }
    let kva: UInt64 = 0xffff_8000_0000_0000
    let kernel = root + 6 * 16384
    let code = kernel + 4 * 16384
    let stack = code + 16384
    guard
      var privileged = ArmKernelTranslation(
        backing: .init(
          start: p + 6 * 16384,
          count: 4 * 16384), physical: kernel),
      privileged.insert(virtual: kva, physical: code, write: false, execute: true),
      privileged.insert(virtual: kva + 16384, physical: stack, write: true, execute: false)
    else { return false }
    var results = InlineArray<12, UInt64>(repeating: .max)
    guard
      withUnsafeMutableBytes(
        of: &results,
        {
          walk(root, va, $0.bindMemory(to: UInt64.self).baseAddress!, kernel, kva) == 1
        })
    else { return false }
    let address: UInt64 = 0x0000_ffff_ffff_f000
    return results[0] & 1 == 0 && results[0] & address == rx
      && results[1] & 0x7f == 0x1f  // permission fault at level 3
      && results[2] & 1 == 0 && results[2] & address == rw
      && results[3] & 0x7f == 0x0f  // translation fault at level 3
      && results[4] & 1 == 0 && results[4] & address == code
      && results[5] & 0x7f == 0x1f && results[6] & 0x7f == 0x1f
      && results[7] & 1 == 0 && results[7] & address == stack
      && results[8] & 0x7f == 0x1f && results[9] & 0x7f == 0x0f
      && results[10] & 1 == 0 && results[10] & address == root + 12 * 16384
      && results[11] & 0x7f == 0x1f
  }
#endif
