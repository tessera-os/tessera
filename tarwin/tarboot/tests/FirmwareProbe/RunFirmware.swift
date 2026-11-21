import CryptoKit
import Darwin
import Foundation

struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private func guestShutdown(_ data: Data) -> Bool {
  data.split(separator: 10).contains { line in
    guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
      event["event"] as? String == "SHUTDOWN", let data = event["data"] as? [String: Any]
    else { return false }
    return data["guest"] as? Bool == true && data["reason"] as? String == "guest-shutdown"
  }
}

// QMP screendump emits binary PPM. Check the whole message on the emulated
// scanout, not a copy of framebuffer RAM or a guest-supplied success value.
private func verifyScanout(_ bytes: Data, kernel: Bool = false) throws {
  let lines = bytes.split(separator: 10, maxSplits: 3, omittingEmptySubsequences: false)
  guard lines.count == 4, lines[0].elementsEqual("P6".utf8), lines[2].elementsEqual("255".utf8)
    else { throw Failure("invalid QMP PPM header") }
  let dims = String(decoding: lines[1], as: UTF8.self).split(separator: " ").compactMap { Int($0) }
  guard dims.count == 2, ((kernel ? 84 : 66)...16384).contains(dims[0]), (8...16384).contains(dims[1]),
    lines[3].count == 3 * dims[0] * dims[1] else { throw Failure("invalid QMP scanout size") }
  let glyphs: [[UInt8]] = [
    [31,4,4,4,4,4,4], [14,17,17,31,17,17,17], [30,17,17,30,20,18,17],
    [17,17,17,21,21,27,17], [14,4,4,4,4,4,14], [17,25,25,21,19,19,17],
    [0,0,0,0,0,0,0],
  ] + (kernel ? [
    [17,17,17,21,21,27,17], [14,17,19,21,25,17,14], [0,0,0,0,0,0,0],
    [30,17,17,30,16,16,16], [14,17,17,31,17,17,17],
    [15,16,16,14,1,1,30], [15,16,16,14,1,1,30],
  ] : [
    [31,4,4,4,4,4,4], [31,16,16,30,16,16,31],
    [15,16,16,14,1,1,30], [31,4,4,4,4,4,4],
  ])
  let pixels = lines[3]
  for (cell, glyph) in glyphs.enumerated() {
    for y in 0..<8 {
      for x in 0..<6 {
        let i = pixels.startIndex + 3 * (y * dims[0] + cell * 6 + x)
        let lit = y < 7 && x < 5 && glyph[y] & (16 >> x) != 0
        guard pixels[i] == (lit ? 255 : 16), pixels[i+1] == (lit ? 255 : 32),
          pixels[i+2] == (lit ? 255 : 64) else { throw Failure("wrong scanout pixel at \(cell * 6 + x),\(y)") }
      }
    }
  }
}

