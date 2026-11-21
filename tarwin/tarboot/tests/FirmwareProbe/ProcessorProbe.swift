#if TARBOOT_TEST_CPU
  import Tarboot
  #if arch(arm64)
    import TarwinArchAarch64
  #endif

  @_extern(c, "tarwin_processor_snapshot")
  private func snapshot(_ out: UnsafeMutablePointer<UInt64>)

  func processorEvidence(console: UnsafeRawPointer, output: Output) -> Bool {
    var words = InlineArray<32, UInt64>(repeating: 0)
    return withUnsafeMutableBytes(of: &words) { raw in
      let v = raw.bindMemory(to: UInt64.self)
      snapshot(v.baseAddress!)
      #if arch(arm64)
        guard let features = ArmProcessorFeatures(UnsafeBufferPointer(v)) else { return false }
        if features.w0Registers {
          writeDiagnostic("TARWIN-CPU-AARCH64-BASE-EL2\r\n", console: console, output: output)
        } else {
          writeDiagnostic("TARWIN-CPU-AARCH64-INSUFFICIENT\r\n", console: console, output: output)
        }
        return features.w0Registers
      #elseif arch(x86_64)
        guard v[0] >= 7, v[4] >= 0x8000_0001 else { return false }
        writeDiagnostic("TARWIN-CPU-CPUID-SNAPSHOT\r\n", console: console, output: output)
        return true  // snapshot only; not x64.v3 admission
      #else
        guard v[0] == 0, v[1] >= 2, v[8] == 0, v[9] != 0 else { return false }
        writeDiagnostic("TARWIN-CPU-SBI-SNAPSHOT\r\n", console: console, output: output)
        return true  // SBI BASE and TIME only; not rv64.base admission
      #endif
    }
  }
#endif
