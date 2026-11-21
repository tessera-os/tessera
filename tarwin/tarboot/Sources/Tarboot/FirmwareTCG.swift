#if arch(arm64) || arch(riscv64) || (arch(x86_64) && (os(Windows) || TARBOOT_EFI_PE_COFF))
  typealias LocateProtocol =
    @convention(c) (
      UnsafeRawPointer, UnsafeRawPointer?,
      UnsafeMutablePointer<UnsafeRawPointer?>
    ) -> UInt

  typealias HashLogExtend =
    @convention(c) (UnsafeRawPointer, UInt64, UInt64, UInt64, UnsafeRawPointer) -> UInt
  private typealias Capability = @convention(c) (UnsafeRawPointer, UnsafeMutableRawPointer) -> UInt

  // UEFI TCG2 Protocol, physical identity addressing, before ExitBootServices.
  // The boot loader owns each referenced buffer for the whole firmware call.
  struct FirmwareTCG {
    let instance: UnsafeRawPointer
    let extend: HashLogExtend

    typealias GetLog = @convention(c) (UnsafeRawPointer, UInt32, UnsafeMutablePointer<UInt64>,
      UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt8>) -> UInt

    func logExtent() -> (UInt64,UInt64)? {
      var base: UInt64 = 0, last: UInt64 = 0, truncated: UInt8 = 1
      guard let get = instance.load(fromByteOffset:8, as:GetLog?.self),
        get(instance,2,&base,&last,&truncated) == 0, truncated == 0,
        base > 0, last > base else { return nil }
      return (base,last)
    }

    static func open(_ locate: LocateProtocol) -> FirmwareTCG? {
      var guid = (UInt64(0x42be_7455_607f_766c), UInt64(0x0f72_b26d_d7e4_0b93))
      var protocolPtr: UnsafeRawPointer?
      guard withUnsafeBytes(of: &guid, { locate($0.baseAddress!, nil, &protocolPtr) }) == 0,
        let instance = protocolPtr,
        let get = instance.load(as: Capability?.self),
        let extend = instance.load(fromByteOffset: 16, as: HashLogExtend?.self)
      else { return nil }
      let z: UInt32 = 0
      var caps = (z, z, z, z, z, z, z, z, z)
      let usable = withUnsafeMutableBytes(of: &caps) { bytes in
        bytes[0] = UInt8(bytes.count)
        guard get(instance, bytes.baseAddress!) == 0, bytes[0] >= 36, bytes[1] == 1, bytes[2] >= 1,
          bytes[3] == 1, bytes[4] >= 1, bytes[16] == 1
        else { return false }
        return bytes[8] & 2 != 0 && bytes[12] & 2 != 0 && bytes[32] & 2 != 0
      }
      return usable ? FirmwareTCG(instance: instance, extend: extend) : nil
    }

    // Packed EFI_TCG2_EVENT: total size, 14-byte version-1 header, payload.
    // Flags = 0: hash the whole supplied buffer as data, and log AND extend it.
    func measure(_ bytes: UnsafeRawBufferPointer, pcr: UInt8, label: StaticString) -> Bool {
      guard let base = bytes.baseAddress, !bytes.isEmpty, label.utf8CodeUnitCount <= 32 else {
        return false
      }
      let z: UInt64 = 0
      var event = (z, z, z, z, z, z, z)
      return withUnsafeMutableBytes(of: &event) { raw in
        raw[0] = UInt8(18 + label.utf8CodeUnitCount)
        raw[4] = 14
        raw[8] = 1
        raw[10] = pcr
        raw[14] = 13  // EV_IPL
        for i in 0..<label.utf8CodeUnitCount { raw[18 + i] = label.utf8Start[i] }
        return extend(
          instance, 0, UInt64(UInt(bitPattern: base)), UInt64(bytes.count), raw.baseAddress!) == 0
      }
    }
  }
#endif
