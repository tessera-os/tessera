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
    return child.terminationReason == .exit && child.terminationStatus == 0
  } catch { return false }
}
