import CryptoKit
import Darwin
import Foundation

// Host side: builds the one-sector images and the TRFS fixture cases, boots
// the EFI probe under QEMU
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

struct Case {
  let name: String
  let bytes: Data
  let verdict: String
  let digest: String?
  let reads: Int
}

func oneSector(corrupt: Bool) -> Case {
  let (bytes, digest) = image(corrupt: corrupt)
  return Case(
    name: corrupt ? "wrong-payload" : "positive", bytes: bytes,
    verdict: corrupt ? "TARWIN-GC-PAYLOAD-MISMATCH" : "TARWIN-GC-PASS", digest: digest, reads: 1)
}

// Damage flips one byte the way trfs/tests/GuestIO's host check does: page 4
// is system-version's data, page 6 the root record the pin covers. The read
// counts are the ones that host check reports for the same fixture.
func trfs(_ fixture: Data, _ name: String, damage page: Int?, reads: Int) -> Case {
  var bytes = fixture
  if let page { bytes[page * 4096 + 77] ^= 0x01 }
  return Case(
    name: name, bytes: bytes,
    verdict: page == nil ? "TARWIN-GC-TRFS-PASS" : "TARWIN-GC-TRFS-REJECTED", digest: nil,
    reads: reads)
}

func field(_ line: Substring, _ name: String) -> String? {
  guard let r = line.range(of: name + " ") else { return nil }
  return String(line[r.upperBound...].prefix { !$0.isWhitespace && $0 != "," })
}

func run(_ arch: String, _ dir: String, _ code: String, _ c: Case) throws {
  let name = c.name
  let bytes = c.bytes
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
  let verdict = c.verdict
  let requests = "TARWIN-GC post-exit io: requests=" + String(format: "%02x", c.reads)
  guard lines.contains(where: { $0 == verdict }),
    lines.contains(where: { $0.hasPrefix("TARWIN-GC post-exit: ExitBootServices ok") }),
    lines.contains(where: { $0.hasPrefix(requests) }),
    c.digest.map({ d in lines.contains { $0 == "TARWIN-GC sha256=" + d } }) ?? true
  else { throw fail("expected \(verdict), \(c.reads) requests and guest digest \(c.digest ?? "-")") }

  // The test drive is the device whose reads end the trace. After its last
  // DRIVER_OK (status 15) QEMU must see exactly the expected reads (one-sector
  // cases: sector 0, one sector; TRFS: aligned 8-sector pages), each completed
  // successfully, then the probe's reset (status 0).
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
  let span = c.digest == nil ? 8 : 1
  guard reads.count == c.reads, completes.count == c.reads,
    reads.allSatisfy({ r in
      guard let s = field(r, "sector").flatMap({ UInt64($0) }) else { return false }
      return field(r, "nsectors") == String(span)
        && (span == 1 ? s == 0 : s % 8 == 0 && s + 8 <= UInt64(bytes.count / 512))
    }),
    completes.allSatisfy({ field($0, "ret") == "0" }),
    after.last.map({ $0.contains("virtio_set_status") && field($0, "val") == "0" }) == true
  else { throw fail("trace after final DRIVER_OK: " + after.joined(separator: " | ")) }
  let sectors = reads.compactMap { field($0, "sector") }.joined(separator: ",")
  print(
    "\(arch) \(name): \(verdict); QEMU trace after the probe's DRIVER_OK: \(c.reads) read(s) of"
      + " \(span) sector(s) at sector \(sectors), all ret 0, then reset;"
      + (c.digest.map { " guest digest = host digest \($0.prefix(16));" } ?? "")
      + " image unchanged; firmware reads of the test drive before the probe's DRIVER_OK: \(early)")
}

let args = CommandLine.arguments
guard args.count == 4 else {
  FileHandle.standardError.write(Data("expected arch, scratch directory and firmware\n".utf8))
  exit(2)
}
do {
  // The unmodified trfs/tests/fixtures generator writes the fixture next to
  // the per-ISA directories; its root file must name the root record page.
  let base = URL(fileURLWithPath: args[2]).deletingLastPathComponent()
  let fixture = try Data(contentsOf: base.appendingPathComponent("system.trfs"))
  let root = try Data(contentsOf: base.appendingPathComponent("system.trfs.root"))
  guard fixture.count == 1 << 20, root == Data(SHA256.hash(data: fixture[6 * 4096..<7 * 4096]))
  else { throw Failure(description: "TRFS fixture is not the 1 MiB pinned system image") }
  for c in [
    oneSector(corrupt: false), oneSector(corrupt: true),
    trfs(fixture, "trfs-clean", damage: nil, reads: 11),
    trfs(fixture, "trfs-damaged-file", damage: 4, reads: 11),
    trfs(fixture, "trfs-damaged-root", damage: 6, reads: 3),
  ] {
    try run(args[1], args[2], args[3], c)
  }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
