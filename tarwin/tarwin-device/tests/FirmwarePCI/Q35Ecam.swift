#if arch(x86_64)
  import KCore
  import TarwinDevice

  private typealias GetTable =
    @convention(c) (
      UInt, UnsafeMutablePointer<UnsafeRawPointer?>, UnsafeMutablePointer<UInt32>,
      UnsafeMutablePointer<UInt>
    ) -> UInt
  private struct Sdt: ByteSource {
    let p: UnsafeRawPointer, size: UInt64
    func byteCount() -> UInt64 { size }
    func byteAt(_ i: UInt64) -> UInt8 {
      precondition(i < size)
      return p.load(fromByteOffset: Int(i), as: UInt8.self)
    }
  }

  // Firmware supplies the SDT buffers. Cross-check MCFG against the *enabled*
  // host-bridge register before reading even one dword via EFI CPU I/O.
  func checkQ35Ecam(locate: Locate, root: UnsafeRawPointer, read: PciRead, function: PciFunction)
    -> Bool
  {
    func host(_ offset: UInt64) -> UInt32? {
      var value: UInt32 = 0
      return read(root, 2, offset, 1, &value) == 0 ? value : nil
    }
    func proto(_ a: UInt64, _ b: UInt64) -> UnsafeRawPointer? {
      var guid = (a, b)
      var object: UnsafeRawPointer?
      return withUnsafeBytes(of: &guid, { locate($0.baseAddress!, nil, &object) }) == 0
        ? object : nil
    }
    guard host(0) == 0x29c0_8086, let lo = host(0x60), let hi = host(0x64), lo & 1 == 1,
      (lo >> 1) & 3 < 3
    else { return false }
    let size = UInt64(256 << 20) >> ((lo >> 1) & 3)
    let base = UInt64(hi) << 32 | UInt64(lo & ~7)
    let aperture = DeviceRange(base: base, length: size)
    guard base != 0, deviceAligned(base, size), aperture.valid(),
      let sdt = proto(0x49c6_cfdf_eb97_088e, 0x860e_b2a5_06d9_4bbe),
      let table = sdt.load(fromByteOffset: 8, as: GetTable?.self),
      let cpu = proto(0x4c0e_ae5f_ad61_f191, 0x4fc6_88d2_69e8_fab9),
      let memRead = cpu.load(as: PciRead?.self)
    else { return false }
    var found: FirmwareEcam?
    for i: UInt in 0..<256 {
      var raw: UnsafeRawPointer?
      var version: UInt32 = 0
      var key: UInt = 0
      let status = table(i, &raw, &version, &key)
      if status == (UInt(1) << 63) | 14 {
        guard
          let address = found?.address(
            bus: function.bus, device: function.device, function: function.functionNumber,
            register: 0, width: 4)
        else { return false }
        var id: UInt32 = 0
        return memRead(cpu, 2, address, 1, &id) == 0 && id == function.identity
      }
      guard status == 0, let raw else { return false }
      guard raw.loadUnaligned(as: UInt32.self) == 0x4746_434d else { continue }
      let length = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
      guard found == nil,
        let window = firmwareEcam(
          Sdt(p: raw, size: UInt64(length)), segment: 0, bus: UInt8(function.bus),
          reservedRegisters: { aperture.contains($0) && $0.base == base })
      else { return false }
      found = window
    }
    return false
  }
#endif
