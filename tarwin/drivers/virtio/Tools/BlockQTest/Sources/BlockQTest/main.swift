// QTest owns a synthetic guest's RAM and ordered MMIO; only the transport
// and virtio-blk protocol are under test, not Tarwin isolation or boot.
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

  init(binary: String, disk: URL) throws {
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = [
      "-machine", "virt", "-accel", "qtest", "-cpu", "cortex-a57", "-m", "64M",
      "-display", "none", "-nodefaults", "-monitor", "none", "-serial", "none",
      "-qtest", "stdio", "-qtest-log", "/dev/null", "-global", "virtio-mmio.force-legacy=off",
      "-drive", "if=none,id=scratch,format=raw,file=" + disk.path,
      "-device", "virtio-blk-device,drive=scratch,iommu_platform=on",
    ]
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

func testBlock(_ q: QTest) throws {
  // The QEMU Arm virt machine has 32 transports at stride 0x200.
  guard
    let base = (0..<32).map({ UInt64(0x0a00_0000 + 0x200 * $0) })
      .first(where: { q.read("l", $0 + 8) == 2 })
  else {
    throw q.error ?? Failure("No virtio-blk MMIO transport")
  }
  let read: (UInt32) -> UInt32 = { UInt32(q.read("l", base + UInt64($0))) }
  let write: (UInt32, UInt32) -> Void = { q.write("l", base + UInt64($0), $1) }
  let expiry = ContinuousClock.now + .seconds(2)
  guard case .negotiated(let features) = negotiateMmio(2, 0x2220, read, write, { .now >= expiry })
  else {
    throw q.error ?? Failure("Modern, ACCESS_PLATFORM feature negotiation failed")
  }
  let mem = QueueMemory(
    count: 8, descriptors: 0x4010_0000, available: 0x4010_1000, used: 0x4010_2000)
  try q.require(
    installSplitQueue(0, mem, read, write) && driverReady(read, write), "Queue activation failed")
  let capacity = UInt64(read(0x100)) | UInt64(read(0x104)) << 32
  var queue = SplitQueue()
  try q.require(queue.initialize(Int(mem.count)) && capacity > 7, "Invalid disk geometry")
  let header: UInt64 = 0x4011_0000
  let data: UInt64 = 0x4011_1000
  let status: UInt64 = 0x4011_2000
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
    write(0x50, 0)
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
    let irq = read(0x60)
    if irq != 0 { write(0x64, irq) }
  }
}

func run() throws {
  guard CommandLine.arguments.count == 2 else {
    throw Failure("Usage: BlockQTest /path/to/qemu-system-aarch64")
  }
  let disk = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".raw")
  try Data(repeating: 0, count: 1 << 20).write(to: disk, options: .withoutOverwriting)
  defer { try? FileManager.default.removeItem(at: disk) }
  let q = try QTest(binary: CommandLine.arguments[1], disk: disk)
  do {
    defer { q.close() }
    try testBlock(q)
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
  print("PASS: QEMU virtio-blk modern MMIO write, flush and 512-byte readback")
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
