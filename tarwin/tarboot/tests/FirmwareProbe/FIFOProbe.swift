#if TARBOOT_TEST_FIFO
  import KCore
  import TarwinBoot
  #if TARBOOT_TEST_GENERATION
    import Tarboot
    import TarwinKernelRandom
    import TarwinRandomCore

    @_extern(c, "tarwin_mmio_write16") private func write16(_ p: UnsafeRawPointer, _ v: UInt16)
    @_extern(c, "tarwin_mmio_write32") private func write32(_ p: UnsafeRawPointer, _ v: UInt32)

    // QEMU virt diagnostic bindings only: fw-cfg@9020000 and pl011@9000000.
    private struct VirtConfig: QEMUConfigReader {
      let base = UnsafeRawPointer(bitPattern: 0x0902_0000)!
      mutating func select(_ key: UInt16) { write16(base + 8, key.bigEndian) }
      mutating func readByte() -> UInt8 { read8(base) }
    }

    @inline(never) private func refusesRandom(_ seed: UnsafeRawBufferPointer,
      _ sample: UnsafeRawBufferPointer, _ generation: RandomEpoch?) -> Bool {
      if let _ = KernelRandom(policy: .debugQEMU, bootSeed: seed, hardware: sample,
        source: .emulatedTPM, generation: generation) { return false }
      return true
    }

    private func emit(_ marker: StaticString) -> Bool {
      let uart = UnsafeRawPointer(bitPattern: 0x0900_0000)!
      for i in 0..<marker.utf8CodeUnitCount {
        var polls = 500000
        while read32(uart + 0x18) & 0x20 != 0 {
          polls -= 1
          if polls == 0 { return false }
        }
        write32(uart, UInt32(marker.utf8Start[i]))
      }
      return true
    }
    #if TARBOOT_TEST_RESTORE
    import TarwinW1Generation
    @_extern(c, "tarwin_mmio_read64") private func read64(_ p: UnsafeRawPointer) -> UInt64
    private func readWord(_ address: UInt64) -> UInt64? {
      guard let p = UnsafeRawPointer(bitPattern: UInt(address)) else { return nil }
      return read64(p)
    }
    #endif
    func exerciseGeneration(bootSeed: UnsafeRawBufferPointer, regions: UnsafeBufferPointer<FirmwareRegion>) -> Bool {
      var cfg = VirtConfig()
      guard bootSeed.count == 64 else { return false }
      #if TARBOOT_TEST_RESTORE
      guard let source = W1GenerationSource(policy: .rotatingDevice, reader: &cfg,
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
        #if TARBOOT_TEST_RESTORE
        guard var rng = withUnsafeBytes(of: &sample, { KernelRandom(policy: .debugQEMU,
          bootSeed: bootSeed, hardware: $0, source: .emulatedTPM, generation: first) }),
          rng.word(generation: source.current(readWord: readWord)) != nil, emit("TARWIN-VMGEN-SNAPSHOT-READY\r\n")
        else { return false }
        while source.current(readWord: readWord) == first {}
        guard let next = source.current(readWord: readWord), next != first, rng.word(generation: next) == nil,
          rng.word(generation: first) == nil, readTPMEntropy32(&port, into: &sample),
          withUnsafeBytes(of: &sample, { rng.reseed(hardware: $0, source: .emulatedTPM, generation: next) }),
          rng.word(generation: source.current(readWord: readWord)) != nil else { return false }
        return emit("TARWIN-VMGEN-RESTORED-REFUSED-RESEEDED\r\n")
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
      guard var port = TPMFIFO(registers: VirtFIFO(), scratch: raw, pollLimit: 500000),
        readTPMEntropy32(&port, into: &sample),
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
