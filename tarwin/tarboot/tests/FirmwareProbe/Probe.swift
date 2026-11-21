// QEMU-only firmware entry. Diagnostics power down through runtime services;
// the signed boot composition instead transfers control to a separate ELF.
import Tarboot
import TarwinBoot
import TarwinBootstrap
import TarwinMM
#if TARBOOT_TEST_SIGNED
import TarwinW0Verify
#endif

typealias Output = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt16>) -> UInt
private typealias Reset = @convention(c) (UInt32, UInt, UInt, UnsafeRawPointer?) -> Void
nonisolated(unsafe) private var storage = InlineArray<4096, UInt64>(repeating: 0)
nonisolated(unsafe) private var records = InlineArray<512, FirmwareRegion>(repeating: .empty)
nonisolated(unsafe) private var cpu = BootCPU()

#if TARBOOT_TEST_FLOOR
  // The independently provisioned debug TPM counter's SHA-256 Name.
  var counterName: InlineArray<32, UInt8> {
    [153,36,237,96,117,77,224,179,204,215,111,177,106,104,33,94,
     62,216,121,131,3,130,95,107,144,89,201,29,0,141,121,15]
  }
#endif

func writeDiagnostic(_ message: StaticString, console: UnsafeRawPointer, output: Output) {
  for i in 0..<message.utf8CodeUnitCount {
    var character = (UInt16(message.utf8Start[i]), UInt16(0))
    _ = withUnsafeBytes(of: &character) {
      output(console, $0.bindMemory(to: UInt16.self).baseAddress!)
    }
  }
}

