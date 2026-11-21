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
    private typealias Allocate =
      @convention(c) (UInt32, UInt32, UInt, UnsafeMutablePointer<UInt64>) -> UInt
    private typealias Release = @convention(c) (UInt64, UInt) -> UInt
    private typealias GetMap =
      @convention(c) (
        UnsafeMutablePointer<UInt>, UnsafeMutableRawPointer,
        UnsafeMutablePointer<UInt>, UnsafeMutablePointer<UInt>, UnsafeMutablePointer<UInt32>
      ) -> UInt
    private typealias Exit = @convention(c) (UnsafeRawPointer, UInt) -> UInt
    private let image: UnsafeRawPointer
    private let system: UnsafeRawPointer
    private let protocolFor: HandleProtocol?
    private let locate: LocateProtocol?
    private let handles: LocateHandles?
    private enum Measurement { case notAttempted, stopped, complete, captured }
    private var measurement: Measurement = .notAttempted
    private let allocate: Allocate?
    private let release: Release?
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
      self.system = system
      self.protocolFor = boot.load(fromByteOffset: 152, as: HandleProtocol?.self)
      self.handles = boot.load(fromByteOffset: 176, as: LocateHandles?.self)
      self.locate =
        boot.load(fromByteOffset: 12, as: UInt32.self) >= 328
        ? boot.load(fromByteOffset: 320, as: LocateProtocol?.self) : nil
      self.allocate = boot.load(fromByteOffset: 40, as: Allocate?.self)
      self.release = boot.load(fromByteOffset: 48, as: Release?.self)
      self.getMap = map
      self.exitBoot = exit
    }

    public struct LoaderPages: ~Copyable {
      public let base: UInt64
      public let count: UInt
      public var length: UInt64 { UInt64(count) * 4096 }
      fileprivate init(base: UInt64, count: UInt) {
        self.base = base
        self.count = count
      }
    }

    /// Work storage, not evidence that DMA has been stopped. Only the EFI
    /// instance that reserved it can finish boot services and publish it.
    public struct ColdWorkspace: ~Copyable {
      public let table: UInt64
      public let regions: Int
      fileprivate init(_ base: UInt64, _ count: Int) { table = base; regions = count }
    }

    /// For the W1 kernel handoff both pinned fence pages have fixed offsets
    /// from x0, outside the published map. Never release the reservation.
    @unsafe public consuming func finishForColdKernel(
      storage: borrowing LoaderPages, map: UnsafeMutableRawBufferPointer,
      into regions: inout UnsafeMutableBufferPointer<FirmwareRegion>
    ) -> ColdWorkspace? {
      guard storage.count == ColdKernelLayout.pages, let layout = ColdKernelLayout(handoff: storage.base),
        case .exited(let count) = finish(map: map, into: &regions) else { return nil }
      for i in 0..<count {
        let r = regions[i]
        if r.type == 2, r.ordinaryWritableRAM, r.base <= storage.base,
          layout.end <= r.base + r.length { return ColdWorkspace(layout.table, count) }
      }
      return nil
    }

    /// Terminal, including on error after an exit attempt. Never call EFI
    /// boot services again. Keep both pages out of every subsequent allocator.
    @unsafe public consuming func finishForColdBoot(
      map: UnsafeMutableRawBufferPointer, into regions: inout UnsafeMutableBufferPointer<FirmwareRegion>
    ) -> ColdWorkspace? {
      guard let pages = reserveLoaderPages(2),
        case .exited(let count) = finish(map: map, into: &regions) else { return nil }
      for i in 0..<count {
        let r = regions[i]
        if r.type == 2, r.ordinaryWritableRAM, r.base <= pages.base,
          pages.base + pages.length <= r.base + r.length {
          return ColdWorkspace(pages.base, count)
        }
      }
      return nil
    }

    /// Snapshot firmware directory entries, without following their addresses.
    @unsafe public func locateTables() -> FirmwareTableLocations? { tableLocations(system) }

    #if arch(riscv64)
      @unsafe public func bootHart() -> FirmwareBootHart? {
        guard let locate else { return nil }
        return FirmwareBootHart(locate)
      }
    #endif

    /// The validated system table owns the mapped runtime-services pointer.
    /// Use it only in the pre-exit physical addressing mode; retain no method.
    @unsafe public func firmwareBootMode() -> FirmwareBootMode? {
      guard let runtime = system.load(fromByteOffset:88,as:UnsafeRawPointer?.self),
        Self.valid(runtime,signature:0x5652_4553_544e_5552,minimum:80),
        let get = runtime.load(fromByteOffset:72,as:GetVariable?.self) else { return nil }
      return bootMode(revision:system.load(fromByteOffset:8,as:UInt32.self), get:get)
    }

    /// Fill only the dedicated 64-byte TBIB field. Verify the firmware/source
    /// provenance separately. No partial seed may escape a failed GetRNG.
    @unsafe public func readBootSeed(into bytes: UnsafeMutableRawBufferPointer) -> Bool {
      FirmwareRNG.readSeed(locate, handles: handles, protocolFor: protocolFor, into: bytes)
    }

    /// Index and SHA-256 Name digest are trusted installation policy, never
    /// archive or ESP input. Missing counters never imply a zero floor.
    @available(macOS 26, *)
    @unsafe public func securityVersionFloor(index:UInt32,name:UnsafeRawBufferPointer)->UInt64? {
      guard let locate, let tcg=FirmwareTCG.open(locate) else { return nil }
      return tcg.securityFloor(index:index,name:name)
    }

    public struct Placement: ~Copyable {
      public let virtual: UInt64
      public let pages: LoaderPages

      public consuming func takePages() -> LoaderPages { pages }
    }

    /// Choose separate virtual/physical positions with fresh firmware RNG words.
    /// This acquires only uninitialized data pages. It neither establishes a
    /// page-table mapping nor grants authority to relocate or execute an image.
    @unsafe public func reserveImage(count: UInt, alignment: UInt64, virtualRegion: Range<UInt64>,
      map: UnsafeMutableRawBufferPointer, into regions: inout UnsafeMutableBufferPointer<FirmwareRegion>
    ) -> Placement? {
      guard count > 0, count <= UInt.max >> 12, let locate, let rng = FirmwareRNG(locate),
        let allocate, let release, let sample = rng.word(),
        let va = virtualBase(region: virtualRegion, bytes: UInt64(count) << 12, alignment: alignment, word: sample)
      else { return nil }
      let bytes = UInt64(count) << 12
      for _ in 0..<8 {
        guard let sample = rng.word(), let (n, _) = snapshot(map: map, into: &regions) else { return nil }
        guard let base = physicalBase(UnsafeBufferPointer(rebasing: regions[..<n]), bytes: bytes,
          alignment: alignment, word: sample) else { continue }
        var actual = base
        let status = allocate(2, 2, count, &actual) // AllocateAddress, EfiLoaderData
        if status == 0x8000_0000_0000_000e { continue } // EFI_NOT_FOUND: stale candidate
        guard status == 0 else { return nil }
        guard actual == base else {
          _ = release(actual, count)
          return nil
        }
        return Placement(virtual: va, pages: LoaderPages(base: actual, count: count))
      }
      return nil
    }

    /// Snapshot a linear GOP mode, not authority to map the aperture.
    @unsafe public func display() -> FirmwareDisplay? {
      guard let locate else { return nil }
      return FirmwareDisplay.current(locate)
    }

    /// Measure pinned, authenticated archive and canonical config bytes before exit.
    /// Does not verify their authenticity. Any failure is terminal for this boot:
    /// firmware may have extended a PCR even if it failed to log the event.
    @unsafe public mutating func measureBootSet(
      _ archive: UnsafeRawBufferPointer,
      configuration: UnsafeRawBufferPointer
    ) -> Bool {
      guard measurement == .notAttempted else { return false }
      measurement = .stopped
      guard !archive.isEmpty, !configuration.isEmpty, let locate,
        let tcg = FirmwareTCG.open(locate)
      else { return false }
      guard tcg.measure(archive, pcr: 8, label: "Tarwin boot set"),
        tcg.measure(configuration, pcr: 9, label: "Tarwin boot configuration")
      else { return false }
      measurement = .complete
      return true
    }

    /// Take an immutable copy of the primary TCG2 log after both extensions.
    /// Capture failure is terminal. The caller pins these dedicated pages
    /// through exit and publication; the final table may grow until exit.
    @unsafe public mutating func captureEventLog(storage: borrowing LoaderPages,
      map: UnsafeMutableRawBufferPointer, into regions: inout UnsafeMutableBufferPointer<FirmwareRegion>
    ) -> PendingFirmwareLog? {
      guard measurement == .complete else { return nil }
      measurement = .stopped
      guard let locate, let tables = tableLocations(system), let tcg = FirmwareTCG.open(locate),
        let (base,last) = tcg.logExtent(), let (count,_) = snapshot(map:map,into:&regions),
        let result = PendingFirmwareLog(base:base,last:last,final:tables.finalEvents,
          storage:storage,regions:UnsafeBufferPointer(rebasing:regions[..<count])) else { return nil }
      measurement = .captured
      return result
    }

    /// Read and close a nonempty regular file on the original loaded image's
    /// volume before the first exit attempt. Discard all output on failure.
    /// The caller owns both buffers and must keep a successful snapshot immutable.
    @unsafe public func readBootFile(
      path: UnsafeBufferPointer<UInt16>,
      into output: UnsafeMutableRawBufferPointer
    ) -> Int? {
      guard let protocolFor else { return nil }
      return readImageFile(image, protocolFor: protocolFor, path: path, into: output)
    }

    /// Reserve a private EfiLoaderData extent while boot services are live.
    /// Holding this reservation, not seeing loader data in a descriptor, confers ownership.
    public func reserveLoaderPages(_ count: UInt) -> LoaderPages? {
      guard count > 0, count <= UInt.max >> 12, let allocate, let release else { return nil }
      var address: UInt64 = 0
      guard allocate(0, 2, count, &address) == 0 else { return nil }
      guard address != 0, address & 4095 == 0, validExtent(address, length: UInt64(count) << 12)
      else {
        _ = release(address, count)
        return nil
      }
      return LoaderPages(base: address, count: count)
    }

    /// Only before the first exit attempt, using the same firmware instance.
    public func releaseLoaderPages(_ pages: consuming LoaderPages) -> Bool {
      guard let release else { return false }
      return release(pages.base, pages.count) == 0
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
      guard measurement != .stopped else { return .preflightFailure }
      var attempted = false
      for _ in 0..<4 {
        guard let (count, key) = snapshot(map: map, into: &regions)
        else { return attempted ? .failedAfterExitAttempt : .preflightFailure }
        let status = exitBoot(image, key)
        if status == 0 { return .exited(regions: count) }
        attempted = true
        if status != 0x8000_0000_0000_0002 { return .failedAfterExitAttempt }
      }
      return .failedAfterExitAttempt
    }

    private func snapshot(map: UnsafeMutableRawBufferPointer,
      into regions: inout UnsafeMutableBufferPointer<FirmwareRegion>) -> (Int, UInt)? {
      guard let p = map.baseAddress, UInt(bitPattern: p) & 7 == 0, map.count >= 40 else { return nil }
      var size = UInt(map.count)
      var key: UInt = 0
      var stride: UInt = 0
      var version: UInt32 = 0
      guard getMap(&size, p, &key, &stride, &version) == 0, size <= UInt(map.count),
        let n = stageFirmwareMap(MappedBytes(base: UnsafeRawPointer(p), size: UInt64(size)),
          stride: UInt64(stride), version: version, into: &regions) else { return nil }
      return (n, key)
    }
  }
#endif
