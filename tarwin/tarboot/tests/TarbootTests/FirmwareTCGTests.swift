import Testing

@testable import Tarboot

#if arch(arm64)
  private typealias Capability = @convention(c) (UnsafeRawPointer, UnsafeMutableRawPointer) -> UInt
  // Only this test uses these pointers, all within the nested table borrows.
  nonisolated(unsafe) private var tcgInstance: UnsafeRawPointer?
  nonisolated(unsafe) private var failAt: UInt8 = 0
  nonisolated(unsafe) private var calls: [UInt8] = []

  @Test func measuredBootStopsOnAmbiguousStatus() {
    let capability: Capability = { _, raw in
      precondition(raw.load(as: UInt8.self) == 36)
      let b = UnsafeMutableRawBufferPointer(start: raw, count: 36)
      for i in 1...4 { b[i] = 1 }
      b[8] = 2
      b[12] = 2
      b[16] = 1
      b[32] = failAt == 1 ? 0 : 2
      return 0
    }
    let locate: LocateProtocol = { guid, key, out in
      precondition(key == nil && guid.load(as: UInt64.self) == 0x42be_7455_607f_766c)
      out.pointee = tcgInstance
      return 0
    }
    let extend: HashLogExtend = { _, flags, base, size, event in
      let pcr = event.load(fromByteOffset: 10, as: UInt8.self)
      precondition(
        flags == 0 && size == 1
          && UnsafeRawPointer(bitPattern: UInt(base))!.load(as: UInt8.self) == pcr)
      let label = pcr == 8 ? "Tarwin boot set" : "Tarwin boot configuration"
      precondition(event.loadUnaligned(as: UInt32.self) == 18 + label.utf8.count)
      precondition(event.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == 14)
      precondition(event.loadUnaligned(fromByteOffset: 8, as: UInt16.self) == 1)
      precondition(event.loadUnaligned(fromByteOffset: 10, as: UInt32.self) == UInt32(pcr))
      precondition(event.loadUnaligned(fromByteOffset: 14, as: UInt32.self) == 13)
      let payload = UnsafeRawBufferPointer(start: event.advanced(by: 18), count: label.utf8.count)
      precondition(payload.elementsEqual(label.utf8))
      calls.append(pcr)
      return pcr == failAt ? (UInt(1) << 63) | 11 : 0  // EFI_VOLUME_FULL: PCR may already have changed
    }
    // Unused firmware calls required to bind a boot services view.
    let map:
      @convention(c) (
        UnsafeMutablePointer<UInt>, UnsafeMutableRawPointer, UnsafeMutablePointer<UInt>,
        UnsafeMutablePointer<UInt>, UnsafeMutablePointer<UInt32>
      ) -> UInt = { _, _, _, _, _ in
        preconditionFailure("firmware exit attempted after failed measurement")
      }
    let exit: @convention(c) (UnsafeRawPointer, UInt) -> UInt = { _, _ in 1 }
    var table = [UInt64](repeating: 0, count: 3)
    var boot = [UInt64](repeating: 0, count: 41)
    var system = [UInt64](repeating: 0, count: 15)
    table.withUnsafeMutableBytes { t in
      boot.withUnsafeMutableBytes { b in
        system.withUnsafeMutableBytes { s in
          t.storeBytes(of: capability, as: Capability.self)
          t.storeBytes(of: extend, toByteOffset: 16, as: HashLogExtend.self)
          tcgInstance = UnsafeRawPointer(t.baseAddress!)
          defer { tcgInstance = nil }
          b.storeBytes(of: map, toByteOffset: 56, as: type(of: map))
          b.storeBytes(of: exit, toByteOffset: 232, as: type(of: exit))
          b.storeBytes(of: locate, toByteOffset: 320, as: LocateProtocol.self)
          header(b, 0x5652_4553_544f_4f42)
          s.storeBytes(of: b.baseAddress!, toByteOffset: 96, as: UnsafeMutableRawPointer.self)
          header(s, 0x5453_5953_2049_4249)
          for failure: UInt8 in [0, 1, 8, 9] {
            calls = []
            failAt = failure
            guard var fw = FirmwareBootServices(image: s.baseAddress!, system: s.baseAddress!)
            else {
              Issue.record("invalid firmware fixture")
              return
            }
            var archive: UInt8 = 8
            var config: UInt8 = 9
            withUnsafeBytes(of: &archive) { a in
              withUnsafeBytes(of: &config) { c in
                let result = fw.measureBootSet(a, configuration: c)
                #expect(result == (failure == 0))
                let duplicate = fw.measureBootSet(a, configuration: c)
                #expect(!duplicate)
              }
            }
            #expect(calls == (failure == 1 ? [] : (failure == 8 ? [8] : [8, 9])))
            if failure != 0 {
              var regions = UnsafeMutableBufferPointer<FirmwareRegion>(start: nil, count: 0)
              if case .preflightFailure = fw.finish(map: b, into: &regions) {
              } else {
                Issue.record("failed measurement did not prevent handoff")
              }
            }
          }
        }
      }
    }
  }
#endif
