#if TARBOOT_TEST_SIGNED
  import Tarboot
  import TarwinLoader
  import TarwinW0Verify

  private typealias GetTime =
    @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer?) -> UInt
  nonisolated(unsafe) private var sig = InlineArray<65536, UInt8>(repeating: 0)
  nonisolated(unsafe) private var polys = InlineArray<2048, Int32>(repeating: 0)
  nonisolated(unsafe) private var msg = InlineArray<1024, UInt8>(repeating: 0)
  nonisolated(unsafe) private var cv = InlineArray<54, BlakeCv>(
    repeating: .init(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0))

  func verifyBootSet(
    _ archive: UnsafeRawBufferPointer, services: inout FirmwareBootServices,
    system: UnsafeRawPointer, floor: UInt64?, baseline: Bool
  ) -> W0Kernel? {
    guard let runtime = system.load(fromByteOffset: 88, as: UnsafeRawPointer?.self),
      FirmwareBootServices.valid(runtime, signature: 0x5652_4553_544e_5552, minimum: 112),
      let getTime = runtime.load(fromByteOffset: 24, as: GetTime?.self)
    else { return nil }
    var clock = InlineArray<2, UInt64>(repeating: 0)
    guard
      let utc = withUnsafeMutableBytes(
        of: &clock,
        { raw -> UInt64? in
          guard getTime(raw.baseAddress!, nil) == 0 else { return nil }
          return emulatorUTC(UnsafeRawBufferPointer(raw))
        })
    else { return nil }
    let policy = W0Policy(
      machine: ElfMachine.aarch64, baselineSupported: baseline, trustedUTC: utc,
      train: (26, 11, 1), tir: (26, 11, 2), addressLimit: 1 << 30, securityFloor: floor,
      slot: 0, debugEmulator: true)
    var path: InlineArray<10, UInt16> = [92, 66, 79, 79, 84, 46, 83, 73, 71, 0]
    return withUnsafeMutableBytes(of: &sig) { s in
      guard
        let n = withUnsafeBytes(
          of: &path, { services.readBootFile(path: $0.bindMemory(to: UInt16.self), into: s) })
      else { return nil }
      // Trust bytes compiled into this test EFI image, never loaded from ESP.
      return withUnsafeBytes(of: &qemuEnrollment) { e in
        withUnsafeMutableBytes(of: &cv) { h in
          withUnsafeMutableBytes(of: &polys) { p in
            withUnsafeMutableBytes(of: &msg) { m in
              authorizeQEMUStage0(
                archive: archive,
                signature: UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(s)[..<n]),
                enrollment: e, policy: policy, hashes: h.bindMemory(to: BlakeCv.self),
                polynomials: p.bindMemory(to: Int32.self), message: m)
            }
          }
        }
      }
    }
  }
#endif
