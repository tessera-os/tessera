#if TARWIN_NATIVE_IMAGE
  #if !hasFeature(Embedded)
    #error("The hardware gate is for a freestanding LibTessera image, not a host backend")
  #endif
  import TarwinABI

  @_extern(c, "libtessera_tarwin_enter")
  private func enterHardware(
    _ number: UInt64, _ words: UnsafePointer<UInt64>, _ result: UnsafeMutablePointer<UInt64>)

  /// Linked only into train-matched native LibTessera. The platform must
  /// register this image's authenticated RX mapping in the calling process.
  public struct NativeHardwareGate: NativeGate {
    public init() {}
    public var isa: CallISA {
      #if arch(arm64)
        .aarch64
      #elseif arch(x86_64)
        .x64
      #elseif arch(riscv64)
        .rv64
      #else
        #error("Unsupported Tarwin syscall architecture")
      #endif
    }
    public mutating func enter(number: UInt64, registers r: CallRegisters) -> CallResult {
      var words: InlineArray<8, UInt64> = [r.a0, r.a1, r.a2, r.a3, r.a4, r.a5, r.a6, r.a7]
      var result = InlineArray<4, UInt64>(repeating: 0)
      withUnsafeBytes(of: &words) { w in
        withUnsafeMutableBytes(of: &result) { out in
          enterHardware(
            number, w.bindMemory(to: UInt64.self).baseAddress!,
            out.bindMemory(to: UInt64.self).baseAddress!)
        }
      }
      return CallResult(status: result[0], detail: result[1], first: result[2], second: result[3])
    }
  }
#endif
