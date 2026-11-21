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
  private struct Bytes: ByteBuffer {
    let b: UnsafeMutableRawBufferPointer
    func byteCount() -> UInt64 { UInt64(b.count) }
    func byteAt(_ pos: UInt64) -> UInt8 { b[Int(pos)] }
    func putByte(_ pos: UInt64, value: UInt8) { b[Int(pos)] = value }
  }
  private struct Label: ByteSource {
    let label: StaticString
    func byteCount() -> UInt64 { UInt64(label.utf8CodeUnitCount) }
    func byteAt(_ pos: UInt64) -> UInt8 { label.utf8Start[Int(pos)] }
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

  func exerciseKernelFIFO() -> Bool {
    var command = InlineArray<96, UInt8>(repeating: 0)
    var event = InlineArray<96, UInt8>(repeating: 0)
    var digest = fifoProbeDigest
    let expected = fifoProbePCR
    return withUnsafeMutableBytes(of: &command) { raw in
      guard var port = TPMFIFO(registers: VirtFIFO(), scratch: raw, pollLimit: 500000),
        readTen(&port, expected: nil)
      else { return false }
      return withUnsafeMutableBytes(of: &digest) { d in
        withUnsafeMutableBytes(of: &event) { e in
          var log = Bytes(b: e)
          var cursor = MeasurementLog(used: 0, stopped: false)
          let label = Label(label: "Tarwin FIFO diagnostic")
          guard
            extendAndRecord(
              &port, state: &cursor, log: &log, pcr: 10, digest: Bytes(b: d),
              event: label), !cursor.stopped, cursor.used == 50 + label.byteCount(),
            little(log, at: 0, bytes: 4) == 10
          else { return false }
          for i in 0..<32 where e[14 + i] != d[i] { return false }
          return withUnsafeBytes(of: expected) { readTen(&port, expected: $0) }
        }
      }
    }
  }
#endif
