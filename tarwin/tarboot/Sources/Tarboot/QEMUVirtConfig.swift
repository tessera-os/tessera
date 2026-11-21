#if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
  @_extern(c, "tarwin_mmio_write16") private func write16(_ p: UnsafeRawPointer, _ v: UInt16)
  @_extern(c, "tarwin_mmio_read8") private func read8(_ p: UnsafeRawPointer) -> UInt8

  /// Debug QEMU virt only. Caller owns a validated Device mapping of the
  /// fw_cfg registers and serializes the full select/read transaction.
  public struct QEMUVirtConfig: QEMUFileReader {
    private let base: UnsafeRawPointer

    @unsafe public init(mapped base: UnsafeRawPointer) { self.base = base }
    public mutating func select(_ key: UInt16) { write16(base + 8, key.bigEndian) }
    public mutating func readByte() -> UInt8 { read8(base) }
    public mutating func readSelected(into output: UnsafeMutableRawBufferPointer) -> Int {
      // QEMU byte PIO has no EOF; its directory gives the immutable file's
      // length. A read fault must stop the CPU, never synthesize a byte.
      for i in output.indices { output[i] = read8(base) }
      return output.count
    }
  }
#endif
