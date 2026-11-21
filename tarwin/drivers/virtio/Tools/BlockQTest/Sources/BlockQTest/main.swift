// QTest owns a synthetic guest's RAM and ordered MMIO; only the transport
// and virtio block/network protocols are under test, not Tarwin isolation or boot.
import Darwin
import Foundation
import KCore
import TarwinBlock
import TarwinBlockWire
import TarwinDevice
import TarwinIPC
import TarwinIoCompletion
import VirtioBlockService
import VirtioGuest

struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ text: String) { description = text }
}

private struct DeviceTreeBlob: ByteSource {
  let bytes: [UInt8]
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ offset: UInt64) -> UInt8 { bytes[Int(offset)] }
}

enum TestDisk { case virtio, nvme, ufs }
final class QTest {
  private let process = Process(), input = Pipe(), output = Pipe()
  private var buffered = Data()
  private(set) var pciInterrupts: Set<UInt32> = []
  private(set) var pciNodes: [RegistryNode] = []
  private(set) var mmio: [DeviceRange] = []
  private(set) var error: Error?

  init(
    binary: String, machine: Machine, disk: URL, translated: Bool, neighbors: Bool,
    extraDevices: [String] = [], tcpFixture: Bool = false, listenerSocket: String? = nil,
    storage: TestDisk = .virtio
  ) throws {
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = [
      "-machine", machine == .x64 ? "q35" : "virt", "-accel", "qtest", "-m", "64M",
      "-display", "none", "-nodefaults", "-monitor", "none", "-serial", "none",
      "-qtest", "stdio", "-qtest-log", "/dev/null",
      "-drive", "if=none,id=scratch,format=raw,file=" + disk.path,
      "-device",
    ]
    switch storage {
    case .nvme: process.arguments!.append("nvme,serial=tarwin-test,drive=scratch")
    case .ufs:
      process.arguments! += [
        "ufs,id=ufs0,mcq=off", "-device", "ufs-lu,bus=ufs0,lun=2,drive=scratch",
      ]
    case .virtio:
      process.arguments!.append(
        machine == .x64
          ? "virtio-blk-pci,disable-legacy=on,addr=04.0,drive=scratch,iommu_platform=on"
          : "virtio-blk-device,drive=scratch,iommu_platform=on")
    }
    process.arguments! += extraDevices
    if translated {
      process.arguments! += [
        "-device", "intel-iommu,device-iotlb=off,caching-mode=off,intremap=off",
      ]
    }
    for i in 0..<(neighbors ? 1 : 2) {
      let device =
        machine == .x64 ? "virtio-net-pci,disable-legacy=on,addr=0\(5+i).0" : "virtio-net-device"
      process.arguments! += [
        "-netdev",
        neighbors
          ? "user,id=nic0,restrict=on,net=10.0.2.0/24,host=10.0.2.2,ipv6-net=fd00:23::/64,ipv6-host=fd00:23::2"
            + (tcpFixture ? ",guestfwd=tcp:10.0.2.100:4242-chardev:tcpfixture" : "")
            + (listenerSocket.map { ",hostfwd=unix:\($0)-10.0.2.15:4242" } ?? "")
          : "hubport,id=nic\(i),hubid=1",
        "-device", device + ",netdev=nic\(i),iommu_platform=on,mac=52:54:00:00:00:0\(i+1)",
      ]
    }
    if machine != .x64 { process.arguments! += ["-global", "virtio-mmio.force-legacy=off"] }
    if machine == .arm { process.arguments! += ["-cpu", "cortex-a57"] }
    if machine != .x64 {
      // Dump the device tree with the exact device topology used by the test.
      let tree = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".dtb")
      defer { try? FileManager.default.removeItem(at: tree) }
      let dump = Process()
      dump.executableURL = process.executableURL
      var args = process.arguments!
      args[1] += ",dumpdtb=" + tree.path
      dump.arguments = args
      dump.standardInput = FileHandle.nullDevice
      dump.standardOutput = FileHandle.nullDevice
      try dump.run()
      dump.waitUntilExit()
      guard dump.terminationStatus == 0,
        let devices = firmwareVirtioMmio(DeviceTreeBlob(bytes: Array(try Data(contentsOf: tree))))
      else { throw Failure("Invalid firmware device tree") }
      mmio = devices.map(\.registers).sorted { $0.base < $1.base }
    }
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    if machine == .x64 {
      do { pciNodes = try enumerateQ35(self) } catch {
        close()
        throw error
      }
    }
  }
  func requester(type: UInt16, instance: Int = 0) throws -> UInt16 {
    let identity = ((0x1040 + UInt64(type)) << 16) | 0x1af4
    let match = pciNodes.filter { $0.device.identity == identity }
    guard match.indices.contains(instance), case .pci(0, let bdf) = match[instance].device.location
    else { throw Failure("Missing modern PCI function") }
    return bdf
  }
  func close() {
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
  }

  private func response(_ command: String) throws -> String {
    try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    while true {
      if let end = buffered.firstIndex(of: 10) {
        let line = String(decoding: buffered[..<end], as: UTF8.self)
        buffered.removeSubrange(...end)
        if line == "OK" { return "" }
        if line.hasPrefix("OK ") { return String(line.dropFirst(3)) }
        if line.hasPrefix("IRQ ") {
          let parts = line.split(separator: " ")
          guard parts.count == 3, let irq = UInt32(parts[2]),
            parts[1] == "raise" || parts[1] == "lower"
          else { throw Failure("Invalid IRQ notification") }
          if (16...23).contains(irq) {
            if parts[1] == "raise" { pciInterrupts.insert(irq) } else { pciInterrupts.remove(irq) }
          }
          continue
        }
        throw Failure("QTest rejected \(command): \(line)")
      }
      var descriptor = pollfd(
        fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
      guard poll(&descriptor, 1, 5000) > 0 else { throw Failure("QTest timed out: \(command)") }
      let chunk = output.fileHandleForReading.availableData
      guard !chunk.isEmpty else { throw Failure("QTest exited: \(command)") }
      buffered.append(chunk)
    }
  }

  func send(_ command: String) -> String {
    guard error == nil else { return "" }
    do { return try response(command) } catch {
      self.error = error
      return ""
    }
  }
  func read(_ width: String, _ address: UInt64) -> UInt64 {
    let value = send("read\(width) \(address)")
    guard value.hasPrefix("0x"), let result = UInt64(value.dropFirst(2), radix: 16) else {
      if error == nil { error = Failure("Invalid QTest integer: \(value)") }
      return 0
    }
    return result
  }
  func write<V: FixedWidthInteger>(_ width: String, _ address: UInt64, _ value: V) {
    _ = send("write\(width) \(address) \(value)")
  }
  func require(_ condition: Bool, _ message: String) throws {
    if let error { throw error }
    guard condition else { throw Failure(message) }
  }
}

