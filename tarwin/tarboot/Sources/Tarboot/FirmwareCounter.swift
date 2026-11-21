#if arch(arm64) || arch(riscv64) || (arch(x86_64) && (os(Windows) || TARBOOT_EFI_PE_COFF))
  import TarwinBoot

  typealias TPMSubmit =
    @convention(c) (UnsafeRawPointer, UInt32, UnsafeRawPointer, UInt32, UnsafeMutableRawPointer) ->
    UInt

  private struct FirmwareCounterPort: TpmPort {
    let instance: UnsafeRawPointer
    let send: TPMSubmit
    let command, reply: UnsafeMutableRawBufferPointer
    func byteCount() -> UInt64 { UInt64(reply.count) }
    func byteAt(_ offset: UInt64) -> UInt8 { reply[Int(offset)] }
    func putByte(_ offset: UInt64, value: UInt8) { command[Int(offset)] = value }
    mutating func submit(_ size: UInt64) -> UInt64 {
      guard size <= UInt64(command.count) else { return 0 }
      reply.initializeMemory(as: UInt8.self, repeating: 0xff)
      guard send(instance, UInt32(size), command.baseAddress!, UInt32(reply.count), reply.baseAddress!) == 0
      else { return 0 }
      return UInt64(UInt32(bigEndian: reply.loadUnaligned(fromByteOffset: 2, as: UInt32.self)))
    }
  }

  extension FirmwareTCG {
    @available(macOS 26, *)
    func securityFloor(index: UInt32, name: UnsafeRawBufferPointer) -> UInt64? {
      guard let send = instance.load(fromByteOffset: 24, as: TPMSubmit?.self) else { return nil }
      var command = InlineArray<62, UInt8>(repeating: 0)
      var reply = InlineArray<62, UInt8>(repeating: 0xff)
      return withUnsafeMutableBytes(of: &command) { c in
        withUnsafeMutableBytes(of: &reply) { r in
          var port = FirmwareCounterPort(instance: instance, send: send, command: c, reply: r)
          return readTPMSecurityFloor(&port, index: index, name: name)
        }
      }
    }
  }
#endif
