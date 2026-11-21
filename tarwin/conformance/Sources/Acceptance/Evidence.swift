import Foundation

struct Reference {
  enum Target: String { case physical, qemu }
  let target: Target
  let arch, serial, tarwin, linux: String
  let battery, nested, confidential: Bool
  let backend: String?
  let storage: [String]?  // nil: inventory unknown; empty: no transport enrolled
}

func safeID(_ id: String) -> Bool {
  !id.isEmpty && id.utf8.count <= 128 && id != "." && id != ".."
    && id.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || [45, 46, 95].contains($0)
    }
}

private func validSiteID(_ id: String) -> Bool {
  safeID(id) && id.lowercased() != "collection.tsv"
    && ![".plan.tsv", ".complete.tsv"].contains(where: { id.lowercased().hasSuffix($0) })
}

func reference(_ line: String) -> Reference? {
  var f = line.components(separatedBy: "\t")
  var storage: [String]?
  if let field = f.last, field.hasPrefix("storage=") {
    let value = String(field.dropFirst("storage=".count))
    let names = value.components(separatedBy: ",")
    guard names.count <= 8, Set(names).count == names.count,
      names.allSatisfy({ id in
        (1...32).contains(id.utf8.count)
          && id.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45
          }
      }), value == "none" || !names.contains("none")
    else { return nil }
    storage = value == "none" ? [] : names
    f.removeLast()
  }
  guard (8...9).contains(f.count), f[0] == "physical", ["aarch64", "x64", "rv64"].contains(f[1]),
    f.count == 8 || (f[1] == "x64" && ["vmx", "svm"].contains(f[8])),
    validSiteID(f[2]), f[3...4].allSatisfy(safeID),
    f[5...7].allSatisfy({ $0 == "yes" || $0 == "no" })
  else { return nil }
  return Reference(
    target: .physical, arch: f[1], serial: f[2], tarwin: f[3], linux: f[4], battery: f[5] == "yes",
    nested: f[6] == "yes", confidential: f[7] == "yes", backend: f.count == 9 ? f[8] : nil,
    storage: storage)
}

// W0 is explicitly the Arm QEMU machine. Use the same target for the W1
// object and IPC suites, never the synthetic guest used in the HV probes.
func qemuReference(_ line: String) -> Reference? {
  let f = line.components(separatedBy: "\t")
  guard f.count == 4, f[0] == "qemu", f[1] == "aarch64",
    validSiteID(f[2]), safeID(f[3])
  else { return nil }
  return Reference(
    target: .qemu, arch: f[1], serial: f[2], tarwin: f[3], linux: "", battery: false,
    nested: false, confidential: false, backend: nil, storage: nil)
}

func captureExists(_ file: URL) -> Bool {
  guard file.resolvingSymlinksInPath().standardizedFileURL.path == file.path,
    let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
    info.isRegularFile == true, let size = info.fileSize, size > 0
  else { return false }
  return file.pathExtension == "log" || size <= 2048
}

func evidence(_ root: String, _ ref: Reference, _ key: String, _ system: String, _ trial: Int)
  -> String?
{
  let dir = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
  let stem = dir.appendingPathComponent(ref.serial).appendingPathComponent(key)
    .appendingPathComponent("\(system)-\(trial)")
  for ext in ["log", "tsv"] {
    guard captureExists(stem.appendingPathExtension(ext)) else { return nil }
  }
  guard let line = try? String(contentsOf: stem.appendingPathExtension("tsv"), encoding: .utf8)
  else { return nil }
  let fields = line.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
  let binding = [
    "26.11.1", ref.target.rawValue, ref.arch, ref.serial, key, system,
    system == "tarwin" ? ref.tarwin : ref.linux, String(trial),
  ]
  guard fields.count == 9, fields.dropLast().elementsEqual(binding) else { return nil }
  return fields.last
}

func positive(_ text: String) -> Double? {
  guard let n = Double(text), n > 0, n.isFinite else { return nil }
  return n
}

func geometricMean(_ values: [Double]) -> Double? {
  guard values.count == 10, values.allSatisfy({ $0 > 0 && $0.isFinite }) else { return nil }
  if values.allSatisfy({ $0 == values[0] }) { return values[0] }
  return exp(values.map(log).reduce(0, +) / 10)
}

enum Verdict: String {
  case passed = "PASS"
  case missed = "FAIL"
  case missing = "NOT VERIFIED"
}

func budgetVerdict(_ root: String, _ ref: Reference, _ budget: Budget) -> Verdict {
  func mean(_ system: String) -> Double? {
    geometricMean(
      (1...10).compactMap { evidence(root, ref, budget.name, system, $0).flatMap(positive) })
  }
  guard let measured = mean("tarwin") else { return .missing }
  var baseline = 1.0
  if budget.baseline == "best-fs" {
    guard let ext = mean("linux-ext4"), let btrfs = mean("linux-btrfs") else { return .missing }
    baseline = max(ext, btrfs)
  } else if budget.baseline != "absolute" {
    guard let value = mean(budget.baseline) else { return .missing }
    baseline = value
  }
  print("  geometric mean \(measured); baseline \(baseline)")
  let threshold = baseline * budget.limit
  return (budget.lower ? measured <= threshold : measured >= threshold) ? .passed : .missed
}
