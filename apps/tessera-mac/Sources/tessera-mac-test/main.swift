import Foundation
import TesseraHostKit
import Darwin

do {
    guard CommandLine.arguments.count == 2 else { throw DiskError.io("Usage: tessera-mac-test Tessera.app") }
    let bundle = URL(fileURLWithPath: CommandLine.arguments[1])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("boot.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    let process = Process(); process.executableURL = bundle.appendingPathComponent("Contents/MacOS/Tessera")
    process.arguments = ["--headless", "--exit-after-ready", "--disk", directory.path]
    process.standardOutput = output; process.standardError = output
    try process.run()
    let deadline = Date().addingTimeInterval(60)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if process.isRunning { process.terminate(); throw DiskError.io("Timed out waiting for TESSERA READY") }
    try output.close()
    let text = try String(contentsOf: log, encoding: .utf8)
    print(text, terminator: "")
    guard process.terminationStatus == 0, text.contains("TESSERA READY"), text.contains("H5 composition received"), text.contains("TASK CHECKED IN") else {
        throw DiskError.io("Boot or frame check failed (exit \(process.terminationStatus))")
    }
    let stages = ["time", "objects", "syscalls", "storage", "network", "scheduler", "ready"]
    guard text.contains("Kernel: TarwindKernel"), !text.contains("Kernel boot failed:"),
          stages.allSatisfy({ text.contains("Stage: \($0)\n") }) else {
        throw DiskError.io("Real kernel did not reach its expected boot stages")
    }
    print("TarwindKernel reached: " + stages.joined(separator: " -> "))
    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("system.trfsdisk").path) else {
        throw DiskError.io("Tarwind did not create the data disk")
    }
    print("tessera-mac-test PASS: real kernel ready, H5 composition received, kernel-created disk, task checked in")
} catch { print("tessera-mac-test FAIL: \(error)"); exit(1) }
