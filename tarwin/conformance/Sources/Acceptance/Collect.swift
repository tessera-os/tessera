import Foundation

func deviceCases(_ ref: Reference) -> [String] {
  var required = cases()
  required.append(ref.nested ? "hv.nested" : "hv.reject-nested")
  required.append(ref.confidential ? "hv.confidential-attestation" : "hv.reject-confidential")
  return required
}

struct Sample {
  let key, system: String
  let trial: Int
  var stem: String { "\(key)/\(system)-\(trial)" }
  var row: String { "\(key)\t\(system)\t\(trial)\n" }
}

// A controller may batch reboots, but may not reuse another trial's samples.
func samples(_ ref: Reference) -> [Sample] {
  var plan = deviceCases(ref).map { Sample(key: $0, system: "tarwin", trial: 1) }
  for b in budgets(ref.battery) {
    let comparators =
      b.baseline == "best-fs"
      ? ["linux-ext4", "linux-btrfs"]
      : b.baseline == "absolute" ? [] : [b.baseline]
    for system in ["tarwin"] + comparators {
      plan += (1...10).map { Sample(key: b.name, system: system, trial: $0) }
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

private func receipt(_ root: String, _ ref: Reference, _ run: UUID) -> Data? {
  let plan = samples(ref)
  guard let hashes = captureHashes(root, ref, plan) else { return nil }
  var data = Data(("v2\t26.11.1\t" + run.uuidString + "\n" + ref.row + "\n").utf8)
  data.append(hashes)
  return data
}

func completedCollection(_ root: String, _ ref: Reference, _ run: UUID) -> Bool {
  let url = receiptURL(root, ref)
  guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.path,
    let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
    info.isRegularFile == true, let size = info.fileSize, size <= 1 << 20,
    let expected = receipt(root, ref, run), size == expected.count
  else { return false }
  return (try? Data(contentsOf: url)) == expected
}

func collect(_ program: String, _ root: String, _ ref: Reference, _ run: UUID) -> Bool {
  let plan = URL(fileURLWithPath: root).appendingPathComponent(ref.serial + ".plan.tsv")
  do {
    try samples(ref).map(\.row).joined().write(to: plan, atomically: true, encoding: .utf8)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: program)
    child.arguments = [ref.arch, ref.serial, ref.tarwin, ref.linux, root, plan.path]
    child.standardInput = FileHandle.nullDevice
    try child.run()
    child.waitUntilExit()
    guard child.terminationReason == .exit && child.terminationStatus == 0,
      let sealed = receipt(root, ref, run)
    else { return false }
    try sealed.write(to: receiptURL(root, ref), options: .atomic)
    return true
  } catch { return false }
}
