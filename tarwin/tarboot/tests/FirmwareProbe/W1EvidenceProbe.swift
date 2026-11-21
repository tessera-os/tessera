#if TARBOOT_TEST_W1_EVIDENCE
  import Tarboot
  import TarwinLoader
  import TarwinW0Verify

  // Negative transport test only. No pin, SDK authorization or valid
  // signature is compiled in; no path from here to measurement or entry.
  private var expected: StaticString { "not-a-signature" }
  #if TARBOOT_TEST_FIXED_RNG
  import TarwinKernelRandom
  func emit(_ marker: StaticString) -> Bool { reportFixedMarker(marker) }
  func emitW1Refusal() -> Bool { emit("TARWIN-W1-EVIDENCE-COPIED-UNAUTHORIZED\r\n") }
  #endif
  nonisolated(unsafe) private var work = InlineArray<704, SIMD2<UInt64>>(repeating: .zero)
  private var absent: UnsafeRawBufferPointer { .init(start: nil, count: 0) }
  private var policy: W0Policy {
    .init(machine: 183, baselineSupported: false, trustedUTC: nil, train: (26, 11, 1),
      tir: (26, 11, 2), addressLimit: 1 << 30, securityFloor: nil, slot: 0, debugEmulator: true)
  }
  private var contract: EarlyRIDLContract {
    .init(uuid: absent, symbol: absent, textSHA256: absent, typeTag: 0)
  }

  #if TARBOOT_TEST_COLD_FENCE
  import TarwinDevice
  func exerciseColdEvidence(pages: borrowing FirmwareBootServices.ColdWorkspace,
    block: UnsafeRawBufferPointer, map: UnsafeRawBufferPointer, archive: UnsafeRawBufferPointer) -> Bool {
    var bytes = InlineArray<16, UInt8>(repeating: 0xcc)
    return withUnsafeMutableBytes(of: &bytes) { dest in
      withUnsafeMutableBytes(of: &work) { scratch in
        var refusal: VirtBootFenceResult?
        var cfg = QEMUVirtConfig(mapped: UnsafeRawPointer(bitPattern: 0x0902_0000)!)
        #if TARBOOT_TEST_HIGH_PCI
        let layout = VirtBootPCILayout.virt11High512GiB
        #else
        let layout = VirtBootPCILayout.lowOnly
        #endif
        guard QEMUW1Evidence.coldBootSet(work: pages, layout: layout, block: block, map: map,
          archive: archive, reader: &cfg, into: dest, enrollment: absent, systemEnrollment: absent,
          policy: policy, contract: contract, scratch: scratch, afterFence: {
            #if TARBOOT_TEST_FIXED_RNG
              var profile: W1HandoffProfile?
              guard let fixed = readFixedClaim(), exerciseFixedRandom(block: block,
                at: UInt64(UInt(bitPattern: block.baseAddress)), map: map, id: fixed,
                beforeRetirement: { launch in
                  profile = W1HandoffProfile(nonRestorable: launch)
                  return profile != nil
                }) else { return nil }
              return profile
            #else
              return .ordinary
            #endif
          }, onRefusal: { refusal = $0 }) == nil,
          dest[15] == 0xcc else { return false }
        if let refusal {
          let marker: StaticString
          switch refusal {
          case .unsupported: marker = "TARWIN-FENCE-REFUSED-PLATFORM\r\n"
          case .drainFailed: marker = "TARWIN-FENCE-REFUSED-DRAIN\r\n"
          case .abortFailed: marker = "TARWIN-FENCE-REFUSED-ABORT\r\n"
          case .syncFailed: marker = "TARWIN-FENCE-REFUSED-SYNC\r\n"
          case .tableFailed: marker = "TARWIN-FENCE-REFUSED-TABLE\r\n"
          case .badMemory: marker = "TARWIN-FENCE-REFUSED-PAGES\r\n"
          case .streamsDenied: return false
          }
          for i in dest.indices where dest[i] != 0xcc { return false }
          return emit(marker) && reportFenceState()
        }
        for i in 0..<expected.utf8CodeUnitCount where dest[i] != expected.utf8Start[i] { return false }
        return emit("TARWIN-FENCE-STREAMS-DENIED\r\n") && emitW1Refusal()
      }
    }
  }
  #endif

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
