import Foundation

// Disposable negative-control VM. No guest or TBIB is supplied here.
private struct Refused: Error {}
private func run(_ executable: String, _ args: [String], input: Data = Data()) throws -> (Int32, Data) {
  let p = Process(), stdin = Pipe(), output = Pipe()
  p.executableURL = URL(fileURLWithPath: executable)
  p.arguments = args
  p.standardInput = stdin
  p.standardOutput = output
  p.standardError = output
  try p.run()
  try stdin.fileHandleForWriting.write(contentsOf: input)
  try stdin.fileHandleForWriting.close()
  let deadline = ContinuousClock.now.advanced(by: .seconds(10))
  while p.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
  if p.isRunning { kill(p.processIdentifier, SIGKILL) }
  p.waitUntilExit()
  return (p.terminationStatus, try output.fileHandleForReading.readToEnd() ?? Data())
}

func check() throws {
  guard CommandLine.arguments.count == 3 else { throw Refused() }
  let binary = CommandLine.arguments[1], work = CommandLine.arguments[2]
  let guardMessage = "VM state transfer disabled by -no-migration"
  let common = ["-no-migration", "-no-user-config", "-machine", "virt-11.1,accel=tcg", "-nodefaults",
    "-S", "-display", "none", "-nic", "none", "-monitor", "none", "-serial", "none"]
  for args in [["-incoming", "defer"], ["-loadvm", "not-a-snapshot"]] {
    let (status, output) = try run(binary, common + args)
    guard status != 0, output.range(of: Data(guardMessage.utf8)) != nil else { throw Refused() }
  }
  let disk = work + "/control.qcow2", destination = work + "/denied-state"
  guard try run("/usr/bin/env", ["qemu-img","create","-q","-f","qcow2",disk,"4M"]).0 == 0
  else { throw Refused() }
  defer { try? FileManager.default.removeItem(atPath: disk) }
  let requests: [[String:Any]] = [
    ["execute":"qmp_capabilities"],
    ["execute":"migrate","arguments":["uri":"file:" + destination]],
    ["execute":"migrate-incoming","arguments":["uri":"defer"]],
    ["execute":"human-monitor-command","arguments":["command-line":"savevm fixture"]],
    ["execute":"human-monitor-command","arguments":["command-line":"loadvm fixture"]],
    ["execute":"query-status"], ["execute":"quit"]]
  var bytes = Data()
  for (id, var request) in requests.enumerated() {
    request["id"] = id
    bytes.append(try JSONSerialization.data(withJSONObject: request))
    bytes.append(10)
  }
  let (status, log) = try run(binary, common + ["-qmp","stdio","-drive","if=none,format=qcow2,file=" + disk],
    input: bytes)
  guard status == 0 else { throw Refused() }
  let replies = log.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String:Any] }
  for id in 1...4 {
    guard let reply = replies.first(where: { $0["id"] as? Int == id }),
      let error = (reply["error"] as? [String:Any])?["desc"] as? String ?? reply["return"] as? String,
      error.contains(guardMessage) else { throw Refused() }
  }
  guard let state = replies.first(where: { $0["id"] as? Int == 5 })?["return"] as? [String:Any],
    state["running"] as? Bool == false, !FileManager.default.fileExists(atPath: destination)
  else { throw Refused() }
}

do { try check() } catch {
  FileHandle.standardError.write(Data("QEMU did not demonstrate the no-restore launch policy\n".utf8))
  exit(1)
}
