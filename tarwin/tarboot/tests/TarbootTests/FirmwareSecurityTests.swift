import Testing

@testable import Tarboot

#if arch(arm64)
  private struct SwitchReply {
    let value: UInt8
    let attrs: UInt32
    let length: UInt
    let status: UInt
    init(_ v: UInt8 = 0, attrs: UInt32 = 6, length: UInt = 1, status: UInt = 0) {
      self.value = v
      self.attrs = attrs
      self.length = length
      self.status = status
    }
  }
  // Borrowed only during this synchronous firmware fixture.
  nonisolated(unsafe) private var switches = [String: SwitchReply]()

  @Test func firmwareSecurityModeIsNotAnImageSignature() {
    let get: GetVariable = { chars, guid, attrs, len, data in
      precondition(
        len.pointee == 1 && guid.load(as: UInt64.self) == 0x11d2_93ca_8be4_df61
          && guid.load(fromByteOffset: 8, as: UInt64.self) == 0x8c2b_0398_e000_0daa)
      let key = String(decodingCString: chars, as: UTF16.self)
      guard let r = switches[key] else { return 0x8000_0000_0000_000e }
      attrs.pointee = r.attrs
      len.pointee = r.length
      data.storeBytes(of: r.value, as: UInt8.self)
      return r.status
    }
    func mode(
      _ sb: SwitchReply?, _ setup: SwitchReply?, _ audit: SwitchReply?,
      revision: UInt32 = 0x2005a
    ) -> FirmwareBootMode? {
      switches = [:]
      switches["SecureBoot"] = sb
      switches["SetupMode"] = setup
      switches["AuditMode"] = audit
      return bootMode(revision: revision, get: get)
    }
    #expect(mode(.init(1), .init(), nil)?.meetsFirmwareMinimum == true)
    #expect(mode(.init(1), .init(), .init(), revision: 0x20050)?.meetsFirmwareMinimum == false)
    #expect(mode(.init(0), .init(1), nil)?.setupMode == true)
    #expect(mode(.init(0), .init(0), .init(1))?.meetsFirmwareMinimum == false)
    #expect(mode(.init(1), .init(1), nil) == nil && mode(.init(1), .init(), .init(1)) == nil)
    for bad: SwitchReply? in [
      nil, .init(2), .init(1, attrs: 7), .init(1, length: 2), .init(1, status: 1),
    ] {
      #expect(mode(bad, .init(), nil) == nil && mode(.init(1), bad, nil) == nil)
    }
    #expect(mode(.init(1), .init(), .init(status: 2)) == nil)
  }
#endif
