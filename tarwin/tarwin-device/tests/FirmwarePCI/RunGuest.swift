import Darwin
import Foundation

struct Failure: Error, CustomStringConvertible { let description: String }

func run(bridged: Bool) throws {
  let args = CommandLine.arguments
  guard args.count == 4 else {
    throw Failure(description: "expected arch, scratch directory and firmware")
  }
  let arch = args[1]
  let dir = args[2]
  let machine =
    arch == "x86_64"
    ? ["-machine", "q35"]
    : (arch == "aarch64"
      ? ["-machine", "virt,gic-version=3", "-cpu", "cortex-a72"] : ["-machine", "virt"])
  let process = Process()
  let input = Pipe()
  let topology = bridged ? "bridged" : "flat"
  let serial = dir + "/console-" + topology + ".log"
  let qmp = dir + "/qmp-" + topology + ".log"
  FileManager.default.createFile(atPath: qmp, contents: nil)
  let log = try FileHandle(forWritingTo: URL(fileURLWithPath: qmp))
  defer { try? log.close() }
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments =
    ["qemu-system-" + arch] + machine + [
      "-m", "512", "-smp", "1", "-display", "none",
      "-serial", "file:" + serial, "-monitor", "none", "-qmp", "stdio", "-nic", "none",
      "-drive", "if=pflash,format=raw,readonly=on,file=" + args[3],
      "-drive", "if=pflash,format=raw,file=" + dir + "/vars.fd",
      "-drive", "if=none,id=esp,format=raw,readonly=on,file=fat:" + dir + "/esp",
      "-device", "virtio-blk-pci,drive=esp",
      "-device", "pcie-root-port,id=rp1,chassis=1",
      "-object", "rng-random,id=entropy,filename=/dev/urandom",
      "-device", "virtio-rng-pci,rng=entropy,disable-legacy=on,bus=" + (bridged ? "rp1" : "pcie.0"),
    ]
  process.standardInput = input
  process.standardOutput = log
  try process.run()
  defer {
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
  try input.fileHandleForWriting.write(
    contentsOf: Data("{\"execute\":\"qmp_capabilities\"}\n".utf8))
  let end = ContinuousClock.now.advanced(by: .seconds(60))
  while process.isRunning && ContinuousClock.now < end { Thread.sleep(forTimeInterval: 0.05) }
  let console = (try? Data(contentsOf: URL(fileURLWithPath: serial))) ?? Data()
  let events = try Data(contentsOf: URL(fileURLWithPath: qmp))
  let shutdown = events.split(separator: 10).contains {
    guard let e = (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any],
      e["event"] as? String == "SHUTDOWN", let d = e["data"] as? [String: Any]
    else { return false }
    return d["guest"] as? Bool == true && d["reason"] as? String == "guest-shutdown"
  }
  guard !process.isRunning, process.terminationStatus == 0, shutdown,
    console.range(
      of: Data((bridged ? "TARWIN-PCI-TOPOLOGY-PASS" : "TARWIN-PCI-TOPOLOGY-FAIL").utf8)) != nil
  else {
    throw Failure(
      description: arch + ": diagnostic failed: "
        + String(decoding: console.suffix(2048), as: UTF8.self))
  }
  print(
    arch
      + (bridged ? ": guest found disk and bridged RNG" : ": guest rejected flat RNG topology")
  )
}
do {
  try run(bridged: false)
  try run(bridged: true)
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
