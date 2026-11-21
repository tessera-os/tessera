import Darwin
import Foundation
import VirtioGuest

func withPipePair(_ run: (URL, String, FileHandle, FileHandle) throws -> Void) throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(
    at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: dir) }
  let console = dir.appendingPathComponent("console").path
  func pipe(_ suffix: String) throws -> FileHandle {
    let path = console + suffix
    guard mkfifo(path, 0o600) == 0 else { throw Failure("mkfifo failed") }
    let fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw Failure("cannot open test pipe") }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }
  let input = try pipe(".in")
  let output = try pipe(".out")
  defer {
    try? input.close()
    try? output.close()
  }
  try run(dir, console, input, output)
}

func testByteStreams(binary: String, disk: URL, machine: Machine) throws {
  try withPipePair { dir, console, input, output in
    let source = dir.appendingPathComponent("rng-source")
    let sample = Array(0..<UInt8(127))
    try Data(sample).write(to: source)
    func device(_ name: String, _ addr: Int) -> String {
      machine == .x64 ? "\(name)-pci,disable-legacy=on,addr=0\(addr).0" : "\(name)-device"
    }
    let q = try QTest(
      binary: binary, machine: machine, disk: disk, translated: false, neighbors: false,
      extraDevices: [
        "-chardev", "pipe,id=ch,path=" + console, "-device",
        device("virtio-serial", 7) + ",id=vs,iommu_platform=on",
        "-device", "virtconsole,bus=vs.0,nr=0,chardev=ch",
        "-object", "rng-random,id=feed,filename=" + source.path, "-device",
        device("virtio-rng", 8) + ",rng=feed,iommu_platform=on,max-bytes=13,period=1000",
      ])
    defer { q.close() }
    func ring(_ i: Int) -> QueueMemory {
      let at = machine.ram + 0x800000 + UInt64(i) * 65536
      return QueueMemory(count: 8, descriptors: at, available: at + 4096, used: at + 8192)
    }
    let serial = try transport(q, machine, type: 3, supported: 0, queues: [ring(0), ring(1)])
    let rng = try transport(q, machine, type: 4, supported: 0, queues: [ring(2)])
    func transfer(
      _ channel: ByteChannel, _ memory: QueueMemory, _ port: DeviceTransport, _ message: [UInt8]
    ) throws {
      let at = memory.used + 8192
      let n: UInt32 = channel.deviceWrites ? 64 : UInt32(message.count)
      var stream = ByteStreamQueue(channel: channel, count: Int(memory.count))!
      _ = q.send("memset \(at) 65 0xcd")
      if !channel.deviceWrites {
        _ = q.send("write \(at) \(n) 0x" + message.map { String(format: "%02x", $0) }.joined())
      }
      try q.require(
        stream.submit(
          iova: at, length: n,
          descriptor: { i, addr, length, flags, next in
            let p = memory.descriptors + UInt64(i) * 16
            q.write("q", p, addr)
            q.write("l", p + 8, length)
            q.write("w", p + 12, flags)
            q.write("w", p + 14, next)
          }, available: { i, head in q.write("w", memory.available + 4 + UInt64(i) * 2, head) },
          publish: { q.write("w", memory.available + 2, $0) }), "stream submit failed")
      port.notify(channel.index)
      if channel == .consoleReceive { try input.write(contentsOf: Data(message)) }
      let end = ContinuousClock.now + .seconds(3)
      while q.read("w", memory.used + 2) == 0 && q.error == nil && .now < end {
        _ = q.send("clock_step 1000000")
        usleep(500)
      }
      stream.poll(
        acquire: { UInt16(q.read("w", memory.used + 2)) },
        head: { UInt32(q.read("l", memory.used + 4 + UInt64($0) * 8)) },
        written: { UInt32(q.read("l", memory.used + 8 + UInt64($0) * 8)) })
      let expected: ByteDelivery =
        channel == .entropy
        ? .uncreditedRandom(UInt32(message.count))
        : channel == .consoleReceive ? .consoleInput(UInt32(message.count)) : .consoleSent(n)
      try q.require(stream.release { true } == expected, "missing or wrong \(channel) completion")
      if channel.deviceWrites {
        let b = (0...64).map { UInt8(q.read("b", at + UInt64($0))) }
        try q.require(
          b == message + Array(repeating: UInt8(0xcd), count: 65 - message.count),
          "input length or guard mismatch")
      } else {
        var fd = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var bytes = [UInt8](repeating: 0, count: message.count + 1)
        guard Darwin.poll(&fd, 1, 2000) > 0,
          bytes.withUnsafeMutableBytes({ Darwin.read(fd.fd, $0.baseAddress, $0.count) })
            == message.count,
          bytes.prefix(message.count).elementsEqual(message)
        else { throw Failure("console backend did not receive exact bytes") }
      }
      port.acknowledge()
    }
    try transfer(.consoleTransmit, ring(1), serial, [0x78, 0x00, 0x0a, 0x7f])
    try transfer(.consoleReceive, ring(0), serial, [0x00, 0xff, 0x20, 0x0a, 0x19])
    try transfer(.entropy, ring(2), rng, Array(sample.prefix(13)))
  }
}
