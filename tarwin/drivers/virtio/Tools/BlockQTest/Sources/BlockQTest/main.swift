// QTest owns a synthetic guest's RAM and ordered MMIO; only the transport
// and virtio block/network protocols are under test, not Tarwin isolation or boot.
import Darwin
import Foundation
import VirtioGuest

struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ text: String) { description = text }
}

final class QTest {
  private let process = Process(), input = Pipe(), output = Pipe()
  private var buffered = Data()
  private(set) var error: Error?

  init(binary: String, machine: Machine, disk: URL) throws {
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = [
      "-machine", machine == .x64 ? "q35" : "virt", "-accel", "qtest", "-m", "64M",
      "-display", "none", "-nodefaults", "-monitor", "none", "-serial", "none",
      "-qtest", "stdio", "-qtest-log", "/dev/null",
      "-drive", "if=none,id=scratch,format=raw,file=" + disk.path,
      "-device",
      machine == .x64
        ? "virtio-blk-pci,disable-legacy=on,addr=04.0,drive=scratch,iommu_platform=on"
        : "virtio-blk-device,drive=scratch,iommu_platform=on",
    ]
    for i in 0..<2 {
      let device =
        machine == .x64 ? "virtio-net-pci,disable-legacy=on,addr=0\(5+i).0" : "virtio-net-device"
      process.arguments! += [
        "-netdev", "hubport,id=nic\(i),hubid=1",
        "-device", device + ",netdev=nic\(i),iommu_platform=on,mac=52:54:00:00:00:0\(i+1)",
      ]
    }
    if machine != .x64 { process.arguments! += ["-global", "virtio-mmio.force-legacy=off"] }
    if machine == .arm { process.arguments! += ["-cpu", "cortex-a57"] }
    process.standardInput = input
    process.standardOutput = output
    try process.run()
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
        if line.hasPrefix("IRQ ") { continue }
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
  let candidates: [UInt64] =
    machine == .rv
    ? (0..<8).map { UInt64(0x1000_1000 + 0x1000 * $0) }
    : (0..<32).map { UInt64(0x0a00_0000 + 0x200 * $0) }
  let matching = candidates.filter { q.read("l", $0 + 8) == type }
  guard matching.indices.contains(instance) else {
    throw q.error ?? Failure("Missing virtio MMIO device")
  }
  let base = matching[instance]
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
    features: features, config: { UInt8(q.read("b", base + 0x100 + UInt64($0))) },
    notify: { write(0x50, UInt32($0)) },
    acknowledge: {
      let irq = read(0x60)
      if irq != 0 { write(0x64, irq) }
    })
}
func testBlock(_ q: QTest, _ machine: Machine) throws {
  let mem = QueueMemory(
    count: 8, descriptors: machine.ram + 0x100000, available: machine.ram + 0x101000,
    used: machine.ram + 0x102000)
  let transport = try transport(q, machine, type: 2, supported: 0x2220, queues: [mem])
  let capacity = (0..<8).reduce(UInt64(0)) { $0 | UInt64(transport.config($1)) << (8 * $1) }
  let features = transport.features
  var queue = SplitQueue()
  try q.require(queue.initialize(Int(mem.count)) && capacity > 7, "Invalid disk geometry")
  let header: UInt64 = machine.ram + 0x110000
  let data: UInt64 = machine.ram + 0x111000
  let status: UInt64 = machine.ram + 0x112000
  let pattern = (0..<512).map { String(format: "%02x", ($0 ^ 0xa5) & 255) }.joined()
  for (i, op) in [GuestBlockOp.write, .flush, .read].enumerated() {
    let flush = op == .flush
    let p = BlockPacket(
      op: op, sector: flush ? 0 : 7, bytes: flush ? 0 : 512, header: header, data: data,
      status: status)
    let cookie = UInt64(i + 1)
    if op == .write { _ = q.send("write \(data) 512 0x\(pattern)") }
    if op == .read { _ = q.send("memset \(data) 512 0") }
    let submitted = submitBlock(
      &queue, cookie, p, capacity, features,
      { addr, kind, sector in
        q.write("l", addr, kind)
        q.write("l", addr + 4, 0)
        q.write("q", addr + 8, sector)
      },
      { addr, value in q.write("b", addr, value) },
      { index, address, length, flags, next in
        let slot = mem.descriptors + UInt64(index) * 16
        q.write("q", slot, address)
        q.write("l", slot + 8, length)
        q.write("w", slot + 12, flags)
        q.write("w", slot + 14, next)
      },
      { index, head in q.write("w", mem.available + 4 + UInt64(index) * 2, head) },
      { idx in q.write("w", mem.available + 2, idx) })
    try q.require(submitted, "Request \(cookie) submission failed")
    transport.notify(0)
    let deadline = ContinuousClock.now + .seconds(3)
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
    try q.require(
      buffer.cookie == cookie
        && blockCompletion(UInt8(q.read("b", status)), op, p.bytes, buffer.written) == .ok,
      "Request \(cookie) failed or returned an invalid length")
    if op == .read {
      try q.require(q.send("read \(data) 512") == "0x" + pattern, "512-byte disk readback mismatch")
    }
    transport.acknowledge()
  }
}

func run() throws {
  guard CommandLine.arguments.count == 2,
    let machine = Machine(
      rawValue: URL(fileURLWithPath: CommandLine.arguments[1]).lastPathComponent)
  else {
    throw Failure("Usage: BlockQTest /path/to/qemu-system-{aarch64,x86_64,riscv64}")
  }
  let disk = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".raw")
  try Data(repeating: 0, count: 1 << 20).write(to: disk, options: .withoutOverwriting)
  defer { try? FileManager.default.removeItem(at: disk) }
  let q = try QTest(binary: CommandLine.arguments[1], machine: machine, disk: disk)
  do {
    defer { q.close() }
    try testBlock(q, machine)
    try testNetwork(q, machine)
  }
  let contents = try Data(contentsOf: disk)
  let sector = 7 * 512
  let pattern = Data((0..<512).map { UInt8(truncatingIfNeeded: $0 ^ 0xa5) })
  guard contents.count == 1 << 20, contents[sector..<sector + 512].elementsEqual(pattern),
    contents[..<sector].allSatisfy({ $0 == 0 }), contents[(sector + 512)...].allSatisfy({ $0 == 0 })
  else { throw Failure("Backing disk changed outside the requested sector or failed to persist") }
}
do {
  try run()
  print("PASS: QEMU virtio-blk write/flush/readback and isolated virtio-net TX/RX")
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
