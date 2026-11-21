import KCore
import Tarboot
import TarwinDevice
import VirtioGuest

// Debug probe only: an EFI application that walks PCI through firmware, calls
// ExitBootServices, then drives one modern virtio-blk controller with the
// unmodified VirtioGuest discovery, negotiation, split-queue and block-request
// code. Storage is only read. Not a Tarwin kernel, DeviceKit or IOMMU test:
// queue and buffer addresses are identity-mapped loader pages, so nothing here
// shows DMA isolation; ACCESS_PLATFORM is still required, as in the driver.

@_extern(c, "gc_load8") func load8(_ a: UInt64) -> UInt8
@_extern(c, "gc_load16") func load16(_ a: UInt64) -> UInt16
@_extern(c, "gc_load32") func load32(_ a: UInt64) -> UInt32
@_extern(c, "gc_store8") func store8(_ a: UInt64, _ v: UInt8)
@_extern(c, "gc_store16") func store16(_ a: UInt64, _ v: UInt16)
@_extern(c, "gc_store32") func store32(_ a: UInt64, _ v: UInt32)
@_extern(c, "gc_store64") func store64(_ a: UInt64, _ v: UInt64)
@_extern(c, "gc_barrier") func barrier()
@_extern(c, "gc_uart") func uart(_ b: UInt8)

typealias Locate =
  @convention(c) (UnsafeRawPointer, UnsafeRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>) ->
  UInt
typealias PciRead =
  @convention(c) (UnsafeRawPointer, UInt32, UInt64, UInt, UnsafeMutableRawPointer) -> UInt
typealias Output = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt16>) -> UInt
typealias Reset = @convention(c) (UInt32, UInt, UInt, UnsafeRawPointer?) -> Void

// The one-sector test image: magic, payload byte count and, at 32..<64, the
// SHA-256 of payload bytes 64..<512. The runner's wrong-payload case flips
// one payload byte after hashing. The virtio-blk drive is attached read-only.
let imageSectors: UInt64 = 1
let payloadBytes: UInt32 = 448
let readBytes: UInt32 = 512
let imageMagic: UInt64 = 0x4347_4e49_5752_4154  // "TARWINGC"

nonisolated(unsafe) var console: UnsafeRawPointer?
nonisolated(unsafe) var output: Output?
nonisolated(unsafe) var scratch = PciWalkScratch()

func put(_ b: UInt8) {
  if b == 10 { put(13) }
  if let console, let output {
    var pair = (UInt16(b), UInt16(0))
    _ = withUnsafeBytes(of: &pair) { output(console, $0.bindMemory(to: UInt16.self).baseAddress!) }
  } else {
    uart(b)
  }
}
func say(_ s: StaticString) { for i in 0..<s.utf8CodeUnitCount { put(s.utf8Start[i]) } }
func hex(_ v: UInt64, _ digits: Int) {
  for i in (0..<digits).reversed() {
    let n = UInt8((v >> UInt64(4 * i)) & 15)
    put(n < 10 ? 48 + n : 87 + n)
  }
}
func bdf(_ b: UInt32, _ d: UInt32, _ f: UInt32) {
  hex(UInt64(b), 2)
  put(58)
  hex(UInt64(d), 2)
  put(46)
  hex(UInt64(f), 1)
}

struct Target: Equatable { var bus: UInt32, device: UInt32, function: UInt32 }

// Phase 1 (boot services live): read-only config reads through firmware.
func efiTarget(_ boot: UnsafeRawPointer) -> (Target, Int)? {
  guard FirmwareBootServices.valid(boot, signature: 0x5652_4553_544f_4f42, minimum: 328),
    let locate = boot.load(fromByteOffset: 320, as: Locate?.self)
  else { return nil }
  var guid = (UInt64(0x11d4_4a1a_2f70_7ebb), UInt64(0x4dc1_3f27_9000_389a))
  var root: UnsafeRawPointer?
  guard withUnsafeBytes(of: &guid, { locate($0.baseAddress!, nil, &root) }) == 0,
    let root, root.load(fromByteOffset: 144, as: UInt32.self) == 0,
    let read = root.load(fromByteOffset: 56, as: PciRead?.self)
  else { return nil }
  return walk(0, 255) { off in
    let a = ((off >> 20) << 24) | (((off >> 15) & 31) << 16) | (((off >> 12) & 7) << 8)
    var value: UInt32 = .max
    return read(root, 2, UInt64(a | (off & 255)), 1, &value) == 0 ? value : .max
  }
}

