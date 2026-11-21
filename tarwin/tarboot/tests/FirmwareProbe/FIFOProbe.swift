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

  private func readTen(_ port: inout TPMFIFO<VirtFIFO>, expected: UnsafeRawBufferPointer?) -> Bool {
    let command: InlineArray<20, UInt8> = [
      128, 1, 0, 0, 0, 20, 0, 0, 1, 126, 0, 0, 0, 1, 0, 11, 3, 0, 4, 0,
    ]
    let selection: InlineArray<16, UInt8> = [0, 0, 0, 1, 0, 11, 3, 0, 4, 0, 0, 0, 0, 1, 0, 32]
    for i in 0..<20 { port.putByte(UInt64(i), value: command[i]) }
    guard port.submit(20) == 62, port.byteAt(0) == 0x80, port.byteAt(1) == 1 else { return false }
    for i in 6..<10 where port.byteAt(UInt64(i)) != 0 { return false }
    for i in 0..<16 where port.byteAt(UInt64(i + 14)) != selection[i] { return false }
    for i in 0..<32 where port.byteAt(UInt64(i + 30)) != (expected?[i] ?? 0) { return false }
    return true
  }

  func exerciseKernelFIFO(
    _ fixture: UnsafeRawBufferPointer, log: UnsafeMutableRawBufferPointer,
    used: Int
  ) -> Int? {
    var command = InlineArray<1100, UInt8>(repeating: 0)
    var cursor = MeasurementLog(used: UInt64(used), stopped: false)
    let label: StaticString = "Tarwin FIFO diagnostic"
    return withUnsafeMutableBytes(of: &command) { raw in
      guard var port = TPMFIFO(registers: VirtFIFO(), scratch: raw, pollLimit: 500000),
        readTen(&port, expected: nil),
        measureEarlyProcess(fixture, port: &port, state: &cursor, log: log, label: label),
        !cursor.stopped, withUnsafeBytes(of: fifoProbePCR, { readTen(&port, expected: $0) })
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
