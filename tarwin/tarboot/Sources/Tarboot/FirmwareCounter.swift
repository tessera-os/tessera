#if arch(arm64) || arch(riscv64) || (arch(x86_64) && (os(Windows) || TARBOOT_EFI_PE_COFF))
  typealias TPMSubmit =
    @convention(c) (UnsafeRawPointer, UInt32, UnsafeRawPointer, UInt32, UnsafeMutableRawPointer) ->
    UInt

  private func put(_ n: UInt32, _ at: Int, _ bytes: inout UnsafeMutableRawBufferPointer) {
    bytes.storeBytes(of: n.bigEndian, toByteOffset: at, as: UInt32.self)
  }
  func counterPublic(_ b: UnsafeRawBufferPointer, index: UInt32, name: UnsafeRawBufferPointer)
    -> Bool
  {
    guard b.count == 62, name.count == 32 else { return false }
    func u16(_ p: Int) -> UInt16 {
      UInt16(bigEndian: b.loadUnaligned(fromByteOffset: p, as: UInt16.self))
    }
    func u32(_ p: Int) -> UInt32 {
      UInt32(bigEndian: b.loadUnaligned(fromByteOffset: p, as: UInt32.self))
    }
    // Fixed provisioned profile: platform-created PPWRITE counter, AUTHREAD,
    // NO_DA, already written. No ordinary writes, owner writes or clearing on reset.
    guard u16(0) == 0x8001, u32(2) == 62, u32(6) == 0, u16(10) == 14, u32(12) == index,
      u16(16) == 0x000b, u32(18) == 0x6204_0011, u16(22) == 0, u16(24) == 8,
      u16(26) == 34, u16(28) == 0x000b
    else { return false }
    for i in 0..<32 where b[30 + i] != name[i] { return false }
    return true
  }
  func counterValue(_ b: UnsafeRawBufferPointer) -> UInt64? {
    guard b.count == 29, UInt16(bigEndian: b.loadUnaligned(as: UInt16.self)) == 0x8002,
      UInt32(bigEndian: b.loadUnaligned(fromByteOffset: 2, as: UInt32.self)) == 29,
      b.loadUnaligned(fromByteOffset: 6, as: UInt32.self) == 0,
      UInt32(bigEndian: b.loadUnaligned(fromByteOffset: 10, as: UInt32.self)) == 10,
      UInt16(bigEndian: b.loadUnaligned(fromByteOffset: 14, as: UInt16.self)) == 8,
      b[24] == 0, b[25] == 0, b[26] <= 1, b[27] == 0, b[28] == 0
    else { return nil }
    return UInt64(bigEndian: b.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
  }
  extension FirmwareTCG {
    // SubmitCommand belongs to the same trusted, live TCG2 table as GetCapability.
    // Only an empty read password is used; there is no provisioning/write path.
    @available(macOS 26, *)
    func securityFloor(index: UInt32, name: UnsafeRawBufferPointer) -> UInt64? {
      guard index >> 24 == 1, name.count == 32,
        let submit = instance.load(fromByteOffset: 24, as: TPMSubmit?.self)
      else { return nil }
      var publicCmd: InlineArray<14, UInt8> = [128, 1, 0, 0, 0, 14, 0, 0, 1, 105, 0, 0, 0, 0]
      var publicReply = InlineArray<62, UInt8>(repeating: 0xff)
      let valid = withUnsafeMutableBytes(of: &publicCmd) { c in
        var c = c
        put(index, 10, &c)
        return withUnsafeMutableBytes(of: &publicReply) { r in
          submit(instance, 14, c.baseAddress!, 62, r.baseAddress!) == 0
            && counterPublic(UnsafeRawBufferPointer(r), index: index, name: name)
        }
      }
      guard valid else { return nil }
      var cmd: InlineArray<35, UInt8> = [
        128, 2, 0, 0, 0, 35, 0, 0, 1, 78, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9,
        64, 0, 0, 9, 0, 0, 0, 0, 0, 0, 8, 0, 0,
      ]
      var reply = InlineArray<29, UInt8>(repeating: 0xff)
      return withUnsafeMutableBytes(of: &cmd) { c in
        var c = c
        put(index, 10, &c)
        put(index, 14, &c)
        return withUnsafeMutableBytes(of: &reply) { r in
          guard submit(instance, 35, c.baseAddress!, 29, r.baseAddress!) == 0 else { return nil }
          return counterValue(UnsafeRawBufferPointer(r))
        }
      }
    }
  }
#endif