// The single modern (0x1042) virtio-blk function behind a bridge is the test
// drive; the transitional boot disk on the root bus is never touched.
func walk(_ first: UInt32, _ last: UInt32, _ read: (UInt32) -> UInt32) -> (Target, Int)? {
  var found: Target?
  var count = 0
  var functions = 0
  guard
    visitEcam(
      first, last, scratch: &scratch, read32: read,
      visit: { f in
        functions += 1
        if f.identity == 0x1042_1af4 && f.bus > 0 {
          count += 1
          found = Target(bus: f.bus, device: f.device, function: f.functionNumber)
        }
        return functions < 256
      }), count == 1, let found
  else { return nil }
  return (found, functions)
}

struct Phys: ByteSource {
  let base: UInt64, count: UInt64
  func byteCount() -> UInt64 { count }
  func byteAt(_ offset: UInt64) -> UInt8 { load8(base + offset) }
}
func word(_ a: UInt64) -> UInt64 { UInt64(load32(a)) | UInt64(load32(a + 4)) << 32 }

// ACPI 2.0+ RSDP -> XSDT -> MCFG, read before exit while firmware is mapped.
func mcfg(_ rsdp: UInt64) -> Phys? {
  guard rsdp != 0, word(rsdp) == 0x2052_5450_2044_5352, load8(rsdp + 15) >= 2 else { return nil }
  let xsdt = word(rsdp + 24)
  guard xsdt != 0, load32(xsdt) == 0x5444_5358 else { return nil }
  let length = UInt64(load32(xsdt + 4))
  guard length >= 36, length <= 36 + 8 * 256 else { return nil }
  var p = xsdt + 36
  while p + 8 <= xsdt + length {
    let t = word(p)
    if t != 0 && load32(t) == 0x4746_434d {
      let n = UInt64(load32(t + 4))
      return n <= 44 + 256 * 16 ? Phys(base: t, count: n) : nil
    }
    p += 8
  }
  return nil
}

enum Stage: UInt64 {
  case ecam = 1, identity, bars, discovery, negotiate, config, queue, submit, completion,
    status, overrun
}

struct Result {
  var requests = 0
  var features: UInt64 = 0
  var capacity: UInt64 = 0
  var headerOK = false
  var digest = InlineArray<32, UInt8>(repeating: 0)
  var expected = InlineArray<32, UInt8>(repeating: 0)
}