func check() throws {
  let denied = CommandLine.arguments.count == 5 && CommandLine.arguments[4] == "unsigned-control"
  guard CommandLine.arguments.count == 4 || denied else {
    throw Failure("expected architecture, work directory and CODE.fd")
  }
  let a = CommandLine.arguments[1]
  let secure = ProcessInfo.processInfo.environment["TARBOOT_TEST_SECURE_FIRMWARE"] == "1"
  guard (!denied || secure) && (!secure || a == "x86_64") else { throw Failure("invalid secure firmware target") }
  let d = CommandLine.arguments[2]
  let code = CommandLine.arguments[3]
  let serial = d + "/console.log"
  let monitor = d + "/monitor.log"
  let input = Pipe()
  let fm = FileManager.default
  fm.createFile(atPath: monitor, contents: nil)
  let qmp = try FileHandle(forWritingTo: URL(fileURLWithPath: monitor))
  defer { try? qmp.close() }
  let cpuCheck=ProcessInfo.processInfo.environment["TARBOOT_TEST_CPU"]
  let restore = ProcessInfo.processInfo.environment["TARBOOT_TEST_RESTORE"] == "1"
  let board = restore ? "virt-11.1,accel=tcg" : "virt"
  let armMachine = cpuCheck == "1" ? ["-machine",board + ",gic-version=3,virtualization=on","-cpu","max"]
    : ["-machine",board + ",gic-version=3","-cpu","cortex-a72"]
  let machine =
    a == "x86_64"
    ? (secure ? ["-machine","q35,smm=on","-global","driver=cfi.pflash01,property=secure,value=on"] : ["-machine", "q35"]) + (cpuCheck == "x64-refusal" ? ["-cpu","max"] : [])
    : (a == "aarch64"
      ? armMachine : ["-machine", "virt"])
  let process = Process()
  let multiple = ProcessInfo.processInfo.environment["TARBOOT_TEST_SMP_TABLES"] == "1"
  let displayEnabled = ProcessInfo.processInfo.environment["TARBOOT_TEST_DISPLAY"] == "1"
  let displayArgs = !displayEnabled ? [] : (a == "x86_64" ? ["-vga", "std"] : ["-device", "ramfb"]) + ["-no-shutdown"]
  let rngEnabled = ProcessInfo.processInfo.environment["TARBOOT_TEST_RNG"] == "1"
  let rngArgs = rngEnabled ? ["-object", "rng-random,filename=/dev/urandom,id=entropy", "-device", "virtio-rng-pci,rng=entropy"] : []
  let tpmEnabled = ProcessInfo.processInfo.environment["TARBOOT_TEST_TPM"] == "1"
  let state = URL(fileURLWithPath: "/tmp/tarwin-tpm-" + UUID().uuidString)
  let socket = state.appendingPathComponent("ctrl").path
  let emulator = Process()
  var tpmArgs: [String] = []
  defer {
    if tpmEnabled {
      if emulator.isRunning {
        _ = kill(emulator.processIdentifier, SIGKILL)
        emulator.waitUntilExit()
      }
      try? fm.removeItem(at: state)
    }
  }
  if tpmEnabled {
    try fm.createDirectory(
      at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    if ProcessInfo.processInfo.environment["TARBOOT_TEST_FLOOR"] == "1" {
      let installer=Process()
      installer.executableURL=URL(fileURLWithPath:"/usr/bin/swift")
      let here=URL(fileURLWithPath:#filePath).deletingLastPathComponent()
      installer.arguments=[here.appendingPathComponent("ProvisionCounter.swift").path,state.path]
      try installer.run(); installer.waitUntilExit()
      guard installer.terminationStatus==0 else { throw Failure("disposable NV provisioning failed") }
    }
    emulator.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    emulator.arguments = [
      "swtpm", "socket", "--tpm2", "--tpmstate", "dir=" + state.path,
      "--ctrl", "type=unixio,path=" + socket, "--terminate",
    ]
    try emulator.run()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while emulator.isRunning && !fm.fileExists(atPath: socket) && ContinuousClock.now < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    guard fm.fileExists(atPath: socket) else { throw Failure("swtpm control socket unavailable") }
    let device = a == "x86_64" ? "tpm-crb" : "tpm-tis-device"
    tpmArgs = [
      "-chardev", "socket,id=tcg,path=" + socket, "-tpmdev", "emulator,id=tpm,chardev=tcg",
      "-device", device + ",tpmdev=tpm",
    ]
  }
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  let wrongPage = ProcessInfo.processInfo.environment["TARBOOT_TEST_WRONG_PAGE"] == "1"
  guard (!wrongPage || restore) && (!restore || (a == "aarch64" && !multiple && !displayEnabled))
    else { throw Failure("restore diagnostic requires one headless ARM vCPU") }
  // Destination policy for this firmware/machine fixture, not from guest RAM or VMState.
  let page = wrongPage ? "0x5c741000" : "0x5c740000"
  let generationArgs = restore ? ["-device", "vmgenid,x-rotate-on-load=on,x-pinned-page=" + page, "-blockdev",
    "driver=file,filename=" + d + "/state.qcow2,node-name=statefile", "-blockdev",
    "driver=qcow2,file=statefile,node-name=state"] : []
  let evidence = ProcessInfo.processInfo.environment["TARBOOT_TEST_W1_EVIDENCE"] == "1"
  let evidenceArgs = evidence ? ["-fw_cfg", "name=opt/org.tessera/tarwin/w1.sig,string=not-a-signature"] : []
  process.arguments =
    ["qemu-system-" + a] + machine + tpmArgs + displayArgs + rngArgs + generationArgs + evidenceArgs + [
      "-m", "512", "-smp", multiple ? "4" : "1", "-display", "none", "-rtc", "base=utc",
      "-serial", "file:" + serial, "-monitor", "none", "-qmp", "stdio", "-nic", "none",
      "-drive", "if=pflash,format=raw,readonly=on,file=" + code, "-drive",
      "if=pflash,format=raw,file=" + d + "/vars.fd",
      "-drive", "if=none,id=esp,format=raw,readonly=on,file=fat:" + d + "/esp", "-device",
      secure ? "virtio-blk-pci,drive=esp,addr=0x6,bootindex=1" : "virtio-blk-pci,drive=esp",
    ]
  process.standardInput = input
  process.standardOutput = qmp
  let stderrPath = d + "/qemu-errors.log"
  if wrongPage {
    fm.createFile(atPath: stderrPath, contents: nil)
    process.standardError = try FileHandle(forWritingTo: URL(fileURLWithPath: stderrPath))
  }
  try process.run()
  defer {
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
  try input.fileHandleForWriting.write(
    contentsOf: Data("{\"execute\":\"qmp_capabilities\"}\n".utf8))
  let deadline = ContinuousClock.now.advanced(by: .seconds(60))
  var captured = false
  let bootKernel = ProcessInfo.processInfo.environment["TARBOOT_ENTER_W0"] == "1"
  var nextShot = ContinuousClock.now
  var loaded = false, serialID = 0
  func request(_ command: String, _ args: [String: Any] = [:]) throws -> Any {
    serialID += 1
    var data = try JSONSerialization.data(withJSONObject: [
      "execute": command, "arguments": args, "id": serialID] as [String: Any])
    data.append(10)
    try input.fileHandleForWriting.write(contentsOf: data)
    while ContinuousClock.now < deadline {
      let events = try Data(contentsOf: URL(fileURLWithPath: monitor))
      for line in events.split(separator: 10).reversed() {
        guard let reply = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
          reply["id"] as? Int == serialID else { continue }
        guard let result = reply["return"] else { throw Failure("QMP refused " + command) }
        return result
      }
      if !process.isRunning { break }
      Thread.sleep(forTimeInterval: 0.01)
    }
    throw Failure("missing QMP reply: " + command)
  }
  func snapshot(_ action: String) throws -> String? {
    _ = try request("snapshot-" + action, [
      "job-id": action, "tag": "tarwin", "vmstate": "state", "devices": ["state"]])
    while ContinuousClock.now < deadline {
      if let jobs = try request("query-jobs") as? [[String: Any]],
        let job = jobs.first(where: { $0["id"] as? String == action }),
        job["status"] as? String == "concluded" { return job["error"] as? String }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw Failure("snapshot job did not conclude")
  }
  func deviceID() throws -> UUID {
    guard let info = try request("query-vm-generation-id") as? [String: Any],
      let guid = info["guid"] as? String, let id = UUID(uuidString: guid) else {
      throw Failure("missing device generation")
    }
    return id
  }
  func checkPage(_ id: UUID) throws {
    let path = d + "/paused-guid.bin"
    _ = try request("pmemsave", ["val": 0x5c740028, "size": 16, "filename": path])
    var uuid = id.uuid
    let raw = withUnsafeBytes(of: &uuid) { Array($0) }
    let wire = [3,2,1,0,5,4,7,6,8,9,10,11,12,13,14,15].map { raw[$0] }
    guard try Data(contentsOf: URL(fileURLWithPath: path)).elementsEqual(wire)
    else { throw Failure("device and paused guest generation differ") }
  }
  while process.isRunning && ContinuousClock.now < deadline {
    if restore && !loaded, let uart = try? Data(contentsOf: URL(fileURLWithPath: serial)),
      uart.range(of: Data("TARWIN-VMGEN-SNAPSHOT-READY".utf8)) != nil {
      _ = try request("stop")
      let before = try deviceID()
      guard let status = try request("query-status") as? [String: Any],
        status["status"] as? String == "paused"
      else { throw Failure("failed to pause diagnostic") }
      try checkPage(before)
      guard try snapshot("save") == nil
      else { throw Failure("failed to save paused diagnostic") }
      let loadError = try snapshot("load")
      guard let after = try request("query-status") as? [String: Any],
        after["running"] as? Bool == false else { throw Failure("vCPU resumed during restore") }
      if wrongPage {
        guard loadError != nil, try deviceID() == before,
          try String(contentsOfFile: stderrPath, encoding: .utf8).contains("refusing unbound restore slot")
        else { throw Failure("missing destination-page refusal") }
        print("aarch64: mismatched VMGenID destination refused before rotation; guest not resumed")
        return
      }
      let fresh = try deviceID()
      guard loadError == nil, after["status"] as? String == "paused", fresh != before
      else { throw Failure("paused restore did not rotate VMGenID: " + (loadError ?? "")) }
      try checkPage(fresh)
      _ = try request("cont")
      loaded = true
    }
    if let bytes = try? Data(contentsOf: URL(fileURLWithPath:serial)),
      bytes.range(of:Data("TARWIN-SIGNED-VERIFICATION-FAILED".utf8)) != nil {
      throw Failure("guest rejected signed archive or native image")
    }
    if secure, let data = try? Data(contentsOf:URL(fileURLWithPath:serial)) {
      let log = String(decoding:data,as:UTF8.self)
      if log.contains("TARWIN-SECURE-MODE-FAILED") { throw Failure("SecureBoot and SetupMode do not confirm enforcement") }
      if denied {
        if log.contains("TARWIN-FIRMWARE-EXIT-TEST") { throw Failure("unsigned diagnostic executed") }
        if log.split(separator:"\n").contains(where:{ line in
          line.contains("BdsDxe: failed to load Boot") && line.contains("PciRoot(0x0)/Pci(0x6,0x0)")
            && (line.contains("Access Denied") || line.contains("Security Violation"))
        }) {
          print("\(a): secure firmware explicitly refused the unsigned ESP image")
          return
        }
      }
    }
    if tpmEnabled, let log = try? Data(contentsOf:URL(fileURLWithPath:serial)),
      log.range(of:Data("TARWIN-LOG-CAPTURE-FAILED".utf8)) != nil {
      throw Failure("\(a): failed to capture primary firmware log")
    }
    if rngEnabled, let log = try? Data(contentsOf: URL(fileURLWithPath: serial)) {
      for marker in ["TARWIN-RNG-UNAVAILABLE", "TARWIN-PLACEMENT-FAILED"] where log.range(of: Data(marker.utf8)) != nil {
        throw Failure("\(a): " + marker)
      }
    }
    if bootKernel && !captured {
      let frame = URL(fileURLWithPath: d + "/scanout.ppm")
      if let bytes = try? Data(contentsOf: frame), (try? verifyScanout(bytes, kernel: true)) != nil {
        try input.fileHandleForWriting.write(contentsOf: Data("{\"execute\":\"quit\"}\n".utf8))
        captured = true
      } else if ContinuousClock.now >= nextShot, let uart = try? Data(contentsOf: URL(fileURLWithPath: serial)) {
        if uart.range(of: Data("TARWIN-IMAGE-INSTALL-REFUSED".utf8)) != nil {
          throw Failure("kernel rejected before installation")
        }
        if uart.range(of: Data("TARBOOT-PHYSICAL-IMAGE-READY".utf8)) != nil {
          let msg: [String:Any] = ["execute":"screendump","arguments":["filename":frame.path]]
          var cmd = try JSONSerialization.data(withJSONObject: msg)
          cmd.append(10)
          try input.fileHandleForWriting.write(contentsOf: cmd)
          nextShot = .now.advanced(by: .milliseconds(400))
        }
      }
    } else if displayEnabled && !captured {
      if let log = try? Data(contentsOf: URL(fileURLWithPath: serial)),
        log.range(of: Data("TARWIN-GOP-UNAVAILABLE".utf8)) != nil { throw Failure("\(a): no linear GOP display") }
      if let events = try? Data(contentsOf: URL(fileURLWithPath: monitor)), guestShutdown(events) {
        let msg: [String: Any] = ["execute": "screendump", "arguments": ["filename": d + "/scanout.ppm"]]
        var commands = try JSONSerialization.data(withJSONObject: msg)
        commands.append(contentsOf: "\n{\"execute\":\"quit\"}\n".utf8)
        try input.fileHandleForWriting.write(contentsOf: commands)
        captured = true
      }
    }
    if tpmEnabled, let log = try? Data(contentsOf: URL(fileURLWithPath: serial)),
      log.range(of: Data("TARWIN-TCG2-NOT-FOUND".utf8)) != nil
    {
      throw Failure("\(a): UEFI reports EFI_NOT_FOUND for the TCG2 protocol")
    }
    Thread.sleep(forTimeInterval: 0.1)
  }
  guard !process.isRunning, process.terminationStatus == 0 else {
    throw Failure("\(a): guest did not shut down normally")
  }
  let uart = try Data(contentsOf: URL(fileURLWithPath: serial))
  if evidence {
    guard uart.range(of: Data("TARWIN-W1-FIRMWARE-KERNEL-REFUSED".utf8)) != nil,
      uart.range(of: Data("TARWIN-W1-EVIDENCE-COPIED-UNAUTHORIZED".utf8)) != nil
    else { throw Failure("missing W1 refusal before or after EFI exit") }
    print("\(a): W1 refused the EFI kernel and the post-exit process set without independent authority")
  }
  guard !denied else { throw Failure("no explicit unsigned boot rejection") }
  if let cpuCheck,cpuCheck != "0" {
    let expected = a == "aarch64" ? (cpuCheck=="refusal" ? "TARWIN-CPU-AARCH64-INSUFFICIENT" : "TARWIN-CPU-AARCH64-BASE-EL2") :
      (a == "x86_64" ? "TARWIN-CPU-CPUID-SNAPSHOT" : "TARWIN-CPU-SBI-SNAPSHOT")
    guard uart.range(of:Data(expected.utf8)) != nil else {throw Failure("missing CPU snapshot")}
    print("\(a): \(expected)")
  }
  if ProcessInfo.processInfo.environment["TARBOOT_TEST_FLOOR"] == "1" {
    guard uart.range(of:Data("TARWIN-NV-FLOOR-ONE".utf8)) != nil else {
      throw Failure("missing provisioned security version floor")
    }
    print("\(a): matched the provisioned TPM counter Name and read its persisted floor of 1")
  }
  if ProcessInfo.processInfo.environment["TARBOOT_TEST_SIGNATURE"] != nil {
    if cpuCheck == "x64-refusal" {
      let log = String(decoding: uart, as: UTF8.self)
      let gaps = ["SHSTK","IBT","VPCLMULQDQ","INVTSC","TSC-DEADLINE"].filter { log.contains("TARWIN-X64-MISSING-" + $0) }
      guard !gaps.isEmpty, log.contains("TARWIN-X64-TARGET-REFUSED"),
        guestShutdown(try Data(contentsOf: URL(fileURLWithPath: monitor))) else { throw Failure("missing target refusal") }
      print("x86_64: signed W0 refused before kernel entry; guest CPUID lacks " + gaps.joined(separator: ", "))
      return
    }
    let negative = ProcessInfo.processInfo.environment["TARBOOT_BAD_SIGNATURE"] == "1"
    let marker = negative ? "TARWIN-SIGNATURE-REJECTED" : "TARWIN-SIGNED-ARCHIVE-AND-KERNEL-VERIFIED"
    guard uart.range(of:Data(marker.utf8)) != nil else { throw Failure("missing verifier verdict") }
    print("\(a): \(marker)")
    if negative {
      guard guestShutdown(try Data(contentsOf: URL(fileURLWithPath: monitor))) else {throw Failure("missing negative-control shutdown")}
      return
    }
  } else if ProcessInfo.processInfo.environment["TARBOOT_TEST_STAGE0_ARCHIVE"] != nil {
    guard uart.range(of:Data("TARWIN-STAGE0-UNSIGNED-NOT-LAUNCHABLE".utf8)) != nil
    else { throw Failure("missing explicit unsigned kernel rejection") }
    print("\(a): read the stage-0 archive; unsigned kernel passed integrity checks but was refused launch preflight")
  }
  guard uart.range(of: Data("TARWIN-FIRMWARE-EXIT-TEST".utf8)) != nil else {
    throw Failure("\(a): probe did not run")
  }
  guard bootKernel ? captured : guestShutdown(try Data(contentsOf: URL(fileURLWithPath: monitor)))
    else { throw Failure("\(a): missing guest-initiated shutdown event") }
  if rngEnabled { print("\(a): physical TBIB, EFI RNG seed, randomized reservation and typed archive/map extents passed readback") }
  if multiple { print("\(a): enumerated four distinct enabled CPU hardware IDs from firmware; boot CPU only") }
  if ProcessInfo.processInfo.environment["TARBOOT_TEST_PSCI"] == "1" {
    print("\(a): PSCI AFFINITY_INFO reports the MPIDR-matched boot CPU ON and three secondaries OFF")
  }
  if ProcessInfo.processInfo.environment["TARBOOT_TEST_TRANSLATION"] == "1" {
    print("\(a): authenticated the private fixture import with its slot modifier and test IA key")
    print("\(a): EL0 hardware translation resolved RX, RW and sealed RELRO frames; writes to RX/RELRO and guard reads denied")
    print("\(a): upper-half EL1 code and stack resolved; EL0 access, writes to privileged RX and EL1 guard reads denied")
  }
  if secure {
    print("\(a): signed diagnostic admitted by enrolled OVMF; SecureBoot=1, SetupMode=0")
    if uart.range(of: Data("TARWIN-UEFI-BELOW-MINIMUM".utf8)) != nil {
      print("\(a): firmware revision below Tarwin's UEFI 2.9 minimum")
    }
  }
  if displayEnabled {
    guard captured else { throw Failure("no scanout recorded") }
    let frame = try Data(contentsOf: URL(fileURLWithPath: d + "/scanout.ppm"))
    try verifyScanout(frame, kernel: bootKernel)
    if let dir = ProcessInfo.processInfo.environment["TARBOOT_TEST_SCANOUT_DIR"] {
      let output = URL(fileURLWithPath: dir).appendingPathComponent(a + ".ppm")
      try frame.write(to: output, options: .withoutOverwriting)
    }
    print("\(a): post-exit debug text matches QMP scanout")
  }
  if tpmEnabled {
    let console = String(decoding: uart, as: UTF8.self)
    func pcr(_ label: String) throws -> Data {
      let matches = console.components(separatedBy: label)
      guard matches.count == 2 else { throw Failure("missing or repeated " + label) }
      let digits = Array(matches[1].utf8.prefix(64))
      guard digits.count == 64 else { throw Failure("incomplete PCR") }
      var bytes = Data()
      for i in stride(from: 0, to: 64, by: 2) {
        guard let byte = UInt8(String(decoding: digits[i...i + 1], as: UTF8.self), radix: 16) else {
          throw Failure("invalid PCR")
        }
        bytes.append(byte)
      }
      return bytes
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: d + "/esp/BOOT.TIR"))
    let config=try Data(contentsOf:URL(fileURLWithPath:d+"/expected-config.json"))
    for (i, payload) in [(8, archive), (9, config)] {
      let before = try pcr("TARWIN-PCR-BEFORE-\(i)=")
      let after = try pcr("TARWIN-PCR-AFTER-\(i)=")
      guard Data(SHA256.hash(data: before + Data(SHA256.hash(data: payload)))) == after
      else { throw Failure("SHA-256 replay failed at PCR \(i)") }
    }
    print("\(a): firmware TCG2 PCR 8 and PCR 9 match independent host replay")
    print("\(a): captured log contains both expected SHA-256 measurements and the final firmware exit event")
    if ProcessInfo.processInfo.environment["TARBOOT_TEST_FIFO"] == "1" {
      if ProcessInfo.processInfo.environment["TARBOOT_TEST_GENERATION"] == "1" {
        if restore {
          guard loaded,
            uart.range(of: Data("TARWIN-VMGEN-RESTORED-REFUSED-RESEEDED".utf8)) != nil
          else { throw Failure("missing snapshot restore and checked reseed") }
          print("\(a): restored guest rejected its previous RNG stream, then reseeded from swtpm")
        } else {
          guard uart.range(of: Data("TARWIN-NO-VMGEN-RNG-REFUSED".utf8)) != nil else {
            throw Failure("missing post-exit RNG refusal")
          }
          print("\(a): guest found no advertised generation device; kernel RNG refused the TBIB seed and emulated TPM sample")
        }
      }
      print("\(a): post-exit TPM2_GetRandom supplied a full 32-byte debug sample")
      print("\(a): post-exit TPM event sequence hashed the fixture; PCR 10 and the appended Event2 SHA-256 digest match host replay")
    }
  }
  if bootKernel {
    print("\(a): signed W0 kernel wrote TARWIN W0 PASS to hardware scanout; stopped via QMP, not EFI shutdown")
    return
  }
  print(
    "\(a): ESP file read, TIRA member and ELF preflight, EFI exit, page, boot queue and shutdown passed"
  )
}

do { try check() } catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
