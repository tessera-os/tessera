#if TARBOOT_TEST_FIFO
  import KCore
  import TarwinBoot
  #if TARBOOT_TEST_GENERATION
    import Tarboot
    import TarwinKernelRandom
    import TarwinRandomCore

    @_extern(c, "tarwin_mmio_write32") private func write32(_ p: UnsafeRawPointer, _ v: UInt32)

    @inline(never) private func refusesRandom(_ seed: UnsafeRawBufferPointer,
      _ sample: UnsafeRawBufferPointer, _ generation: RandomEpoch?) -> Bool {
      if let _ = KernelRandom(policy: .debugQEMU, bootSeed: seed, hardware: sample,
        source: .emulatedTPM, generation: generation) { return false }
      return true
    }

    func uartByte(_ byte: UInt8) -> Bool {
      let uart = UnsafeRawPointer(bitPattern: 0x0900_0000)!
      var polls = 500000
      while read32(uart + 0x18) & 0x20 != 0 {
        polls -= 1
        if polls == 0 { return false }
      }
      write32(uart, UInt32(byte))
      return true
    }
    func emit(_ marker: StaticString) -> Bool {
      for i in 0..<marker.utf8CodeUnitCount where !uartByte(marker.utf8Start[i]) { return false }
      return true
    }
    #if TARBOOT_TEST_W1_EVIDENCE
    func emitW1Refusal() -> Bool { emit("TARWIN-W1-EVIDENCE-COPIED-UNAUTHORIZED\r\n") }
    #endif
    #if TARBOOT_TEST_RESTORE || TARBOOT_TEST_RO_GENID
    import TarwinW1Generation
    @_extern(c, "tarwin_mmio_read64") private func read64(_ p: UnsafeRawPointer) -> UInt64
    private func readWord(_ address: UInt64) -> UInt64? {
      guard let p = UnsafeRawPointer(bitPattern: UInt(address)) else { return nil }
      return read64(p)
    }
    #endif
    func exerciseGeneration(bootSeed: UnsafeRawBufferPointer, regions: UnsafeBufferPointer<FirmwareRegion>) -> Bool {
      var cfg = QEMUVirtConfig(mapped: UnsafeRawPointer(bitPattern: 0x0902_0000)!)
      guard bootSeed.count == 64 else { return false }
      #if TARBOOT_TEST_RESTORE || TARBOOT_TEST_RO_GENID
      #if TARBOOT_TEST_RO_GENID
      let policy = QEMUGenerationPolicy.readOnlyVirt11
      #else
      let policy = QEMUGenerationPolicy.rotatingDevice(pinnedPage: 0x5c74_0000)
      #endif
      guard let source = W1GenerationSource(policy: policy, reader: &cfg,
        regions: regions, readWord: readWord),
        let first = source.current(readWord: readWord) else { return false }
      #else
      guard case .unavailable = qemuGenerationDevice(&cfg) else { return false }
      #endif
      var command = InlineArray<1100, UInt8>(repeating: 0)
      var sample = InlineArray<32, UInt8>(repeating: 0)
      defer { sample = .init(repeating: 0) }
      return withUnsafeMutableBytes(of: &command, { raw in
        guard var port = TPMFIFO(registers: VirtFIFO(), scratch: raw, pollLimit: 500000),
          readTPMEntropy32(&port, into: &sample) else { return false }
        #if TARBOOT_TEST_RESTORE || TARBOOT_TEST_RO_GENID
        guard var rng = withUnsafeBytes(of: &sample, { KernelRandom(policy: .debugQEMU,
          bootSeed: bootSeed, hardware: $0, source: .emulatedTPM, generation: first) }),
          rng.word(generation: source.current(readWord: readWord)) != nil
        else { return false }
        #if TARBOOT_TEST_RESTORE
        guard emit("TARWIN-VMGEN-SNAPSHOT-READY\r\n") else { return false }
        while source.current(readWord: readWord) == first {}
        guard let next = source.current(readWord: readWord), next != first, rng.word(generation: next) == nil,
          rng.word(generation: first) == nil, readTPMEntropy32(&port, into: &sample),
          withUnsafeBytes(of: &sample, { rng.reseed(hardware: $0, source: .emulatedTPM, generation: next) }),
          rng.word(generation: source.current(readWord: readWord)) != nil else { return false }
        return emit("TARWIN-VMGEN-RESTORED-REFUSED-RESEEDED\r\n")
        #else
        return emit("TARWIN-COLD-VMGEN-ACCEPTED\r\n")
        #endif
        #else
        return withUnsafeBytes(of: &sample) { refusesRandom(bootSeed, $0, nil) }
          && emit("TARWIN-NO-VMGEN-RNG-REFUSED\r\n")
        #endif
      })
    }
  #endif

  @_extern(c, "tarwin_mmio_read8") private func read8(_ p: UnsafeRawPointer) -> UInt8
  @_extern(c, "tarwin_mmio_read32") private func read32(_ p: UnsafeRawPointer) -> UInt32
  @_extern(c, "tarwin_mmio_write8") private func write8(_ p: UnsafeRawPointer, _ v: UInt8)

  // This diagnostic is bound ONLY to the QEMU virt platform-bus with a
  // single tpm-tis-device at bus offset zero (see runner). Not discovery.
  private struct VirtFIFO: TPMFIFORegisters {
    let base = UnsafeRawPointer(bitPattern: 0x0c00_0000)!
    func access() -> UInt8 { read8(base) }
    func setAccess(_ v: UInt8) { write8(base, v) }
    func status() -> UInt32 { read32(base + 0x18) }
    func setStatus(_ v: UInt8) { write8(base + 0x18, v) }
    func receive() -> UInt8 { read8(base + 0x24) }
    func send(_ v: UInt8) { write8(base + 0x24, v) }
  }

  func exerciseKernelFIFO(
    _ fixture: UnsafeRawBufferPointer, log: UnsafeMutableRawBufferPointer,
    used: Int
  ) -> Int? {
    var command = InlineArray<1100, UInt8>(repeating: 0)
    var cursor = MeasurementLog(used: UInt64(used), stopped: false)
    let label: StaticString = "Tarwin FIFO diagnostic"
    return withUnsafeMutableBytes(of: &command) { raw in
      var sample = InlineArray<32, UInt8>(repeating: 0)
      guard var port = TPMFIFO(registers: VirtFIFO(), scratch: raw, pollLimit: 500000) else { return nil }
      #if TARBOOT_TEST_FLOOR
        var name = counterName
        guard withUnsafeBytes(of: &name, { readTPMSecurityFloor(&port, index: 0x0180_f001, name: $0) }) == 1
        else { return nil }
        name[0] ^= 1
        guard withUnsafeBytes(of: &name, { readTPMSecurityFloor(&port, index: 0x0180_f001, name: $0) }) == nil
        else { return nil }
      #endif
      guard readTPMEntropy32(&port, into: &sample),
        measureEarlyProcess(
          fixture,
          expected: PCR10Expectation(
            imageSHA256: fifoProbeDigest,
            previousPCR: .init(repeating: 0), replayedPCR: fifoProbePCR),
          port: &port, state: &cursor, log: log, label: label), !cursor.stopped
      else { return nil }
      let bytes = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(log)[..<Int(cursor.used)])
      guard let fmt = EventLogFormat(bytes), let event = fmt.event(bytes, at: used),
        event.pcr == 10, event.type == 13, event.payload.upperBound == bytes.count,
        event.payload.count == label.utf8CodeUnitCount
      else { return nil }
      for i in 0..<32 where bytes[event.sha256 + i] != fifoProbeDigest[i] { return nil }
      for i in 0..<label.utf8CodeUnitCount
      where bytes[event.payload.lowerBound + i] != label.utf8Start[i] {
        return nil
      }
      return bytes.count
    }
  }
#endif
