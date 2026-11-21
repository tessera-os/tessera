#if TARBOOT_TEST_W1_EVIDENCE
  import Tarboot
  import TarwinLoader
  import TarwinW0Verify

  // Negative transport test only. No pin, SDK authorization or valid
  // signature is compiled in; no path from here to measurement or entry.
  private var expected: StaticString { "not-a-signature" }
  nonisolated(unsafe) private var work = InlineArray<704, SIMD2<UInt64>>(repeating: .zero)
  private var absent: UnsafeRawBufferPointer { .init(start: nil, count: 0) }
  private var policy: W0Policy {
    .init(machine: 183, baselineSupported: false, trustedUTC: nil, train: (26, 11, 1),
      tir: (26, 11, 2), addressLimit: 1 << 30, securityFloor: nil, slot: 0, debugEmulator: true)
  }
  private var contract: EarlyRIDLContract {
    .init(uuid: absent, symbol: absent, textSHA256: absent, typeTag: 0)
  }

  func refusesFirmwareKernel(
    _ archive: UnsafeRawBufferPointer, services: borrowing FirmwareBootServices
  ) -> Bool {
    var bytes = InlineArray<16, UInt8>(repeating: 0xcc)
    return withUnsafeMutableBytes(of: &bytes) { dest in
      withUnsafeMutableBytes(of: &work) { scratch in
        func refused(_ pin: UnsafeRawBufferPointer) -> Bool {
          QEMUW1Evidence.firmwareKernel(archive: archive, services: services, into: dest,
            enrollment: pin, systemEnrollment: absent, policy: policy, contract: contract,
            scratch: scratch) == nil
        }
        guard refused(.init(dest)), dest[0] == 0xcc, refused(absent), dest[15] == 0xcc else { return false }
        for i in 0..<expected.utf8CodeUnitCount where dest[i] != expected.utf8Start[i] { return false }
        return true
      }
    }
  }

  func exerciseW1Evidence(
    block: UnsafeRawBufferPointer, at base: UInt64, map: UnsafeRawBufferPointer,
    archive: UnsafeRawBufferPointer, at physical: UInt64
  ) -> Bool {
    var bytes = InlineArray<16, UInt8>(repeating: 0xcc)
    return withUnsafeMutableBytes(of: &bytes) { dest in
      return withUnsafeMutableBytes(of: &work) { scratch in
        func refused(_ address: UInt64, _ pin: UnsafeRawBufferPointer,
          _ out: UnsafeMutableRawBufferPointer) -> Bool {
          var cfg = QEMUVirtConfig(mapped: UnsafeRawPointer(bitPattern: 0x0902_0000)!)
          return QEMUW1Evidence.verify(block: block, at: base, map: map, at: base + 4096,
            archive: archive, at: address, reader: &cfg, into: out,
            enrollment: pin, systemEnrollment: absent, policy: policy, contract: contract,
            scratch: scratch) == nil
        }
        guard refused(physical + 1, absent, dest), dest[0] == 0xcc,
          refused(physical, .init(dest), dest), dest[0] == 0xcc,
          refused(physical, absent, .init(rebasing: scratch[..<16])), scratch[0] == 0,
          refused(physical, absent, dest), dest[15] == 0xcc else { return false }
        for i in 0..<expected.utf8CodeUnitCount where dest[i] != expected.utf8Start[i] { return false }
        return true
      }
    }
  }
#endif
