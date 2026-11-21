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
  let mca = ProcessInfo.processInfo.environment["TARBOOT_TEST_MCA"] ?? "0"
  guard ["0", "1", "wide"].contains(mca), mca == "0" || a == "x86_64"
  else { throw Failure("invalid MCA diagnostic target") }
  let mcaLog = d + "/mca.log"
  let gen = ProcessInfo.processInfo.environment["TARBOOT_TEST_Q35_GENID"] ?? "0"
  guard ["0", "present", "absent"].contains(gen), gen == "0" || (a == "x86_64" && mca == "0")
  else { throw Failure("invalid q35 VMGenID diagnostic") }
  let q35ID = UUID()
  let genLog = d + "/genid.log"
  let q35Args = gen == "0" ? [] : ["-debugcon", "file:" + genLog]
    + (gen == "present" ? ["-device", "vmgenid,guid=" + q35ID.uuidString] : [])
  let mcaArgs = mca == "0" ? [] : ["-accel", "tcg", "-cpu", "max,vendor=GenuineIntel", "-debugcon", "file:" + mcaLog]
  let monitor = d + "/monitor.log"
  let input = Pipe()
  let fm = FileManager.default
  fm.createFile(atPath: monitor, contents: nil)
  let qmp = try FileHandle(forWritingTo: URL(fileURLWithPath: monitor))
  defer { try? qmp.close() }
  let cpuCheck=ProcessInfo.processInfo.environment["TARBOOT_TEST_CPU"]
  let restore = ProcessInfo.processInfo.environment["TARBOOT_TEST_RESTORE"] == "1"
  let ro = ProcessInfo.processInfo.environment["TARBOOT_TEST_RO_GENID"] == "1"
  let cold = ProcessInfo.processInfo.environment["TARBOOT_TEST_COLD_FENCE"] == "1"
  let fixed = ProcessInfo.processInfo.environment["TARBOOT_TEST_FIXED_GENID"] == "1"
  let fixedRNG = ProcessInfo.processInfo.environment["TARBOOT_TEST_FIXED_RNG"] == "1"
  let isolatedPCI = ro || cold
  let extraPCI = ProcessInfo.processInfo.environment["TARBOOT_TEST_EXTRA_PCI"] == "1"
  guard !extraPCI || cold else { throw Failure("extra PCI control requires the cold fixture") }
  let highMode = ProcessInfo.processInfo.environment["TARBOOT_TEST_HIGH_PCI"] ?? "0"
  guard ["0", "1", "wrong-window"].contains(highMode) else { throw Failure("unknown PCI layout") }
  let highPCI = highMode != "0", wrongWindow = highMode == "wrong-window"
  guard !highPCI || (cold && !extraPCI) else { throw Failure("invalid high PCI profile") }
  let windows = highPCI && !wrongWindow ? ",highmem-mmio=on,highmem-mmio-size=512G" : (cold ? ",highmem-mmio=off" : "")
  let board = isolatedPCI ? "virt-11.1,accel=tcg,iommu=smmuv3,default-bus-bypass-iommu=off,msi=off" + windows : (restore ? "virt-11.1,accel=tcg" : "virt")
  let armMachine = cpuCheck == "1" || isolatedPCI ? ["-machine",board + ",gic-version=3,virtualization=on","-cpu","max"]
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
  let endpoint = isolatedPCI ? ",iommu_platform=on,disable-legacy=on" : ""
  let rngArgs = rngEnabled ? ["-object", "rng-random,filename=/dev/urandom,id=entropy", "-device", "virtio-rng-pci,rng=entropy" + endpoint + (isolatedPCI ? ",addr=2" : "")] : []
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
  guard !ro || (restore != cold && !wrongPage) else { throw Failure("invalid read-only generation profile") }
  guard (!wrongPage || restore) && (!(restore || cold) || (a == "aarch64" && !multiple && !displayEnabled))
    else { throw Failure("restore diagnostic requires one headless ARM vCPU") }
  // Destination policy for this firmware/machine fixture, not from guest RAM or VMState.
  let page = wrongPage ? "0x5c741000" : "0x5c740000"
  let genDevice = ro ? "tarwin-virt-vmgenid-ro" : "vmgenid,x-rotate-on-load=on,x-pinned-page=" + page
  let limits = ro ? ["-nodefaults", "-no-user-config", "-global", "fw_cfg_mem.dma_enabled=off"] : []
  let generationArgs = restore ? limits + ["-device", genDevice, "-blockdev",
    "driver=file,filename=" + d + "/state.qcow2,node-name=statefile", "-blockdev",
    "driver=qcow2,file=statefile,node-name=state"] : (cold && !fixed ? limits + ["-device", genDevice] : [])
  let fixedBytes = withUnsafeBytes(of: UUID().uuid) { Data($0) }
  var fixedArgs: [String] = []
  if fixed {
    guard a == "aarch64", !restore, (!cold || fixedRNG), !ro, !multiple, !secure, !displayEnabled,
      tpmEnabled == fixedRNG, rngEnabled, gen == "0", generationArgs.isEmpty,
      let binary = ProcessInfo.processInfo.environment["TARBOOT_FIXED_BINARY"], binary.hasPrefix("/") else {
      throw Failure("fixed ID requires an isolated cold debug machine")
    }
    process.executableURL = URL(fileURLWithPath: binary)
    let path = d + "/fixed-id"
    try fixedBytes.write(to: URL(fileURLWithPath: path))
    fixedArgs = ["-no-user-config", "-nodefaults", "-no-migration",
      "-fw_cfg", "name=opt/org.tessera/tarwin/debug-fixed-epoch,file=" + path]
    if cold { fixedArgs += ["-global", "fw_cfg_mem.dma_enabled=off"] }
  }
  let evidence = ProcessInfo.processInfo.environment["TARBOOT_TEST_W1_EVIDENCE"] == "1"
  let intake = ProcessInfo.processInfo.environment["TARBOOT_ENTER_W1_INTAKE"] == "1"
  let gateOnly = ProcessInfo.processInfo.environment["TARBOOT_TEST_W1_GATE_ONLY"] == "1"
  guard !gateOnly || intake else { throw Failure("gate-only test requires W1 firmware") }
  let changedCopy = ProcessInfo.processInfo.environment["TARBOOT_TEST_W1_CHANGED_COPY"] == "1"
  guard !changedCopy || gateOnly else { throw Failure("copy mutation requires the no-transfer test") }
  let badPIO = ProcessInfo.processInfo.environment["TARBOOT_TEST_INVALID_W1_PIO"] == "1"
  let changedEnvelope = ProcessInfo.processInfo.environment["TARBOOT_TEST_W1_CHANGED_ENVELOPE"] == "1"
  guard !changedEnvelope || (gateOnly && !changedCopy && !badPIO) else { throw Failure("invalid signature control") }
  var sigPath = d + "/esp/BOOT.SIG"
  if badPIO || changedEnvelope {
    guard intake else { throw Failure("PIO refusal requires signed kernel intake") }
    var copy = try Data(contentsOf: URL(fileURLWithPath: sigPath))
    guard !copy.isEmpty else { throw Failure("empty W1 signature") }
    copy[copy.count - 1] ^= 1
    sigPath = d + "/altered.sig"
    try copy.write(to: URL(fileURLWithPath: sigPath))
  }
  let signature = intake ? "file=" + sigPath : "string=not-a-signature"
  let evidenceArgs = (evidence ? ["-fw_cfg", "name=opt/org.tessera/tarwin/w1.sig," + signature] : [])
    + (extraPCI ? ["-device", "virtio-balloon-pci,addr=3,iommu_platform=on,disable-legacy=on"] : [])
  process.arguments =
    (fixed ? [] : ["qemu-system-" + a]) + machine + tpmArgs + displayArgs + rngArgs + generationArgs + evidenceArgs + (mcaArgs + q35Args + fixedArgs) + [
      "-m", "512", "-smp", multiple ? "4" : "1", "-display", "none", "-rtc", "base=utc",
      "-serial", "file:" + serial, "-monitor", "none", "-qmp", "stdio", "-nic", "none",
      "-drive", "if=pflash,format=raw,readonly=on,file=" + code, "-drive",
      "if=pflash,format=raw,file=" + d + "/vars.fd",
      "-drive", "if=none,id=esp,format=raw,readonly=on,file=fat:" + d + "/esp", "-device",
      secure ? "virtio-blk-pci,drive=esp,addr=0x6,bootindex=1" : "virtio-blk-pci,drive=esp" + endpoint + (isolatedPCI ? ",addr=1" : ""),
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
  let measuredInit = ProcessInfo.processInfo.environment["TARBOOT_TEST_SIGNED_INIT_PCR10"] == "1"
  let stagedImages = ProcessInfo.processInfo.environment["TARBOOT_TEST_PRIVATE_W1_IMAGES"] == "1"
  guard !stagedImages || measuredInit else { throw Failure("private image check needs PCR 10") }
  guard !measuredInit || intake else { throw Failure("PCR 10 requires signed kernel intake") }
  let deadline = ContinuousClock.now.advanced(by: .seconds(intake ? 300 : 60))
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
    _ = try request("pmemsave", ["val": ro ? 0x090d0010 : 0x5c740028, "size": 16, "filename": path])
    var uuid = id.uuid
    let raw = withUnsafeBytes(of: &uuid) { Array($0) }
    let wire = [3,2,1,0,5,4,7,6,8,9,10,11,12,13,14,15].map { raw[$0] }
    guard try Data(contentsOf: URL(fileURLWithPath: path)).elementsEqual(wire)
    else { throw Failure("device and paused guest generation differ") }
  }
  var injected = 0
  let expectedReports = mca == "wide" ? 1 : 2
  while process.isRunning && ContinuousClock.now < deadline {
    if intake, let raw = try? Data(contentsOf: URL(fileURLWithPath: serial)) {
      let lines = String(decoding: raw, as: UTF8.self).components(separatedBy: "\r\n").dropLast()
      if gateOnly && lines.contains("TARBOOT-W1-VERIFIED-TRANSFER") {
        throw Failure("gate-only firmware attempted kernel transfer")
      }
      if let failure = lines.first(where: { $0.hasPrefix("TARBOOT-W1-REFUSED") || $0.hasPrefix("TARWIN-W1-KERNEL-REFUSED") }) {
        if changedEnvelope, failure == "TARBOOT-W1-REFUSED-CHANGED-ENVELOPE",
           !lines.contains("TARBOOT-W1-FROZEN-COPY-CONFIRMED") {
          print("aarch64: live PCRs matched; final signature authorization refused identical changed envelopes before kernel installation")
          return
        }
        if changedCopy, failure == "TARBOOT-W1-REFUSED-MEASUREMENT",
          lines.contains("TARBOOT-W1-TEST-CHANGED-COPY"), !lines.contains("TARBOOT-W1-FROZEN-COPY-CONFIRMED"),
          !lines.contains("TARBOOT-W1-VERIFIED-TRANSFER") {
          print("aarch64: changed reserved archive refused by measurement gate after DMA exclusion, before kernel installation")
          return
        }
        if badPIO, failure == "TARBOOT-W1-REFUSED-SET",
           !lines.contains("TARBOOT-W1-VERIFIED-TRANSFER") {
          print("aarch64: altered post-EFI PIO signature refused before signed kernel transfer")
          return
        }
        throw Failure(failure)
      }
      if gateOnly, lines.contains("TARBOOT-W1-FROZEN-COPY-CONFIRMED") {
        guard !badPIO, !changedCopy, !changedEnvelope, !lines.contains("TARBOOT-W1-VERIFIED-TRANSFER") else { throw Failure("unexpected gate result") }
        print("aarch64: fenced copy reauthorized; PCR 8 and 9 matched one live TPM read; stopped before kernel installation")
        return
      }
      if !gateOnly, let gate = lines.firstIndex(of: "TARBOOT-W1-FROZEN-COPY-CONFIRMED"),
         let jump = lines[(gate+1)...].firstIndex(of: "TARBOOT-W1-VERIFIED-TRANSFER"),
         let verified = lines.suffix(from: jump + 1).firstIndex(of: "TARWIN-W1-KERNEL-REVERIFIED-BOOTSET") {
        guard !badPIO else { throw Failure("altered PIO signature passed signed intake") }
        if measuredInit {
          if let measured = lines[verified...].firstIndex(of: "TARWIN-W1-KERNEL-MEASURED-SIGNED-INIT-PCR10") {
            guard !stagedImages || lines[verified..<measured].contains("TARWIN-W1-KERNEL-STAGED-PRIVATE-IMAGES")
            else { throw Failure("kernel measured init without staging private images") }
            let stage = stagedImages ? "staged both private images and " : ""
            print("aarch64: signed kernel \(stage)measured the authorized init into PCR 10; no EL0 entry")
            return
          }
        } else {
          print("aarch64: signed intake kernel independently reverified the boot set after the firmware transfer; no EL0 entry")
          return
        }
      }
    }
    if mca != "0", injected < expectedReports, let raw = try? Data(contentsOf: URL(fileURLWithPath: mcaLog)) {
      let prefix = "MCA\(injected) "
      let lines = String(decoding: raw, as: UTF8.self).components(separatedBy: "\n").dropLast()
      if let line = lines.first(where: { $0.hasPrefix(prefix) }) {
        let hex = line.dropFirst(prefix.count)
        guard hex.count == 16, let gpa = UInt64(hex, radix: 16), gpa > 0, gpa < 512 << 20,
          gpa & 4095 == 0 else { throw Failure("invalid MCA test frame") }
        let command = "mce 0 4 0x9c00000000000090 0 \(gpa + UInt64(injected)) \(mca == "wide" ? 141 : 128)"
        let reply = try request("human-monitor-command", ["command-line": command])
        guard let s = reply as? String, s.isEmpty else { throw Failure("MCA report refused: \(reply)") }
        injected += 1
      }
    }
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
  if fixed {
    let wanted = "TARWIN-DEBUG-FIXED-TBIB=" + fixedBytes.map { String(format: "%02x", $0) }.joined() + "\r\n"
    guard uart.range(of: Data(wanted.utf8)) != nil else { throw Failure("fixed debug TBIB mismatch") }
    print("aarch64: fixed debug TBIB matches this cold launch; ordinary reader refused")
    if fixedRNG && !extraPCI && !wrongWindow {
      guard uart.range(of: Data("TARWIN-DEBUG-FIXED-TBIB-SWTPM-RNG-ACCEPTED".utf8)) != nil
      else { throw Failure("checked fixed-ID random launch did not complete") }
      print("TARWIN-DEBUG-FIXED-TBIB-SWTPM-RNG-ACCEPTED")
    }
  }
  if gen != "0" {
    let wire = withUnsafeBytes(of: q35ID.uuid) { Array($0) }
    let order = [3,2,1,0,5,4,7,6,8,9,10,11,12,13,14,15]
    let expected = gen == "present" ? [1] + order.map { wire[$0] } : [0]
    guard try Data(contentsOf: URL(fileURLWithPath: genLog)) == Data(expected)
    else { throw Failure("q35 ACPI VMGenID differs from host") }
    print("x86_64: q35 ACPI VMGenID " + (gen == "present" ? "matches host GUID" : "absent"))
  }
  if mca != "0" {
    let log = try String(contentsOfFile: mcaLog, encoding: .utf8)
    let marker = mca == "wide" ? "MCA-WIDE-RETAINED" : "MCA-CORRECTED-FRAME-RETIRED"
    guard injected == expectedReports, log.components(separatedBy: "\n").contains(marker)
    else { throw Failure("missing MCA verdict") }
    print("x86_64: " + marker)
  }
  if cold {
    let log = String(decoding: uart, as: UTF8.self)
    if let line = log.split(whereSeparator: \.isNewline).first(where: { $0.contains("TARWIN-FENCE-REFUSED-") }) {
      for row in log.split(whereSeparator: \.isNewline) where row.contains("TARWIN-COLD-") { print(row) }
      if (extraPCI || wrongWindow) && line.contains("TARWIN-FENCE-REFUSED-PLATFORM") && !log.contains("TARWIN-W1-EVIDENCE-COPIED") && !log.contains("TARWIN-DEBUG-FIXED-TBIB-SWTPM-RNG-ACCEPTED") {
        print("aarch64: \(extraPCI ? "unexpected PCI endpoint" : "wrong PCI window") refused before detached signature copy")
        return
      }
      throw Failure("cold W1 closed before signature copy: " + String(line))
    }
    guard !extraPCI && !wrongWindow, log.contains("TARWIN-FENCE-STREAMS-DENIED"),
      log.contains(fixed ? "TARWIN-DEBUG-FIXED-TBIB-SWTPM-RNG-ACCEPTED" : "TARWIN-COLD-VMGEN-ACCEPTED")
    else { throw Failure("missing cold generation or device fence") }
    print("aarch64: post-EFI disk/RNG streams denied before detached signature copy (\(highPCI ? "high" : "low") BARs)")
    if ProcessInfo.processInfo.environment["TARBOOT_TEST_KERNEL_INTAKE"] == "1" {
      guard log.contains("TARWIN-W1-KERNEL-INTAKE-FENCE-RECHECKED") else { throw Failure("kernel intake refused the pinned workspace") }
      print("aarch64: kernel intake rechecked the retained fence and refused a displaced workspace before reading the detached envelope")
    }
  }
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
  if ProcessInfo.processInfo.environment["TARBOOT_TEST_TSC_REFUSAL"] == "1" {
    guard a == "x86_64", uart.range(of: Data("TARWIN-X64-DEADLINE-REFUSED".utf8)) != nil
    else { throw Failure("missing x64 timer refusal") }
    print("x86_64: refused TSC-deadline on the unsupported emulated CPU")
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
  if ProcessInfo.processInfo.environment["TARBOOT_TEST_BOOT_HART"] == "1" {
    guard a == "riscv64", multiple, uart.range(of: Data("TARWIN-RV64-BOOT-HART-PROTOCOL".utf8)) != nil
    else { throw Failure("missing RISC-V boot protocol") }
    print("\(a): after EFI exit HSM reported the firmware boot hart started and all other listed harts stopped")
  }
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
            uart.range(of: Data("TARWIN-VMGEN-RESTORED-PAC-BANK-RETIRED".utf8)) != nil,
            uart.range(of: Data("TARWIN-VMGEN-RESTORED-REFUSED-RESEEDED".utf8)) != nil
          else { throw Failure("missing snapshot restore and checked reseed") }
          print("\(a): restored guest retired the old PAC bank and rejected its previous RNG stream, then reseeded from swtpm")
        } else if !cold {
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
    "\(a): ESP file read, TIRA member and ELF preflight, EFI exit, CPU-only frame pins, compressed-page restore, page retirement, boot queue and shutdown passed"
  )
}

do { try check() } catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
