#if TARBOOT_TEST_CPU
  import Tarboot
  #if TARBOOT_TEST_PSCI
    import TarwinBoot
    @_extern(c, "tarboot_psci_version") private func version() -> UInt64
    @_extern(c, "tarboot_psci_affinity") private func affinity(_ id: UInt64) -> UInt64
    @_extern(c, "tarboot_affinity_id") private func mpidr() -> UInt64

    func bootCPUOnly(_ ids: UnsafeBufferPointer<FirmwareProcessor>) -> Bool {
      let v = UInt32(truncatingIfNeeded: version())
      guard v >= 0x10000, v & 0x80000000 == 0 else { return false }
      let bootID = mpidr() & 0xff00_ffffff
      var sawBoot = false
      for cpu in ids {
        let current = cpu.hardwareID == bootID
        guard affinity(cpu.hardwareID) == (current ? 0 : 1) else { return false }
        if current {
          guard !sawBoot else { return false }
          sawBoot = true
        }
      }
      return sawBoot
    }
  #endif
  #if arch(arm64)
    import TarwinArchAarch64
  #elseif arch(x86_64)
    import TarwinArchX64
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
        #if TARBOOT_TEST_X64_REFUSAL
          guard let f = X64TargetFeatures(UnsafeBufferPointer(v)) else { return false }
          if !f.shadowStack { writeDiagnostic("TARWIN-X64-MISSING-SHSTK\r\n",console:console,output:output) }
          if !f.indirectBranchTracking { writeDiagnostic("TARWIN-X64-MISSING-IBT\r\n",console:console,output:output) }
          if !f.vectorCarrylessMultiply { writeDiagnostic("TARWIN-X64-MISSING-VPCLMULQDQ\r\n",console:console,output:output) }
          if !f.invariantCounter { writeDiagnostic("TARWIN-X64-MISSING-INVTSC\r\n",console:console,output:output) }
          if !f.deadlineTimer { writeDiagnostic("TARWIN-X64-MISSING-TSC-DEADLINE\r\n",console:console,output:output) }
          return f.namedBaseline
        #else
        return true  // snapshot only; not x64.v3 admission
        #endif
      #else
        guard v[0] == 0, v[1] >= 2, v[8] == 0, v[9] != 0 else { return false }
        writeDiagnostic("TARWIN-CPU-SBI-SNAPSHOT\r\n", console: console, output: output)
        return true  // SBI BASE and TIME only; not rv64.base admission
      #endif
    }
  }
#endif
