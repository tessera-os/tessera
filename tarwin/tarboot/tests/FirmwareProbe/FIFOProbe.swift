#if TARBOOT_TEST_FIFO
  import KCore
  import TarwinBoot

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
