import CryptoKit
import Darwin
import Foundation

// Host side: builds the one-sector images, boots the EFI probe under QEMU
// with a read-only virtio-blk test drive behind a PCIe root port, and checks
// the guest verdict against QEMU's own virtio-blk trace and the host digest.
struct Failure: Error, CustomStringConvertible { let description: String }

func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }

func image(corrupt: Bool) -> (Data, String) {
  var payload = [UInt8](repeating: 0, count: 448)
  var rng = SystemRandomNumberGenerator()
  for i in payload.indices { payload[i] = rng.next() }
  var sector = [UInt8](repeating: 0, count: 512)
  sector.replaceSubrange(0..<8, with: Array("TARWINGC".utf8))
  sector.replaceSubrange(8..<12, with: [192, 1, 0, 0])
  sector.replaceSubrange(32..<64, with: Array(SHA256.hash(data: payload)))
  if corrupt { payload[200] ^= 0x01 }
  sector.replaceSubrange(64..<512, with: payload)
  return (Data(sector), hex(SHA256.hash(data: payload)))
}

func field(_ line: Substring, _ name: String) -> String? {
  guard let r = line.range(of: name + " ") else { return nil }
  return String(line[r.upperBound...].prefix { !$0.isWhitespace && $0 != "," })
}

func run(_ arch: String, _ dir: String, _ code: String, corrupt: Bool) throws {
  let name = corrupt ? "wrong-payload" : "positive"
  let (bytes, payloadDigest) = image(corrupt: corrupt)
  let disk = dir + "/" + name + ".img"
  try bytes.write(to: URL(fileURLWithPath: disk))
  let machine =
    arch == "x86_64"
    ? ["-machine", "q35"]
    : (arch == "aarch64"
      ? ["-machine", "virt,gic-version=3", "-cpu", "cortex-a72"] : ["-machine", "virt"])
  let serial = dir + "/console-" + name + ".log"
  let qmp = dir + "/qmp-" + name + ".log"
  let trace = dir + "/trace-" + name + ".log"
  let vars = dir + "/vars-" + name + ".fd"
  for f in [serial, qmp, trace, vars] { try? FileManager.default.removeItem(atPath: f) }
  FileManager.default.createFile(atPath: qmp, contents: nil)
  let log = try FileHandle(forWritingTo: URL(fileURLWithPath: qmp))
  defer { try? log.close() }
  try FileManager.default.copyItem(atPath: dir + "/vars.fd", toPath: vars)
  let process = Process()
  let input = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  let arguments =
    ["qemu-system-" + arch] + machine + [
      "-accel", "tcg", "-m", "512", "-smp", "1", "-display", "none",
      "-serial", "file:" + serial, "-monitor", "none", "-qmp", "stdio", "-nic", "none",
      "-drive", "if=pflash,format=raw,readonly=on,file=" + code,
      "-drive", "if=pflash,format=raw,file=" + vars,
      "-drive", "if=none,id=esp,format=raw,readonly=on,file=fat:" + dir + "/esp",
      "-device", "virtio-blk-pci,drive=esp",
      "-device", "pcie-root-port,id=rp1,chassis=1",
      "-drive", "if=none,id=gc,format=raw,readonly=on,file=" + disk,
      "-device", "virtio-blk-pci,id=gcdisk,drive=gc,bus=rp1,disable-legacy=on,iommu_platform=on",
      "-trace", "enable=virtio_blk_handle_read", "-trace", "enable=virtio_blk_rw_complete",
      "-trace", "enable=virtio_set_status", "-D", trace,
    ]
  let devices = arguments.indices.dropLast().filter { arguments[$0] == "-device" }
    .map { arguments[$0 + 1].prefix { $0 != "," } }
  guard devices.allSatisfy({ $0 == "virtio-blk-pci" || $0 == "pcie-root-port" }),
    !arguments.contains(where: { $0.contains("vfio") || $0.contains("hvf") || $0.contains("kvm") })
  else { throw Failure(description: "\(arch): only emulated QEMU devices under TCG are allowed") }
  process.arguments = arguments
  process.standardInput = input
  process.standardOutput = log
  try process.run()
  defer {
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
  try input.fileHandleForWriting.write(
    contentsOf: Data("{\"execute\":\"qmp_capabilities\"}\n".utf8))
  let end = ContinuousClock.now.advanced(by: .seconds(180))
  while process.isRunning && ContinuousClock.now < end { Thread.sleep(forTimeInterval: 0.05) }
  let console = String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: serial))) ?? Data(), as: UTF8.self)
  let events = try Data(contentsOf: URL(fileURLWithPath: qmp))
  let shutdown = events.split(separator: 10).contains {
    guard let e = (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any],
      e["event"] as? String == "SHUTDOWN", let d = e["data"] as? [String: Any]
    else { return false }
    return d["guest"] as? Bool == true && d["reason"] as? String == "guest-shutdown"
  }
  let fail = { (why: String) in
    Failure(description: "\(arch) \(name): \(why)\n" + String(console.suffix(1500)))
  }
  guard !process.isRunning, shutdown else { throw fail("no guest-shutdown") }
  guard try Data(contentsOf: URL(fileURLWithPath: disk)) == bytes else {
    throw fail("test image changed")
  }
  let lines = console.split(whereSeparator: \.isNewline)
  let verdict = corrupt ? "TARWIN-GC-PAYLOAD-MISMATCH" : "TARWIN-GC-PASS"
  guard lines.contains(where: { $0 == verdict }),
    lines.contains(where: { $0.hasPrefix("TARWIN-GC post-exit: ExitBootServices ok") }),
    lines.contains(where: { $0 == "TARWIN-GC sha256=" + payloadDigest })
  else { throw fail("expected \(verdict) and guest digest \(payloadDigest)") }

  // The test drive is the device whose reads end the trace. After its last
  // DRIVER_OK (status 15) QEMU must see exactly one read of sector 0, one
  // sector long, completed successfully, then the probe's reset (status 0).
  let t = try String(contentsOfFile: trace, encoding: .utf8).split(whereSeparator: \.isNewline)
  guard let last = t.last(where: { $0.contains("virtio_blk_handle_read") }),
    let vdev = field(last, "vdev"),
    let ready = t.lastIndex(where: {
      $0.contains("virtio_set_status") && field($0, "vdev") == vdev && field($0, "val") == "15"
    })
  else { throw fail("trace has no test-drive reads") }
  let after = t[(ready + 1)...].filter { field($0, "vdev") == vdev }
  let reads = after.filter { $0.contains("virtio_blk_handle_read") }
  let completes = after.filter { $0.contains("virtio_blk_rw_complete") }
  let early = t[..<ready].filter {
    $0.contains("virtio_blk_handle_read") && field($0, "vdev") == vdev
  }.count
  guard reads.count == 1, field(reads[0], "sector") == "0", field(reads[0], "nsectors") == "1",
    completes.count == 1, field(completes[0], "ret") == "0",
    after.last.map({ $0.contains("virtio_set_status") && field($0, "val") == "0" }) == true
  else { throw fail("trace after final DRIVER_OK: " + after.joined(separator: " | ")) }
  print(
    "\(arch) \(name): \(verdict); QEMU trace after the probe's DRIVER_OK: 1 read, sector 0, 1 sector, ret 0, then reset;"
      + " guest digest = host digest \(payloadDigest.prefix(16)); image unchanged;"
      + " firmware reads of the test drive before the probe's DRIVER_OK: \(early)")
}

let args = CommandLine.arguments
guard args.count == 4 else {
  FileHandle.standardError.write(Data("expected arch, scratch directory and firmware\n".utf8))
  exit(2)
}
do {
  try run(args[1], args[2], args[3], corrupt: false)
  try run(args[1], args[2], args[3], corrupt: true)
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