// Phase 2 (after ExitBootServices): firmware-independent ECAM and controller.
func drive(
  _ ecam: FirmwareEcam, _ want: Target, _ regions: UnsafeMutableBufferPointer<FirmwareRegion>,
  _ count: Int, dma: UInt64, result: inout Result
) -> Stage? {
  let window = ecam.registers
  for i in 0..<count {
    let r = regions[i]
    let ram = r.type >= 1 && r.type <= 4 || r.type == 7
    if ram && r.base < window.base + window.length && window.base < r.base + r.length {
      return .ecam
    }
  }
  guard
    let (found, functions) = walk(UInt32(ecam.firstBus), UInt32(ecam.lastBus), { off in
      UInt64(off) < window.length ? load32(window.base + UInt64(off)) : .max
    }), found == want
  else { return .identity }
  say("TARWIN-GC post-exit ecam: functions=")
  hex(UInt64(functions), 2)
  say(" target=")
  bdf(found.bus, found.device, found.function)
  say(" matches firmware walk\n")
  guard
    let cfg = ecam.address(
      bus: found.bus, device: found.device, function: found.function, register: 0, width: 4)
  else { return .identity }

  // Standard BAR sizing with decode off, then restore; then memory decode
  // and bus mastering for this one function only.
  let command = load16(cfg + 4)
  store16(cfg + 4, command & ~7)
  var addresses = [UInt64](repeating: 0, count: 6)
  var lengths = [UInt64](repeating: 0, count: 6)
  var i = 0
  while i < 6 {
    let at = cfg + 0x10 + UInt64(4 * i)
    let low = load32(at)
    let wide = low & 7 == 4
    if low & 1 != 0 || (wide && i == 5) {
      i += 1
      continue
    }
    store32(at, .max)
    var mask = UInt64(load32(at) & ~15) | (wide ? 0 : 0xffff_ffff_0000_0000)
    store32(at, low)
    var base = UInt64(low & ~15)
    if wide {
      let high = load32(at + 4)
      store32(at + 4, .max)
      mask |= UInt64(load32(at + 4)) << 32
      store32(at + 4, high)
      base |= UInt64(high) << 32
    }
    if mask != 0 && base != 0 {
      addresses[i] = base
      lengths[i] = ~mask &+ 1
    }
    i += wide ? 2 : 1
  }
  store16(cfg + 4, (command & ~7) | 6)
  var bytes = [UInt8](repeating: 0, count: 256)
  for b in 0..<256 { bytes[b] = load8(cfg + UInt64(b)) }

  guard case .found(let t) = discoverVirtioPci(bytes, lengths, 2) else { return .discovery }
  let common = addresses[Int(t.common.bar)] + t.common.offset
  guard addresses[Int(t.common.bar)] != 0, addresses[Int(t.notify.bar)] != 0,
    t.config.length != 0, addresses[Int(t.config.bar)] != 0
  else { return .bars }
  let read: (UInt32, UInt32) -> UInt32 = { off, width in
    let a = common + UInt64(off)
    return width == 1 ? UInt32(load8(a)) : width == 2 ? UInt32(load16(a)) : load32(a)
  }
  let write: (UInt32, UInt32, UInt32) -> Void = { off, width, v in
    let a = common + UInt64(off)
    if width == 1 {
      store8(a, UInt8(truncatingIfNeeded: v))
    } else if width == 2 {
      store16(a, UInt16(truncatingIfNeeded: v))
    } else {
      store32(a, v)
    }
  }
  var spins = 0
  // SIZE_MAX | SEG_MAX | RO; no write, flush, discard or write-zeroes.
  guard case .negotiated(let features) = negotiatePci(0x26, read, write, {
    spins += 1
    return spins > 10_000_000
  }) else { return .negotiate }
  result.features = features
  let config = addresses[Int(t.config.bar)] + t.config.offset
  guard
    let geometry = BlockConfiguration.snapshot(
      features: features, configBytes: t.config.length, generation: { read(21, 1) },
      read: { load8(config + UInt64($0)) })
  else { return .config }
  result.capacity = geometry.capacity
  guard geometry.capacity == imageSectors, features & 32 != 0 else { return .config }

  // Loader pages: queue (page 0), header+status (page 1), data (page 2),
  // untouched guard (page 3). Identity-mapped; not an isolated DMA domain.
  for a in stride(from: dma, to: dma + 4 * 4096, by: 8) { store64(a, a >= dma + 8192 ? ~0 : 0) }
  let memory = QueueMemory(count: 8, descriptors: dma, available: dma + 128, used: dma + 256)
  guard case .offset(let doorbell) = setupPciQueue(0, memory, t, read, write) else {
    return .queue
  }
  let notify = addresses[Int(t.notify.bar)] + doorbell
  write(20, 1, 15)
  guard read(20, 1) == 15 else { return .queue }
  var queue = SplitQueue()
  guard queue.initialize(8) else { return .queue }

  let fill: UInt64 = 0x5a5a_5a5a_5a5a_5a5a
  var hash = Sha256()
  var sector: UInt64 = 0
  while sector < imageSectors {
    let header = dma + 4096
    let status = header + 64
    let data = dma + 8192
    for a in stride(from: data, to: data + 4096, by: 8) { store64(a, fill) }
    let packet = BlockPacket(
      op: .read, sector: sector, bytes: readBytes, header: header, data: data, status: status)
    guard
      submitBlock(
        &queue, sector, packet, geometry,
        [Segment(iova: data, length: readBytes, deviceWrites: true)],
        { a, kind, s in
          store32(a, kind)
          store32(a + 4, 0)
          store64(a + 8, s)
        },
        { a, v in store8(a, v) },
        { slot, iova, length, flags, next in
          let d = memory.descriptors + 16 * UInt64(slot)
          store64(d, iova)
          store32(d + 8, length)
          store16(d + 12, flags)
          store16(d + 14, next)
        },
        { index, head in store16(memory.available + 4 + 2 * UInt64(index), head) },
        { published in
          barrier()
          store16(memory.available + 2, published)
        })
    else { return .submit }
    barrier()
    store16(notify, 0)
    var polls = 0
    var done: UsedBuffer?
    while done == nil {
      switch queue.consume(
        {
          let v = load16(memory.used + 2)
          barrier()
          return v
        },
        { load32(memory.used + 4 + 8 * UInt64($0)) },
        { load32(memory.used + 8 + 8 * UInt64($0)) })
      {
      case .completed(let u): done = u
      case .broken: return .completion
      case .empty:
        polls += 1
        if polls > 50_000_000 { return .completion }
      }
    }
    guard let done, done.cookie == sector else { return .completion }
    guard blockCompletion(load8(status), .read, readBytes, done.written) == .ok else {
      return .status
    }
    // Bytes past the request in the data page and the whole guard page
    // must keep their fill: the device wrote exactly the 512-byte span.
    for a in stride(from: data + UInt64(readBytes), to: dma + 16384, by: 8)
    where word(a) != (a >= dma + 12288 ? ~0 : fill) {
      return .overrun
    }
    for b in 0..<UInt64(readBytes) {
      let byte = load8(data + b)
      if b >= 64 {
        hash.add(byte)
      } else if b >= 32 {
        result.expected[Int(b - 32)] = byte
      }
    }
    result.headerOK = word(data) == imageMagic && load32(data + 8) == payloadBytes
    result.requests += 1
    sector += 1
  }
  result.digest = hash.finish()
  write(20, 1, 0)
  while read(20, 1) != 0 {
    spins += 1
    if spins > 20_000_000 { break }
  }
  store16(cfg + 4, command)
  return nil
}