@_cdecl("efi_main")
public func efiMain(_ image: UnsafeRawPointer?, _ system: UnsafeRawPointer?) -> UInt {
  let unsupported = (UInt(1) << 63) | 3
  // Only tables owned by firmware during EFI image entry; validate before field reads.
  guard let image, let system,
    FirmwareBootServices.valid(system, signature: 0x5453_5953_2049_4249, minimum: 120),
    let runtime = system.load(fromByteOffset: 88, as: UnsafeRawPointer?.self),
    FirmwareBootServices.valid(runtime, signature: 0x5652_4553_544e_5552, minimum: 112),
    let shutdown = runtime.load(fromByteOffset: 104, as: Reset?.self),
    let console = system.load(fromByteOffset: 64, as: UnsafeRawPointer?.self),
    let output = console.load(fromByteOffset: 8, as: Output?.self)
  else { return unsupported }
  writeDiagnostic("TARWIN-FIRMWARE-EXIT-TEST\r\n", console: console, output: output)
  // The two static arrays are disjoint, initialized, naturally aligned and exclusive.
  let done = withUnsafeMutableBytes(of: &storage) { raw in
    withUnsafeMutableBytes(of: &records) { bytes in
      var buffer = bytes.bindMemory(to: FirmwareRegion.self)
      #if arch(arm64)
        let pageSize: UInt64 = 16384
      #else
        let pageSize: UInt64 = 4096
      #endif
      guard var boot = FirmwareBootServices(image: image, system: system),
        let tables = boot.locateTables()
      else { return false }
      #if TARBOOT_TEST_CPU
        let snapshotOK=processorEvidence(console:console,output:output)
        #if TARBOOT_TEST_CPU_REFUSAL || TARBOOT_TEST_X64_REFUSAL
        guard !snapshotOK else { return false }
        #else
        guard snapshotOK else { return false }
        #endif
      #endif
      #if TARBOOT_TEST_FLOOR
        // Public SHA-256 Name of this fixture's WRITTEN NV public area.
        // ProvisionCounter runs offline before QEMU; the ESP cannot select it.
        var name = counterName
        let observedFloor = withUnsafeBytes(of:&name,{boot.securityVersionFloor(index:0x0180f001,name:$0)})
        guard observedFloor == 1
        else {
          writeDiagnostic("TARWIN-NV-READ-FAILED\r\n",console:console,output:output)
          return false
        }
        name[0]^=1
        guard withUnsafeBytes(of:&name,{boot.securityVersionFloor(index:0x0180f001,name:$0)})==nil else { return false }
        writeDiagnostic("TARWIN-NV-FLOOR-ONE\r\n",console:console,output:output)
      #endif
      #if TARBOOT_TEST_SECURE_FIRMWARE
        guard let mode = boot.firmwareBootMode(), mode.secureBoot, !mode.setupMode else {
          writeDiagnostic("TARWIN-SECURE-MODE-FAILED\r\n", console:console, output:output)
          return false
        }
        if !mode.meetsFirmwareMinimum {
          writeDiagnostic("TARWIN-UEFI-BELOW-MINIMUM\r\n", console:console, output:output)
        }
      #endif
      #if TARBOOT_TEST_DISPLAY
        guard let display = boot.display() else {
          writeDiagnostic("TARWIN-GOP-UNAVAILABLE\r\n", console: console, output: output)
          return false
        }
      #endif
      #if TARBOOT_TEST_STAGE0
        let archivePages: UInt = 256
      #else
        let archivePages: UInt = 1
      #endif
      guard let archive = boot.reserveLoaderPages(archivePages),
        let storage = boot.reserveLoaderPages(6),
        let archiveBase = UnsafeMutableRawPointer(bitPattern: UInt(archive.base)),
        let size = exerciseFile(
          &boot, system: system, console: console, output: output,
          into: UnsafeMutableRawBufferPointer(start: archiveBase, count: Int(archive.length)))
      else { return false }
      #if TARBOOT_TEST_W1_EVIDENCE
        guard refusesFirmwareKernel(.init(start: archiveBase, count: size), services: boot)
        else { return false }
        writeDiagnostic("TARWIN-W1-FIRMWARE-KERNEL-REFUSED\r\n", console: console, output: output)
      #endif
      #if TARBOOT_TEST_SIGNED
        let immutable = UnsafeRawBufferPointer(start: archiveBase, count: size)
        let candidate = verifyBootSet(immutable, services: &boot, system: system, floor: observedFloor, baseline: snapshotOK)
        #if TARBOOT_TEST_X64_REFUSAL
          guard !snapshotOK, candidate == nil else { return false }
          writeDiagnostic("TARWIN-X64-TARGET-REFUSED\r\n",console:console,output:output)
          return true
        #elseif TARBOOT_BAD_SIGNATURE
          guard candidate == nil else { return false }
          writeDiagnostic("TARWIN-SIGNATURE-REJECTED\r\n",console:console,output:output)
          return true
        #else
          guard let kernel = candidate, kernel.range.lowerBound >= 0, kernel.range.upperBound <= size,
            kernel.bytes.baseAddress == immutable.baseAddress?.advanced(by:kernel.range.lowerBound),
            kernel.bytes.count == kernel.range.count, kernel.securityVersion >= observedFloor! else {
              writeDiagnostic("TARWIN-SIGNED-VERIFICATION-FAILED\r\n",console:console,output:output)
              return false
            }
          writeDiagnostic("TARWIN-SIGNED-ARCHIVE-AND-KERNEL-VERIFIED\r\n",console:console,output:output)
        #endif
      #endif
      #if TARBOOT_TEST_RNG
        var seed = InlineArray<64, UInt8>(repeating: 0)
        guard withUnsafeMutableBytes(of: &seed, { boot.readBootSeed(into: $0) }) else {
          writeDiagnostic("TARWIN-RNG-UNAVAILABLE\r\n", console: console, output: output)
          return false
        }
        let window: Range<UInt64> = 0xffff_8000_0000_0000..<0xffff_c000_0000_0000
        guard
          let placed = boot.reserveImage(
            count: UInt(64 * pageSize / 4096), alignment: 64 * pageSize,
            virtualRegion: window, map: raw, into: &buffer), window.contains(placed.virtual),
          placed.virtual % (64 * pageSize) == 0, placed.pages.base % (64 * pageSize) == 0
        else {
          writeDiagnostic("TARWIN-PLACEMENT-FAILED\r\n", console: console, output: output)
          return false
        }
        let virtual = placed.virtual
        let owned = placed.takePages()
        #if TARBOOT_ENTER_W0
          guard let stack = boot.reserveLoaderPages(16),
            let entry = installArmKernel(kernel, in: owned)
          else {
            writeDiagnostic("TARWIN-IMAGE-INSTALL-REFUSED\r\n", console: console, output: output)
            return false
          }
          writeDiagnostic("TARBOOT-PHYSICAL-IMAGE-READY\r\n", console: console, output: output)
        #endif
      #else
        guard let owned = boot.reserveLoaderPages(UInt(2 * 64 * pageSize / 4096 - 1)) else {
          return false
        }
      #endif
      #if TARBOOT_TEST_TPM
        guard let logPages = boot.reserveLoaderPages(64),
          let pending = boot.captureEventLog(storage: logPages, map: raw, into: &buffer)
        else {
          writeDiagnostic("TARWIN-LOG-CAPTURE-FAILED\r\n", console: console, output: output)
          return false
        }
      #endif
      #if TARBOOT_TEST_COLD_FENCE
        guard let fencePages = boot.finishForColdBoot(map: raw, into: &buffer) else { return false }
        let n = fencePages.regions
      #else
        guard case .exited(let n) = boot.finish(map: raw, into: &buffer) else { return false }
      #endif
      #if TARBOOT_TEST_SMP_TABLES
        #if arch(arm64)
          let family = ProcessorFamily.arm64
        #elseif arch(x86_64)
          let family = ProcessorFamily.x64
        #else
          let family = ProcessorFamily.rv64
        #endif
        var ids = InlineArray<4, FirmwareProcessor>(repeating: .empty)
        guard
          withUnsafeMutableBytes(
            of: &ids,
            { bytes in
              firmwareProcessors(
                tables, family: family, in: UnsafeBufferPointer(rebasing: buffer[..<n]),
                into: bytes.bindMemory(to: FirmwareProcessor.self)) == 4
            })
        else { return false }
        #if TARBOOT_TEST_PSCI
          guard armPSCIConduit(tables, in: UnsafeBufferPointer(rebasing: buffer[..<n])) == .smc,
            withUnsafeBytes(of: &ids, { bootCPUOnly($0.bindMemory(to: FirmwareProcessor.self)) })
          else { return false }
        #endif
      #endif
      #if TARBOOT_TEST_TPM
        guard
          let firmwareLogSize = pending.finish(
            in: logPages, regions: UnsafeBufferPointer(rebasing: buffer[..<n])),
          let logBase = UnsafeRawPointer(bitPattern: UInt(logPages.base)),
          checkEventLog(UnsafeRawBufferPointer(start: logBase, count: firmwareLogSize))
        else { return false }
        #if TARBOOT_TEST_FIFO
          guard let logSize = exerciseKernelFIFO(UnsafeRawBufferPointer(start: archiveBase, count: size),
            log: UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(mutating: logBase),
              count: Int(logPages.length)), used: firmwareLogSize) else { return false }
        #else
          let logSize = firmwareLogSize
        #endif
      #endif
      guard
        let inspected = inspectFirmwareTables(
          tables, in: UnsafeBufferPointer(rebasing: buffer[..<n])),
        inspected.rsdp != 0 || inspected.treeBytes > 0
      else { return false }
      #if TARBOOT_TEST_RNG
        var info = emptyBootInfo()
        info.year = 26
        info.month = 11
        info.week = 1
        info.security = 2  // QEMU debug mode; do not assert production Secure Boot.
        #if TARBOOT_TEST_SECURE_FIRMWARE
          info.security |= 1 // OVMF admitted this PE, not the archive it reads.
        #endif
        info.rsdp = inspected.rsdp
        info.deviceTree = inspected.deviceTree
        info.uefiTable = UInt64(UInt(bitPattern: system))
        info.kernelVirtual = virtual
        info.kernelPhysical = owned.base
        #if TARBOOT_TEST_TPM
          info.logAddress = logPages.base
          info.logSize = UInt64(logSize)
        #endif
        withUnsafeBytes(of: &seed) { s in
          func word(_ i: Int) -> UInt64 { s.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) }
          info.entropy0 = word(0)
          info.entropy1 = word(1)
          info.entropy2 = word(2)
          info.entropy3 = word(3)
          info.entropy4 = word(4)
          info.entropy5 = word(5)
          info.entropy6 = word(6)
          info.entropy7 = word(7)
        }
        #if TARBOOT_TEST_DISPLAY
          info.framebuffer = display.base
          info.width = UInt32(display.mode.width)
          info.height = UInt32(display.mode.height)
          info.stride = UInt32(display.mode.stride)
          info.format = display.mode.format
        #endif
        guard
          writeHandoff(
            info, regions: UnsafeBufferPointer(rebasing: buffer[..<n]),
            storage: storage, archive: archive, archiveBytes: UInt64(size)),
          let p = UnsafeRawPointer(bitPattern: UInt(storage.base)),
          let received = readHandoff(
            block: UnsafeRawBufferPointer(start: p, count: 4096), at: storage.base,
            map: UnsafeRawBufferPointer(
              start: p.advanced(by: 4096), count: Int(storage.length) - 4096),
            at: storage.base + 4096), received.bootSet == archive.base,
          received.bootSetSize == UInt64(size),
          received.security == info.security,
          received.kernelVirtual == virtual, received.kernelPhysical == owned.base,
          received.logAddress == info.logAddress, received.logSize == info.logSize,
          received.rsdp == inspected.rsdp, received.deviceTree == inspected.deviceTree,
          received.entropy0 == info.entropy0 && received.entropy1 == info.entropy1
            && received.entropy2 == info.entropy2 && received.entropy3 == info.entropy3
            && received.entropy4 == info.entropy4 && received.entropy5 == info.entropy5
            && received.entropy6 == info.entropy6 && received.entropy7 == info.entropy7
        else { return false }
        #if TARBOOT_TEST_GENERATION
          guard exerciseGeneration(bootSeed: .init(start: p + 96, count: 64),
            regions: .init(rebasing: buffer[..<n])) else { return false }
        #endif
        #if TARBOOT_TEST_COLD_FENCE
          guard exerciseColdEvidence(pages: fencePages, block: .init(start: p, count: 4096),
            map: .init(start: p + 4096, count: Int(storage.length) - 4096),
            archive: .init(start: archiveBase, count: size)) else { return false }
        #elseif TARBOOT_TEST_W1_EVIDENCE
          guard exerciseW1Evidence(block: .init(start: p, count: 4096), at: storage.base,
            map: .init(start: p + 4096, count: Int(storage.length) - 4096),
            archive: .init(start: archiveBase, count: size), at: archive.base),
            emitW1Refusal() else { return false }
        #endif
      #endif
      #if TARBOOT_ENTER_W0
        cleanRange(owned.base, owned.base + owned.length)
        cleanRange(storage.base, storage.base + storage.length)
        cleanRange(archive.base, archive.base + archive.length)
        cleanRange(logPages.base, logPages.base + logPages.length)
        cleanRange(stack.base, stack.base + stack.length)
        enterArm(storage.base, entry, stack.base + stack.length)
        while true {}
      #else
      var usable = false
      var runtime = false
      var covered = false
      for i in 0..<n {
        let kind = buffer[i].bootMapKind(afterExit: true)
        usable = usable || kind == 0
        runtime = runtime || kind == 2 || kind == 3
        let r = buffer[i]
        if r.type == 2, kind == 1, r.attributes >> 63 == 0, owned.base >= r.base,
          owned.base - r.base < r.length, owned.length <= r.length - (owned.base - r.base)
        {
          covered = true
        }
      }
      guard
        usable && runtime && covered
          && checkPage(base: owned.base, length: owned.length, pageSize: pageSize)
          && runBootCPU(UInt64(n))
      else { return false }
      #if TARBOOT_TEST_TRANSLATION
        guard checkUserTranslation(base: owned.base, length: owned.length) else { return false }
      #endif
      #if TARBOOT_TEST_DISPLAY
        // Dedicated debug VM. Its GOP aperture remains identity mapped after
        // exit; no graphics driver or other CPU is using the framebuffer.
        let mapped = UnsafeMutableRawBufferPointer(
          start: UnsafeMutableRawPointer(bitPattern: UInt(display.base)),
          count: display.mode.byteCount)
        guard var debug = DebugConsole(mapped: mapped, mode: display.mode, debugImage: true) else {
          return false
        }
        return debug.write("TARWIN TEST")
      #else
        return true
      #endif
      #endif
    }
  }
  if done { shutdown(2, 0, 0, nil) }  // EfiResetShutdown; still in physical addressing mode.
  // Failure after a partial firmware shutdown is terminal. Never return into boot services.
  while true {}
}

