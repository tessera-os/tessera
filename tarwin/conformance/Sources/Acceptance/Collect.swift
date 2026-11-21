import Foundation

func deviceCases(_ ref: Reference) -> [String] {
  var required = cases()
  required.append(ref.nested ? "hv.nested" : "hv.reject-nested")
  required.append(ref.confidential ? "hv.confidential-attestation" : "hv.reject-confidential")
  return required
}

func trials(_ key: String, _ system: String) -> String {
  var s = ""
  for i in 1...10 { s += "\(key)\t\(system)\t\(i)\n" }
  return s
}

// A controller may batch reboots, but may not reuse another trial's samples.
func measurementPlan(_ ref: Reference) -> String {
  var plan = ""
  for key in deviceCases(ref) { plan += "\(key)\ttarwin\t1\n" }
  for b in budgets(ref.battery) {
    plan += trials(b.name, "tarwin")
    if b.baseline == "best-fs" {
      plan += trials(b.name, "linux-ext4") + trials(b.name, "linux-btrfs")
    } else if b.baseline != "absolute" {
      plan += trials(b.name, b.baseline)
    }
  }
  return plan
}

// Archive evaluation requires proof that the controller observed a clean
// adapter exit for this inventory and plan, not just a directory of samples.
private func receiptURL(_ root: String, _ ref: Reference) -> URL {
  URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
    .appendingPathComponent(ref.serial + ".complete.tsv")
}

func receipt(_ ref: Reference) -> Data {
  let header = [
    "26.11.1", "physical", ref.arch, ref.serial, ref.tarwin, ref.linux,
    ref.battery ? "yes" : "no", ref.nested ? "yes" : "no", ref.confidential ? "yes" : "no",
  ]
  return Data((header.joined(separator: "\t") + "\n" + measurementPlan(ref)).utf8)
}

func completedCollection(_ root: String, _ ref: Reference) -> Bool {
  let url = receiptURL(root, ref)
  let expected = receipt(ref)
  guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.path,
    let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
    info.isRegularFile == true, info.fileSize == expected.count
  else { return false }
  return (try? Data(contentsOf: url)) == expected
}

func collect(_ program: String, _ root: String, _ ref: Reference) -> Bool {
  let plan = URL(fileURLWithPath: root).appendingPathComponent(ref.serial + ".plan.tsv")
  do {
    try measurementPlan(ref).write(to: plan, atomically: true, encoding: .utf8)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: program)
    child.arguments = [ref.arch, ref.serial, ref.tarwin, ref.linux, root, plan.path]
    child.standardInput = FileHandle.nullDevice
    try child.run()
    child.waitUntilExit()
    guard child.terminationReason == .exit && child.terminationStatus == 0 else { return false }
    try receipt(ref).write(to: receiptURL(root, ref), options: .atomic)
    return true
  } catch { return false }
}
