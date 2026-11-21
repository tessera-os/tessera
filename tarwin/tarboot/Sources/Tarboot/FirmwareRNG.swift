#if arch(arm64) || arch(riscv64) || (arch(x86_64) && (os(Windows) || TARBOOT_EFI_PE_COFF))
  typealias RandomBytes = @convention(c) (UnsafeRawPointer, UnsafeRawPointer?, UInt, UnsafeMutableRawPointer) -> UInt

  // Only live EFI RNG_PROTOCOL tables in the identity mapping. No software
  // fallback, timing-derived data, or firmware addresses as a source of entropy.
  struct FirmwareRNG {
    let table: UnsafeRawPointer
    let generate: RandomBytes

    init?(_ locate: LocateProtocol) {
      var id = (UInt64(0x433d_eade_3152_bca5), UInt64(0x441f_29dc_1cc0_2e86))
      var instance: UnsafeRawPointer?
      guard withUnsafeBytes(of: &id, { locate($0.baseAddress!, nil, &instance) }) == 0,
        let instance, let generate = instance.load(fromByteOffset: 8, as: RandomBytes?.self)
        else { return nil }
      self.table = instance
      self.generate = generate
    }

    static func readSeed(_ locate: LocateProtocol?, into bytes: UnsafeMutableRawBufferPointer) -> Bool {
      guard bytes.count == 64, let p = bytes.baseAddress else { return false }
      var rawAlgorithm = (UInt64(0x4827_b6e8_e431_76d7), UInt64(0x6185_b6c4_fd7f_84b7))
      if let locate, let rng = FirmwareRNG(locate),
        withUnsafeBytes(of: &rawAlgorithm, { rng.generate(rng.table, $0.baseAddress, 64, p) }) == 0 {
        return true
      }
      for i in bytes.indices { bytes[i] = 0 }
      return false
    }

    func word() -> UInt64? {
      var word: UInt64 = 0
      return generate(table, nil, 8, &word) == 0 ? word : nil
    }
  }
#endif