enum Machine: String {
  case arm = "qemu-system-aarch64"
  case rv = "qemu-system-riscv64"
  case x64 = "qemu-system-x86_64"
  var ram: UInt64 {
    switch self {
    case .arm: 0x4000_0000
    case .rv: 0x8000_0000
    case .x64: 0
    }
  }
}
struct DeviceTransport {
  let features: UInt64
  let configBytes: UInt64, generation: () -> UInt32
  let config: (Int) -> UInt8
  let notify: (Int) -> Void
  let acknowledge: () -> Void
}
func transport(
  _ q: QTest, _ machine: Machine, type: UInt16, instance: Int = 0,
  supported: UInt32, queues: [QueueMemory]
) throws -> DeviceTransport {
  if machine == .x64 {
    return try pciTransport(q, type: type, instance: instance, supported: supported, queues: queues)
  }
  let matching = q.mmio.filter { $0.length >= 0x108 && q.read("l", $0.base + 8) == type }
  guard matching.indices.contains(instance) else {
    throw q.error ?? Failure("Missing virtio MMIO device")
  }
  let window = matching[instance]
  let base = window.base
  let read: (UInt32) -> UInt32 = { UInt32(q.read("l", base + UInt64($0))) }
  let write: (UInt32, UInt32) -> Void = { q.write("l", base + UInt64($0), $1) }
  let expiry = ContinuousClock.now + .seconds(2)
  guard
    case .negotiated(let features) = negotiateMmio(
      UInt32(type), supported, read, write, { .now >= expiry })
  else { throw q.error ?? Failure("MMIO feature negotiation failed") }
  for (index, mem) in queues.enumerated() {
    try q.require(installSplitQueue(UInt32(index), mem, read, write), "Queue installation failed")
  }
  try q.require(driverReady(read, write), "Queue activation failed")
  return DeviceTransport(
    features: features, configBytes: window.length - 0x100, generation: { read(0xfc) },
    config: { UInt8(q.read("b", base + 0x100 + UInt64($0))) },
    notify: { write(0x50, UInt32($0)) },
    acknowledge: {
      let irq = read(0x60)
      if irq != 0 { write(0x64, irq) }
    })
}
// Single-threaded hosted client, not a kernel port table or an IOMMU.
struct TestClient: IoPorts, ~Copyable {
  var port: CompletionPort, references = 0, notifications = 0
  var koid: UInt64 = 1
  mutating func retainPort(_ id: UInt64) -> Bool {
    guard id == koid else { return false }
    references += 1
    return true
  }
  mutating func withLockedPort(_ id: UInt64, _ visit: (inout CompletionPort) -> Void) {
    precondition(id == koid)
    visit(&port)
  }
  mutating func releasePort(_ id: UInt64) { references -= 1 }
  mutating func wakePort(_ id: UInt64, count: Int) { notifications += count }
}

