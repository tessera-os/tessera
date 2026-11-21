import Tarboot
import Testing

#if arch(arm64)
  private typealias MapFunction =
    @convention(c) (
      UnsafeMutablePointer<UInt>, UnsafeMutableRawPointer, UnsafeMutablePointer<UInt>,
      UnsafeMutablePointer<UInt>, UnsafeMutablePointer<UInt32>
    ) -> UInt
  private typealias ExitFunction = @convention(c) (UnsafeRawPointer, UInt) -> UInt
  private struct Trace {
    var calls = 0
    var expectedKey: UInt = 1
    let invalidUntil: Int
    let otherError: Bool
  }

  private func header(_ bytes: UnsafeMutableRawBufferPointer, _ signature: UInt64) {
    bytes.storeBytes(of: signature, as: UInt64.self)
    bytes.storeBytes(of: UInt32(bytes.count), toByteOffset: 12, as: UInt32.self)
    var crc = UInt32.max
    for b in bytes {
      crc ^= UInt32(b)
      for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
    }
    bytes.storeBytes(of: ~crc, toByteOffset: 16, as: UInt32.self)
  }

  @Test func firmwareExitRetries() {
    let map: MapFunction = { size, memory, key, stride, version in
      guard size.pointee >= 64 else { return 0x8000_0000_0000_0005 }
      // The last word belongs to this fixture and is outside its descriptor.
      let seq = memory.load(fromByteOffset: 56, as: UInt.self) + 1
      memory.storeBytes(of: seq, toByteOffset: 56, as: UInt.self)
      memory.storeBytes(of: UInt64(7), as: UInt64.self)
      memory.storeBytes(of: UInt64(seq << 12), toByteOffset: 8, as: UInt64.self)
      memory.storeBytes(of: UInt64(1), toByteOffset: 24, as: UInt64.self)
      key.pointee = seq
      size.pointee = 48
      stride.pointee = 48
      version.pointee = 1
      return 0
    }
    let exit: ExitFunction = { handle, key in
      let s = UnsafeMutableRawPointer(mutating: handle).assumingMemoryBound(to: Trace.self)
      precondition(key == s.pointee.expectedKey)
      s.pointee.expectedKey += 1
      s.pointee.calls += 1
      if s.pointee.otherError { return 0x8000_0000_0000_0007 }
      return s.pointee.calls > s.pointee.invalidUntil ? 0 : 0x8000_0000_0000_0002
    }
    var system = [UInt64](repeating: 0, count: 15)
    var boot = [UInt64](repeating: 0, count: 30)
    boot.withUnsafeMutableBytes { services in
      services.storeBytes(of: map, toByteOffset: 56, as: MapFunction.self)
      services.storeBytes(of: exit, toByteOffset: 232, as: ExitFunction.self)
      header(services, 0x5652_4553_544f_4f42)
      system.withUnsafeMutableBytes { st in
        st.storeBytes(of: services.baseAddress!, toByteOffset: 96, as: UnsafeMutableRawPointer.self)
        header(st, 0x5453_5953_2049_4249)
        for (stale, capacity, otherError, calls) in [
          (0, 64, false, 1), (1, 64, false, 2), (8, 64, false, 4), (0, 8, false, 0),
          (0, 64, true, 1),
        ] {
          var backing = [UInt64](repeating: 0, count: capacity / 8)
          var staged = [FirmwareRegion](repeating: .empty, count: 1)
          var trace = Trace(invalidUntil: stale, otherError: otherError)
          withUnsafeMutablePointer(to: &trace) { image in
            backing.withUnsafeMutableBytes { raw in
              staged.withUnsafeMutableBufferPointer { view in
                guard let fw = FirmwareBootServices(image: image, system: st.baseAddress!) else {
                  Issue.record("test tables failed header validation")
                  return
                }
                switch fw.finish(map: raw, into: &view) {
                case .preflightFailure: #expect(capacity < 64)
                case .failedAfterExitAttempt: #expect(stale >= 4 || otherError)
                case .exited(let n):
                  #expect(!otherError && capacity == 64 && stale < 4)
                  #expect(n == 1)
                  #expect(view[0].base == UInt64((stale + 1) << 12))
                }
              }
            }
          }
          #expect(trace.calls == calls)
        }
        st[119] ^= 1
        #expect(
          !FirmwareBootServices.valid(
            st.baseAddress!, signature: 0x5453_5953_2049_4249, minimum: 120))
      }
    }
  }
#endif
