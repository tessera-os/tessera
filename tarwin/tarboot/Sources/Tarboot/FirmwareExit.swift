import KCore

public enum FirmwareExit {
  /// No exit call was made; the caller may still use normal firmware services.
  case preflightFailure
  /// Firmware may have partially shut down; never return to its boot manager or console.
  case failedAfterExitAttempt
  /// Only the validated prefix is published. No boot services or console remain callable.
  case exited(regions: Int)
}

/// EFIAPI on 64-bit Arm and RISC-V uses the target C PCS. Do not call EFIAPI with
/// the SysV x64 ABI: the x64 loader must itself be built for the Microsoft x64 ABI.
#if arch(arm64) || arch(riscv64) || (arch(x86_64) && (os(Windows) || TARBOOT_EFI_PE_COFF))

  private struct MappedBytes: ByteSource {
    var base: UnsafeRawPointer
    var size: UInt64
    func byteCount() -> UInt64 { size }
    func byteAt(_ offset: UInt64) -> UInt8 {
      precondition(offset < size)
      // The constructor borrows immutable live firmware or loader storage of this extent.
      return base.load(fromByteOffset: Int(offset), as: UInt8.self)
    }
  }

  public struct FirmwareBootServices: ~Copyable {
    private typealias GetMap =
      @convention(c) (
        UnsafeMutablePointer<UInt>, UnsafeMutableRawPointer,
        UnsafeMutablePointer<UInt>, UnsafeMutablePointer<UInt>, UnsafeMutablePointer<UInt32>
      ) -> UInt
    private typealias Exit = @convention(c) (UnsafeRawPointer, UInt) -> UInt
    private let image: UnsafeRawPointer
    private let getMap: GetMap
    private let exitBoot: Exit

    /// The EFI entry's system pointer and its nested tables are trusted firmware-mapped
    /// storage, not addresses parsed from a boot set. The caller owns the image handle.
    /// Never retain this view across a successful or partial ExitBootServices.
    @unsafe public init?(image: UnsafeRawPointer, system: UnsafeRawPointer) {
      guard Self.valid(system, signature: 0x5453_5953_2049_4249, minimum: 120),
        let boot = system.load(fromByteOffset: 96, as: UnsafeRawPointer?.self),
        Self.valid(boot, signature: 0x5652_4553_544f_4f42, minimum: 240),
        let map = boot.load(fromByteOffset: 56, as: GetMap?.self),
        let exit = boot.load(fromByteOffset: 232, as: Exit?.self)
      else { return nil }
      self.image = image
      self.getMap = map
      self.exitBoot = exit
    }

    /// Firmware guarantees a mapped EFI_TABLE_HEADER prefix. Cap its declared extent
    /// before checking CRC; this detects table corruption, not untrusted pointers.
    @unsafe public static func valid(_ p: UnsafeRawPointer, signature: UInt64, minimum: UInt64)
      -> Bool
    {
      let size = UInt64(p.load(fromByteOffset: 12, as: UInt32.self))
      return size <= 4096
        && validFirmwareTable(
          MappedBytes(base: p, size: size),
          signature: signature, minimumSize: minimum)
    }

    /// Both buffers are exclusively owned, preallocated loader memory. Acquire, validate,
    /// and exit with the same key without logging, allocating or invoking other services.
    @unsafe public consuming func finish(
      map: UnsafeMutableRawBufferPointer,
      into regions: inout UnsafeMutableBufferPointer<FirmwareRegion>
    ) -> FirmwareExit {
      guard let p = map.baseAddress, UInt(bitPattern: p) & 7 == 0, map.count >= 40
      else { return .preflightFailure }
      var attempted = false
      for _ in 0..<4 {
        var size = UInt(map.count)
        var key: UInt = 0
        var stride: UInt = 0
        var version: UInt32 = 0
        guard getMap(&size, p, &key, &stride, &version) == 0, size <= UInt(map.count),
          let count = stageFirmwareMap(
            MappedBytes(base: UnsafeRawPointer(p), size: UInt64(size)),
            stride: UInt64(stride), version: version, into: &regions)
        else { return attempted ? .failedAfterExitAttempt : .preflightFailure }
        let status = exitBoot(image, key)
        if status == 0 { return .exited(regions: count) }
        attempted = true
        if status != 0x8000_0000_0000_0002 { return .failedAfterExitAttempt }
      }
      return .failedAfterExitAttempt
    }
  }
#endif