func testBlock(_ q: QTest, _ machine: Machine, _ dma: TranslatedDisk?, encrypted: Bool, intx: Bool)
  throws
{
  let bias = dma?.bias ?? 0
  let mem = QueueMemory(
    count: 8, descriptors: machine.ram + 0x100000, available: machine.ram + 0x101000,
    used: machine.ram + 0x102000)
  let transport = try transport(
    q, machine, type: 2, supported: dma == nil ? 0x6226 : 0x220,
    queues: [
      QueueMemory(
        count: mem.count, descriptors: mem.descriptors + bias, available: mem.available + bias,
        used: mem.used + bias)
    ])
  guard
    let config = BlockConfiguration.snapshot(
      features: transport.features, configBytes: transport.configBytes,
      generation: transport.generation, read: transport.config)
  else { throw Failure("Invalid or changing block device configuration") }
  let capacity = config.capacity
  var queue = SplitQueue()
  try q.require(queue.initialize(Int(mem.count)) && capacity > 7, "Invalid disk geometry")
  let header: UInt64 = machine.ram + 0x110000
  let data: UInt64 = machine.ram + 0x111000
  let status: UInt64 = machine.ram + 0x112000
  let pattern = (0..<512).map { String(format: "%02x", ($0 ^ 0xa5) & 255) }.joined()
  let channel = BlockChannel(capacity: capacity, blockBytes: 512)
  let list = machine.ram + 0x113000
  let scatter = dma == nil
  let firstBytes = scatter ? 193 : 512
  let second = machine.ram + 0x115000
  if scatter {
    try q.require(
      config.maxSegments >= 2 && config.maxSegmentBytes >= 319, "Missing scatter/gather capacity")
    q.write("q", list + 16, second)
    q.write("l", list + 24, 512 - firstBytes)
    q.write("l", list + 28, 0)
    q.write("b", data + UInt64(firstBytes), 0xa7)
    q.write("b", second - 1, 0x59)
    q.write("b", second + UInt64(512 - firstBytes), 0xce)
  }
  q.write("q", list, data + bias)
  q.write("l", list + 8, firstBytes)
  q.write("l", list + 12, 0)
  var ops: [TarwinBlockWire.BlockOp] = [.write, .flush, .read]
  var irq: Q35DiskInterrupt?
  if intx {
    _ = q.send("irq_intercept_in ioapic")
    try q.require(q.pciInterrupts.isEmpty, "Unexpected initial disk interrupt")
  }
  if dma == nil { ops += [.zero, .discard, .flush] }
  for operation in ops {
    let flush = operation == .flush
    let hasVector = operation == .write || operation == .read
    let lba: UInt64 = flush ? 0 : operation == .zero ? 12 : operation == .discard ? 64 : 7
    let blocks: UInt64 = flush ? 0 : operation == .zero ? 3 : operation == .discard ? 8 : 1
    let physicalData = dma != nil && operation == .read ? 0x180000 : data
    let xts =
      encrypted && hasVector
      ? EncryptedSectorCheck(frame: physicalData, read: operation == .read) : nil
    try xts?.prepare(q)
    if let dma, hasVector {
      try dma.mapData(frame: physicalData, access: operation == .read ? .deviceWrite : .deviceRead)
    }
    let key = UInt64(operation.rawValue)
    let payload =
      hasVector ? BlockPayload(list: list + bias, vectors: scatter ? 2 : 1) : BlockPayload()
    var record = RingRecord()
    let cookie = try channel.request(
      BlockCommand(op: operation, lba: lba, blocks: blocks, qos: .interactive, queue: 0), key: key,
      payload: payload, record: &record)
    guard
      case .ready(let pending) = prepareBlockIo(
        record, epoch: channel.epoch, queue: 0,
        config: config, header: header + bias, status: status + bias,
        rangeBuffer: dma == nil ? machine.ram + 0x114000 : nil,
        allows: { addr, n, writable in
          (addr == list + bias && n == (scatter ? 32 : 16) && !writable)
            || (writable == (operation == .read)
              && ((addr == data + bias && n == firstBytes)
                || (scatter && addr == second && n == 512 - firstBytes)))
        },
        readVector: { iova in
          let addr = iova - bias
          guard q.read("l", addr + 12) == 0 else { return nil }
          return BlockDmaVector(address: q.read("q", addr), bytes: UInt32(q.read("l", addr + 8)))
        })
    else { throw q.error ?? Failure("Guest driver rejected block request") }
    let op = pending.op
    if op == .write && xts == nil {
      _ = q.send("write \(data) \(firstBytes) 0x\(pattern.prefix(firstBytes*2))")
      if scatter {
        _ = q.send("write \(second) \(512-firstBytes) 0x\(pattern.dropFirst(firstBytes*2))")
      }
    }
    if op == .read {
      if xts == nil { _ = q.send("memset \(physicalData) \(firstBytes) 0") }
      if scatter { _ = q.send("memset \(second) \(512-firstBytes) 0") }
      if dma != nil { _ = q.send("memset \(data) 512 0x5a") }
    }
    let submitted = pending.submit(
      &queue,
      storeHeader: { iova, kind, sector in
        let addr = iova - bias
        q.write("l", addr, kind)
        q.write("l", addr + 4, 0)
        q.write("q", addr + 8, sector)
      },
      storeRange: { addr, lba, count, flags in
        q.write("q", addr - bias, lba)
        q.write("l", addr - bias + 8, count)
        q.write("l", addr - bias + 12, flags)
      }, setStatus: { addr, value in q.write("b", addr - bias, value) },
      descriptor: { index, address, length, flags, next in
        let slot = mem.descriptors + UInt64(index) * 16
        q.write("q", slot, address)
        q.write("l", slot + 8, length)
        q.write("w", slot + 12, flags)
        q.write("w", slot + 14, next)
      },
      putAvailable: { index, head in q.write("w", mem.available + 4 + UInt64(index) * 2, head) },
      releaseAvailable: { idx in q.write("w", mem.available + 2, idx) })
    try q.require(submitted, "Request \(cookie) submission failed")
    transport.notify(0)
    let deadline = ContinuousClock.now + .seconds(3)
    if intx {
      while q.pciInterrupts.isEmpty && q.error == nil && .now < deadline { _ = q.send("inb 0x80") }
      guard q.pciInterrupts.count == 1, let pin = q.pciInterrupts.first else {
        throw q.error ?? Failure("Expected one asserted PCI INTx input")
      }
      if let irq { try irq.deliver(pin) } else { irq = Q35DiskInterrupt(q, pin: pin) }
    }
    while q.read("w", mem.used + 2) == UInt64(queue.consumed) && q.error == nil && .now < deadline {
      usleep(200)
    }
    let completion = queue.consume(
      { UInt16(q.read("w", mem.used + 2)) },
      { UInt32(q.read("l", mem.used + 4 + UInt64($0) * 8)) },
      { UInt32(q.read("l", mem.used + 8 + UInt64($0) * 8)) })
    guard case .completed(let buffer) = completion else {
      throw q.error ?? Failure("Request \(cookie) has no valid used entry")
    }
    guard
      let done = pending.complete(
        cookie: buffer.cookie, status: UInt8(q.read("b", status)), written: buffer.written)
    else { throw q.error ?? Failure("Malformed driver completion") }
    try channel.finish(done, id: cookie, key: key, bytes: hasVector ? 512 : 0) {
      guard $0 == buffer.cookie else { return false }
      let retire = { !hasVector || dma?.retireData(frame: physicalData) != false }
      if let xts { return xts.finish(q, success: done.status == .ok, retire: retire) }
      return retire()
    }
    if op == .read {
      if dma != nil {
        try q.require(
          q.send("read \(data) 512") == "0x" + String(repeating: "5a", count: 512),
          "Retired frame was modified")
      }
      try q.require(
        q.send("read \(physicalData) \(firstBytes)") == "0x"
          + (xts == nil
            ? String(pattern.prefix(firstBytes * 2)) : String(repeating: "00", count: 512)),
        "512-byte disk readback mismatch")
      if scatter {
        try q.require(
          q.send("read \(second) \(512-firstBytes)") == "0x" + pattern.dropFirst(firstBytes * 2)
            && q.read("b", data + UInt64(firstBytes)) == 0xa7 && q.read("b", second - 1) == 0x59
            && q.read("b", second + UInt64(512 - firstBytes)) == 0xce,
          "Scatter/gather bytes or guards differ")
      }
    }
    transport.acknowledge()
    try irq?.afterDeviceAck()
  }
  if let irq { try irq.finish(expected: ops.count - 1) }
  if let dma {
    try q.require(
      dma.retired == 2 && q.read("l", 0xfed9_0034) == 0,
      "Unexpected remapping fault or missing drain")
  }
  try q.require(channel.notifications == ops.count, "Expected one wake per terminal packet")
}

