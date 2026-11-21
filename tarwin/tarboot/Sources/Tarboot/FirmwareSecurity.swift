#if arch(arm64) || arch(riscv64) || (arch(x86_64) && (os(Windows) || TARBOOT_EFI_PE_COFF))
  /// Snapshot of firmware's own UEFI global variables. It describes firmware
  /// enforcement, not the signature or rollback status of a file on the ESP.
  public struct FirmwareBootMode {
    public let revision: UInt32
    public let secureBoot: Bool
    public let setupMode: Bool

    public var meetsFirmwareMinimum: Bool {
      revision >= 0x0002_005a && secureBoot && !setupMode
    }
  }

  typealias GetVariable =
    @convention(c) (
      UnsafePointer<UInt16>, UnsafeRawPointer, UnsafeMutablePointer<UInt32>,
      UnsafeMutablePointer<UInt>, UnsafeMutableRawPointer
    ) -> UInt

  private enum Switch { case off, on, absent, invalid }

  // UEFI 2.10 §§3.3, 32: exact, read-only BS|RT byte in the global namespace.
  // Fixed, naturally aligned buffers outlive each synchronous GetVariable call.
  private func readSwitch(_ name: StaticString, _ get: GetVariable) -> Switch {
    let z: UInt64 = 0
    var chars = (z, z, z)
    guard name.utf8CodeUnitCount < MemoryLayout.size(ofValue: chars) / 2 else { return .invalid }
    var global = (UInt64(0x11d2_93ca_8be4_df61), UInt64(0x8c2b_0398_e000_0daa))
    var byte: UInt8 = 0xff
    var attributes: UInt32 = 0
    var size: UInt = 1
    let result = withUnsafeMutableBytes(of: &chars) { raw in
      let utf16 = raw.bindMemory(to: UInt16.self)
      for i in 0..<name.utf8CodeUnitCount { utf16[i] = UInt16(name.utf8Start[i]) }
      return withUnsafeBytes(of: &global) { guid in
        get(UnsafePointer(utf16.baseAddress!), guid.baseAddress!, &attributes, &size, &byte)
      }
    }
    if result == 0x8000_0000_0000_000e { return .absent }
    guard result == 0, attributes == 6, size == 1, byte <= 1 else { return .invalid }
    return byte == 1 ? .on : .off
  }

  func bootMode(revision: UInt32, get: GetVariable) -> FirmwareBootMode? {
    let secure = readSwitch("SecureBoot", get)
    let setup = readSwitch("SetupMode", get)
    let audit = readSwitch("AuditMode", get)
    guard secure == .on || secure == .off, setup == .on || setup == .off,
      audit != .invalid, secure == .off || (setup == .off && audit != .on)
    else { return nil }
    return .init(revision: revision, secureBoot: secure == .on, setupMode: setup == .on)
  }
#endif
