#if TARBOOT_TEST_TPM
  import Tarboot

  private typealias Submit =
    @convention(c) (UnsafeRawPointer, UInt32, UnsafeRawPointer, UInt32, UnsafeMutableRawPointer) ->
    UInt
  private typealias Locate =
    @convention(c) (UnsafeRawPointer, UnsafeRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>) ->
    UInt

  // Independent, read-only test observer. Only the SHA-256 PCR selected by
  // the diagnostic is sent to the host, never TPM secrets or arbitrary responses.
  private func readPCR(
    _ system: UnsafeRawPointer, pcr: UInt8, before: Bool,
    console: UnsafeRawPointer, output: Output
  ) -> Bool {
    guard pcr == 8 || pcr == 9,
      let boot = system.load(fromByteOffset: 96, as: UnsafeRawPointer?.self),
      FirmwareBootServices.valid(boot, signature: 0x5652_4553_544f_4f42, minimum: 328),
      let locate = boot.load(fromByteOffset: 320, as: Locate?.self)
    else { return false }
    var guid = (UInt64(0x42be_7455_607f_766c), UInt64(0x0f72_b26d_d7e4_0b93))
    var interface: UnsafeRawPointer?
    let status = withUnsafeBytes(of: &guid) { locate($0.baseAddress!, nil, &interface) }
    if status == (UInt(1) << 63) | 14 {
      writeDiagnostic("TARWIN-TCG2-NOT-FOUND\r\n", console: console, output: output)
    }
    guard status == 0, let interface,
      let submit = interface.load(fromByteOffset: 24, as: Submit?.self)
    else { return false }
    var command: InlineArray<20, UInt8> = [
      128, 1, 0, 0, 0, 20, 0, 0, 1, 126, 0, 0, 0, 1, 0, 11, 3, 0, 1, 0,
    ]
    command[18] = pcr == 8 ? 1 : 2
    var reply = InlineArray<62, UInt8>(repeating: 0)
    let ok = withUnsafeBytes(of: &command) { c in
      withUnsafeMutableBytes(of: &reply) { b in
        submit(interface, 20, c.baseAddress!, 62, b.baseAddress!) == 0
      }
    }
    guard ok, reply[0] == 128, reply[1] == 1, reply[5] == 62, reply[17] == 1, reply[19] == 11,
      reply[20] == 3, reply[22] == command[18], reply[27] == 1, reply[29] == 32
    else { return false }
    for i in 2..<30 where i < 10 || i >= 14 {
      if i != 5 && i != 17 && i != 19 && i != 20 && i != 22 && i != 27 && i != 29 && reply[i] != 0 {
        return false
      }
    }
    func put(_ byte: UInt8) {
      var ch = (UInt16(byte), UInt16(0))
      _ = withUnsafeBytes(of: &ch) { output(console, $0.bindMemory(to: UInt16.self).baseAddress!) }
    }
    let prefix: StaticString = before ? "TARWIN-PCR-BEFORE-" : "TARWIN-PCR-AFTER-"
    for i in 0..<prefix.utf8CodeUnitCount { put(prefix.utf8Start[i]) }
    put(48 + pcr)
    put(61)
    let hex: StaticString = "0123456789abcdef"
    for i in 30..<62 {
      let b = reply[i]
      put(hex.utf8Start[Int(b >> 4)])
      put(hex.utf8Start[Int(b & 15)])
    }
    put(13)
    put(10)
    return true
  }

  func exerciseMeasurements(
    _ boot: inout FirmwareBootServices, archive: UnsafeRawBufferPointer,
    system: UnsafeRawPointer, console: UnsafeRawPointer, output: Output
  ) -> Bool {
    let json: StaticString = #"{"flags":[],"slot":"A"}"#
    let config = UnsafeRawBufferPointer(start: json.utf8Start, count: json.utf8CodeUnitCount)
    return readPCR(system, pcr: 8, before: true, console: console, output: output)
      && readPCR(system, pcr: 9, before: true, console: console, output: output)
      && boot.measureBootSet(archive, configuration: config)
      && !boot.measureBootSet(archive, configuration: config)
      && readPCR(system, pcr: 8, before: false, console: console, output: output)
      && readPCR(system, pcr: 9, before: false, console: console, output: output)
  }
#endif