// Only call for the dedicated firmware allocation in the identity map.
// Never use arbitrary RAM found by scanning the map. No CPU or device shares it.
private func checkPage(base: UInt64, length: UInt64, pageSize: UInt64) -> Bool {
  guard var arena = arenaFromReservation(base: base, length: length, pageSize: pageSize) else {
    return false
  }
  let page = takePages(&arena, order: 0)
  guard page.ok, let bytes = UnsafeMutableRawPointer(bitPattern: UInt(page.address)) else {
    return false
  }
  let words = bytes.bindMemory(to: UInt64.self, capacity: Int(pageSize / 8))
  for i in 0..<Int(pageSize / 8) { words.advanced(by: i).initialize(to: page.address ^ UInt64(i)) }
  let correct = pageMatches(UnsafePointer(words), count: Int(pageSize / 8), value: page.address)
  for i in 0..<Int(pageSize / 8) { words[i] = 0 }
  words.deinitialize(count: Int(pageSize / 8))
  guard correct, givePages(&arena, address: page.address, order: 0),
    !givePages(&arena, address: page.address, order: 0)
  else { return false }
  let heapPage = takePages(&arena, order: 0)
  guard heapPage.ok, let p = UnsafeMutableRawPointer(bitPattern: UInt(heapPage.address)) else {
    return false
  }
  // QEMU's selected Arm CPU is Cortex-A72 (no MTE). Keep this page dedicated
  // until shutdown; don't recycle a typed virtual range into the page allocator.
  var metadata = InlineArray<2, HeapSlab>(repeating: HeapSlab())
  return withUnsafeMutableBytes(of: &metadata) { m in
    guard
      var heap = HeapArena(
        storage: .init(start: p, count: Int(pageSize)),
        metadata: m.bindMemory(to: HeapSlab.self), policy: .noHardwareTags),
      heap.provision(typeID: 0x11, sizeClass: 32, slots: 1),
      heap.provision(typeID: 0x22, sizeClass: 32, slots: 1),
      let a = heap.allocate(size: 27, alignment: 16, typeID: 0x11),
      let b = heap.allocate(size: 27, alignment: 16, typeID: 0x22), a != b
    else { return false }
    a.storeBytes(of: UInt64.max, as: UInt64.self)
    b.storeBytes(of: UInt64(19), as: UInt64.self)
    guard heap.free(a), !heap.free(a), let pending = heap.beginQuarantine(),
      heap.allocate(size: 27, alignment: 16, typeID: 0x11) == nil,
      heap.completeQuarantine(pending),
      let reused = heap.allocate(size: 27, alignment: 16, typeID: 0x11), reused == a,
      reused.load(as: UInt64.self) == 0, b.load(as: UInt64.self) == 19
    else { return false }
    return true
  }
}

@inline(never)
private func pageMatches(_ words: UnsafePointer<UInt64>, count: Int, value: UInt64) -> Bool {
  for i in 0..<count where words[i] != value ^ UInt64(i) { return false }
  return true
}

// EDK II masks CPU interrupts before returning from ExitBootServices. Exercise
// the boot composition here without starting another CPU or programming a timer.
private func runBootCPU(_ initial: UInt64) -> Bool {
  guard cpu.start(counter: 0, frequency: 1_000_000, initialContext: initial),
    let lone = cpu.service(.poll, counter: 0), lone.next == initial, lone.sliceCounter == nil,
    let two = cpu.service(.add(context: initial + 1, qos: 3), counter: 0),
    let alarm = two.sliceCounter, alarm == 3000,
    let swap = cpu.service(.poll, counter: alarm), swap.next == initial + 1,
    let parked = cpu.service(.sleepRunning, counter: alarm), parked.next == initial,
    parked.sliceCounter == nil,
    let idle = cpu.service(.retire(context: initial), counter: alarm), idle.next == 0
  else { return false }
  return true
}