func run() throws {
  let encrypted = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--vtd-xts"
  let translated =
    encrypted || (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--vtd")
  let neighbors = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--neighbors"
  let streams = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--byte-streams"
  let tcp = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--tcp-receive"
  let listen = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--tcp-listen"
  let intx = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--intx"
  let nvme = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--nvme"
  let ufs =
    CommandLine.arguments.count == 3 && ["--ufs", "--ufs-vtd"].contains(CommandLine.arguments[2])
  guard
    CommandLine.arguments.count == 2 || translated || neighbors || streams || tcp || listen || intx
      || nvme || ufs,
    let machine = Machine(
      rawValue: URL(fileURLWithPath: CommandLine.arguments[1]).lastPathComponent)
  else {
    throw Failure("Usage: BlockQTest /path/to/qemu-system-{aarch64,x86_64,riscv64}")
  }
  guard !translated || machine == .x64 else { throw Failure("--vtd requires q35") }
  guard !intx || machine == .x64 else { throw Failure("--intx requires q35") }
  guard !nvme || machine == .x64 else { throw Failure("--nvme requires q35") }
  guard !ufs || machine == .x64 else { throw Failure("--ufs requires q35") }
  let disk = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".raw")
  try Data(repeating: 0x6c, count: 1 << 20).write(to: disk, options: .withoutOverwriting)
  defer { try? FileManager.default.removeItem(at: disk) }
  if ufs {
    try testUFS(
      binary: CommandLine.arguments[1], disk: disk,
      translated: CommandLine.arguments[2] == "--ufs-vtd")
    return
  }
  if nvme {
    try testNVMe(binary: CommandLine.arguments[1], disk: disk)
    return
  }
  if listen {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    let socket = dir.appendingPathComponent("peer").path
    let q = try QTest(
      binary: CommandLine.arguments[1], machine: machine, disk: disk, translated: false,
      neighbors: true, listenerSocket: socket)
    defer { q.close() }
    try testNeighbors(q, machine, listenerSocket: socket)
    return
  }
  if tcp {
    try withPipePair { _, path, input, output in
      let q = try QTest(
        binary: CommandLine.arguments[1], machine: machine, disk: disk, translated: false,
        neighbors: true, extraDevices: ["-chardev", "pipe,id=tcpfixture,path=" + path],
        tcpFixture: true)
      defer { q.close() }
      try testNeighbors(q, machine, tcpPipes: (input, output))
    }
    return
  }
  if streams {
    try testByteStreams(binary: CommandLine.arguments[1], disk: disk, machine: machine)
    return
  }
  let q = try QTest(
    binary: CommandLine.arguments[1], machine: machine, disk: disk, translated: translated,
    neighbors: neighbors)
  do {
    defer { q.close() }
    if neighbors {
      try testNeighbors(q, machine)
      return
    }
    let dma = translated ? try TranslatedDisk(q) : nil
    try testBlock(q, machine, dma, encrypted: encrypted, intx: intx)
    try dma?.close(q)
    if !translated && !intx { try testNetwork(q, machine) }
  }
  let contents = try Data(contentsOf: disk)
  let sector = 7 * 512
  let pattern = Data((0..<512).map { UInt8(truncatingIfNeeded: $0 ^ 0xa5) })
  var expected = Data(repeating: 0x6c, count: 1 << 20)
  if encrypted {
    guard contents.count == expected.count,
      EncryptedSectorCheck.expectedCiphertext(contents[sector..<sector + 512])
    else { throw Failure("On-disk ciphertext does not match IEEE vector") }
    expected.replaceSubrange(sector..<sector + 512, with: contents[sector..<sector + 512])
  } else {
    expected.replaceSubrange(sector..<sector + 512, with: pattern)
  }
  if !translated {
    expected.replaceSubrange(12 * 512..<15 * 512, with: Data(repeating: 0, count: 3 * 512))
    // Reads after discard are unspecified. Check every byte outside the range.
    guard contents.count == expected.count else { throw Failure("Backing disk size changed") }
    expected.replaceSubrange(64 * 512..<72 * 512, with: contents[64 * 512..<72 * 512])
  }
  guard contents == expected else {
    throw Failure("Backing disk differs outside expected ranges or zero failed to persist")
  }

}
do {
  try run()
  print(
    CommandLine.arguments.last == "--ufs-vtd"
      ? "PASS: q35 UFS translated command pages and directional scatter DMA; nine page drains, read remap, both backing files verified"
      : CommandLine.arguments.last == "--ufs"
        ? "PASS: q35 UFS discovered LUs 1 and 2, stopped on invalid selection, verified LU 2 scatter write/FUA/flush/read and unchanged LU 1"
        : CommandLine.arguments.last == "--nvme"
          ? "PASS: q35 NVMe four-page PRP list, 12 KiB FUA write, flush, guarded readback, shutdown and backing-file check"
          : CommandLine.arguments.last == "--intx"
            ? "PASS: observed disk INTx, IOAPIC masking, Device notifications and handle-authorized rearm on q35"
            : CommandLine.arguments.last == "--tcp-receive"
              ? "PASS: TCP active open, bidirectional stream, lost-segment retransmit and acknowledged FIN against isolated libslirp"
              : CommandLine.arguments.last == "--tcp-listen"
                ? "PASS: passive TCP handshake and bidirectional stream against restricted libslirp via a private Unix socket"
                : CommandLine.arguments.last == "--byte-streams"
                  ? "PASS: bidirectional single-port virtio-console and short uncredited virtio-rng input"
                  : CommandLine.arguments.last == "--vtd-xts"
                    ? "PASS: AES-256-XTS known-answer sector over q35 VT-d, retired before decryption"
                    : CommandLine.arguments.last == "--vtd"
                      ? "PASS: q35 VT-d translated disk DMA, IOTLB drain and same-IOVA remap"
                      : CommandLine.arguments.last == "--neighbors"
                        ? "PASS: router advertisement, SLAAC/DAD, ARP and IPv6 neighbor discovery against restricted libslirp"
                        : "PASS: QEMU virtio-blk scatter/gather write/flush/readback, zero/discard extents and paced UDP delivery across isolated NICs"
  )
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