func digest(_ d: InlineArray<32, UInt8>) { for i in 0..<32 { hex(UInt64(d[i]), 2) } }

@_cdecl("efi_main")
public func efiMain(_ image: UnsafeRawPointer?, _ system: UnsafeRawPointer?) -> UInt {
  guard let image, let system,
    FirmwareBootServices.valid(system, signature: 0x5453_5953_2049_4249, minimum: 120),
    let rt = system.load(fromByteOffset: 88, as: UnsafeRawPointer?.self),
    FirmwareBootServices.valid(rt, signature: 0x5652_4553_544e_5552, minimum: 112),
    let reset = rt.load(fromByteOffset: 104, as: Reset?.self),
    let out = system.load(fromByteOffset: 64, as: UnsafeRawPointer?.self),
    let boot = system.load(fromByteOffset: 96, as: UnsafeRawPointer?.self)
  else { return (1 << 63) | 3 }
  console = out
  output = out.load(fromByteOffset: 8, as: Output?.self)
  guard let (want, functions) = efiTarget(boot), let services = FirmwareBootServices(
    image: image, system: system),
    let heap = services.reserveLoaderPages(64), let dma = services.reserveLoaderPages(4),
    let mapPages = services.reserveLoaderPages(8), let regionPages = services.reserveLoaderPages(4),
    let tables = services.locateTables(), let table = mcfg(tables.rsdp)
  else {
    say("TARWIN-GC-FAIL stage=efi\n")
    reset(2, 0, 0, nil)
    return (1 << 63) | 3
  }
  heapStart(heap.base, heap.length)
  say("TARWIN-GC efi: functions=")
  hex(UInt64(functions), 2)
  say(" target=")
  bdf(want.bus, want.device, want.function)
  say(" via firmware root-bridge config reads; no device I/O before exit\n")
  let capacity = Int(regionPages.length) / MemoryLayout<FirmwareRegion>.stride
  let raw = UnsafeMutableRawPointer(bitPattern: UInt(regionPages.base))!
  var regions = UnsafeMutableBufferPointer(
    start: raw.bindMemory(to: FirmwareRegion.self, capacity: capacity), count: capacity)
  regions.initialize(repeating: .empty)
  let map = UnsafeMutableRawBufferPointer(
    start: UnsafeMutableRawPointer(bitPattern: UInt(mapPages.base)), count: Int(mapPages.length))
  console = nil
  output = nil
  guard case .exited(let count) = services.finish(map: map, into: &regions) else {
    say("TARWIN-GC-FAIL stage=exit\n")
    reset(2, 0, 0, nil)
    return (1 << 63) | 3
  }
  say("TARWIN-GC post-exit: ExitBootServices ok regions=")
  hex(UInt64(count), 4)
  say(" console=raw-uart\n")
  var result = Result()
  var failure: Stage? = .ecam
  if let ecam = firmwareEcam(table, segment: 0, bus: UInt8(want.bus), reservedRegisters: { _ in true }) {
    failure = drive(ecam, want, regions, count, dma: dma.base, result: &result)
  }
  say("TARWIN-GC post-exit io: requests=")
  hex(UInt64(result.requests), 2)
  say(" features=")
  hex(result.features, 16)
  say(" capacity=")
  hex(result.capacity, 4)
  say("\nTARWIN-GC sha256=")
  digest(result.digest)
  say("\nTARWIN-GC header-sha256=")
  digest(result.expected)
  put(10)
  if let failure {
    say("TARWIN-GC-FAIL stage=")
    hex(failure.rawValue, 2)
  } else if !result.headerOK {
    say("TARWIN-GC-BAD-HEADER")
  } else {
    var same = true
    for i in 0..<32 where result.digest[i] != result.expected[i] { same = false }
    say(same ? "TARWIN-GC-PASS" : "TARWIN-GC-PAYLOAD-MISMATCH")
  }
  put(10)
  reset(2, 0, 0, nil)
  return (1 << 63) | 3
}
