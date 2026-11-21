import Darwin
import Foundation
import VirtioGuest

// Independent of the guest DMA backing and control response: ask the QEMU
// display backend for its scanout over an isolated local monitor pipe.
private func checkScanout(_ dir: URL, _ input: FileHandle, _ output: FileHandle, _ rgb: [UInt8])
  throws
{
  func receive(_ key: String) throws {
    let end = ContinuousClock.now + .seconds(3)
    var bytes: [UInt8] = []
    while .now < end && bytes.count < 16384 {
      var p = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
      guard poll(&p, 1, 500) >= 0 else { throw Failure("QMP read failed") }
      var byte: UInt8 = 0
      if Darwin.read(p.fd, &byte, 1) != 1 { continue }
      if byte != 10 {
        bytes.append(byte)
        continue
      }
      guard let msg = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
        msg["error"] == nil
      else { throw Failure("QMP refused scanout capture") }
      if msg[key] != nil { return }
      bytes.removeAll()
    }
    throw Failure("Missing QMP " + key)
  }
  func send(_ cmd: String, _ args: [String: Any]) throws {
    var msg = try JSONSerialization.data(withJSONObject: ["execute": cmd, "arguments": args])
    msg.append(10)
    try input.write(contentsOf: msg)
    try receive("return")
  }
  try receive("QMP")
  try send("qmp_capabilities", [:])
  let ppm = dir.appendingPathComponent("scanout.ppm")
  try send("screendump", ["filename": ppm.path, "format": "ppm"])
  var expected = Data("P6\n64 48\n255\n".utf8)
  expected.append(contentsOf: rgb)
  guard try Data(contentsOf: ppm) == expected else { throw Failure("Scanout pixels differ") }
}

func testGPU(binary: String, disk: URL, machine: Machine) throws {
  try withPipePair { dir, monitor, input, output in
    let model = machine == .x64 ? "virtio-gpu-pci,disable-legacy=on,addr=07.0" : "virtio-gpu-device"
    let q = try QTest(
      binary: binary, machine: machine, disk: disk, translated: false,
      neighbors: false,
      extraDevices: [
        "-device", model + ",id=screen,iommu_platform=on",
        "-chardev", "pipe,id=gpucontrol,path=" + monitor, "-object",
        "monitor-qmp,id=gpuqmp,chardev=gpucontrol",
      ])
    defer { q.close() }
    let p = machine.ram + 0x800000
    let ring = QueueMemory(count: 8, descriptors: p, available: p + 4096, used: p + 8192)
    let port = try transport(q, machine, type: 16, supported: 0, queues: [ring])
    let cmd = p + 16384
    let reply = cmd + 4096
    let framebuffer = cmd + 8192
    var resource = GPU2DResource(
      id: 1, scanout: 0, width: 64, height: 48,
      backing: framebuffer, backingBytes: 64 * 48 * 4)!
    var queue = SplitQueue()
    try q.require(queue.initialize(8), "GPU queue capacity")
    var pixels: [UInt8] = []
    var rgb: [UInt8] = []
    for y in UInt8(0)..<48 {
      for x in UInt8(0)..<64 {
        let r = x &* 3
        let g = y &* 5
        let b = x ^ y
        pixels += [b, g, r, 0]
        rgb += [r, g, b]
      }
    }
    func copy(_ bytes: [UInt8], _ to: UInt64) {
      _ = q.send(
        "write \(to) \(bytes.count) 0x" + bytes.map { String(format: "%02x", $0) }.joined())
    }
    copy(pixels, framebuffer)
    for op: GPU2DOp in [
      .display, .create, .attach, .upload, .scanout, .flush, .disable, .detach, .destroy,
    ] {
      guard let req = resource.prepare(op) else { throw Failure("GPU lifecycle order") }
      copy(req.bytes, cmd)
      _ = q.send("memset \(reply) \(req.responseBytes + 1) 0xca")
      let segments = [
        Segment(iova: cmd, length: UInt32(req.bytes.count), deviceWrites: false),
        Segment(iova: reply, length: req.responseBytes, deviceWrites: true),
      ]
      try q.require(
        queue.submit(
          req.fence, segments,
          { i, address, length, flags, next in
            let at = ring.descriptors + UInt64(i * 16)
            q.write("q", at, address)
            q.write("l", at + 8, length)
            q.write("w", at + 12, flags)
            q.write("w", at + 14, next)
          }, { i, head in q.write("w", ring.available + 4 + UInt64(2 * i), head) },
          { q.write("w", ring.available + 2, $0) }), "GPU submit")
      port.notify(0)
      let used = try queueCompleted(q, &queue, ring)
      guard used.cookie == req.fence, used.written == req.responseBytes,
        q.read("b", reply + UInt64(used.written)) == 0xca,
        resource.complete((0..<used.written).map { UInt8(q.read("b", reply + UInt64($0))) })
      else { throw Failure("GPU reply or fence mismatch: \(op)") }
      port.acknowledge()
      if op == .flush { try checkScanout(dir, input, output, rgb) }
    }
    try q.require(resource.retired, "GPU backing released out of order")
  }
}
