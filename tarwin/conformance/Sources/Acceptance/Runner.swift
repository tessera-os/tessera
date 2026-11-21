import Foundation

private let architectures = ["aarch64", "x64", "rv64"]

// With no inventory, expose both branches of a capability-dependent gate.
// These are unknowns, not assertions about hardware we haven't inspected.
func missingGates(_ arch: String, _ ref: Reference?) -> [String] {
  let keys =
    ref.map(deviceCases)
    ?? (cases() + platformCases(arch, backend: nil)
      + ["hv.nested", "hv.reject-nested", "hv.confidential-attestation", "hv.reject-confidential"])
  return keys + [roleKey] + budgets(ref?.battery ?? true).map(\.name)
}

private func unverified(_ arch: String, _ ref: Reference? = nil) {
  for key in missingGates(arch, ref) {
    print("NOT VERIFIED\t\(arch)\t\(ref?.serial ?? "-")\t\(key)")
  }
}

private func readInventory(_ path: String, _ target: Reference.Target) -> [Reference]? {
  guard let inventory = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
  var refs = [Reference]()
  var ids = Set<String>()
  for line in inventory.components(separatedBy: .newlines)
  where !line.isEmpty && !line.hasPrefix("#") {
    guard let ref = (target == .physical ? reference(line) : qemuReference(line)),
      ids.insert(ref.serial.lowercased()).inserted
    else { return nil }
    refs.append(ref)
  }
  return refs
}

func sameArmBuilds(_ hardware: [Reference], _ dev: [Reference]) -> Bool {
  let arm = Set(hardware.filter { $0.target == .physical && $0.arch == "aarch64" }.map(\.tarwin))
  return !arm.isEmpty && dev.allSatisfy { $0.target == .qemu } && arm == Set(dev.map(\.tarwin))
}

private func score(
  _ refs: [Reference], _ root: String, _ adapter: String?, _ target: Reference.Target
) -> Int32 {
  let qemu = target == .qemu
  var blocked = 0
  func report(_ key: String, _ result: Verdict) {
    print("\(result.rawValue) \(key)")
    if result != .passed { blocked += 1 }
  }
  func unknown(_ arch: String, _ ref: Reference? = nil) {
    if qemu {
      for key in qemuMilestones { report("qemu " + arch + " " + key, .missing) }
    } else {
      unverified(arch, ref)
    }
  }
  for arch in (qemu ? ["aarch64"] : architectures) where !refs.contains(where: { $0.arch == arch })
  {
    report(target.rawValue + " reference: " + arch, .missing)
    unknown(arch)
  }
  if let adapter {
    guard adapter.hasPrefix("/"), !FileManager.default.fileExists(atPath: root),
      (try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false))
        != nil
    else {
      print("collection needs an absolute adapter and a new evidence directory")
      return 2
    }
  }
  guard let id = archiveID(root, refs, create: adapter != nil) else {
    for ref in refs { unknown(ref.arch, ref) }
    print("TRAIN BLOCKED: collection manifest missing or inventory changed")
    return 1
  }
  var failed = Set<String>()
  if let adapter {
    for ref in refs
    where (ref.arch == "x64" && ref.backend == nil) || !collect(adapter, root, ref, id) {
      failed.insert(ref.serial)
    }
    guard archiveID(root, refs, create: false) == id else {
      for ref in refs { unknown(ref.arch, ref) }
      print("TRAIN BLOCKED: collection manifest changed during capture")
      return 1
    }
  }
  var qualifying = Set<String>()
  for ref in refs {
    print("reference \(ref.serial) (\(ref.arch))")
    if ref.arch == "x64" && ref.backend == nil {
      report("unidentified x64 virtualization backend: " + ref.serial, .missing)
      unknown(ref.arch, ref)
      continue
    }
    if failed.contains(ref.serial) || !completedCollection(root, ref, id) {
      report("lab collection: " + ref.serial, .missing)
      unknown(ref.arch, ref)
      continue
    }
    for key in (qemu ? qemuMilestones : deviceCases(ref)) {
      let value = evidence(root, ref, key, "tarwin", 1)
      report(key, value == "pass" ? .passed : value == "fail" ? .missed : .missing)
    }
    if qemu { continue }
    // W10 needs at least one actual x64 desktop and an Arm laptop or
    // development board. Do not infer those from serial strings or battery flags.
    let role = evidence(root, ref, roleKey, "tarwin", 1) ?? ""
    if ["desktop", "laptop", "development-board", "server", "phone", "tablet", "console", "other"]
      .contains(role)
    {
      report(roleKey + ": " + role, .passed)
      if (ref.arch == "x64" && role == "desktop")
        || (ref.arch == "aarch64" && ["laptop", "development-board"].contains(role))
      {
        qualifying.insert(ref.arch)
      }
    } else {
      report(roleKey, .missing)
    }
    for b in budgets(ref.battery) { report(b.name, budgetVerdict(root, ref, b)) }
  }
  if !qemu {
    for arch in ["aarch64", "x64"] where !qualifying.contains(arch) {
      report("w10.reference-class." + arch, .missing)
    }
  }
  if blocked > 0 {
    print("TRAIN BLOCKED: \(blocked) failed or unverified gates")
    return 1
  }
  print(
    qemu
      ? "QEMU W0/W1 gates passed; no physical acceptance implied."
      : "Physical-reference gates passed; QEMU W0/W1 archives and integration review are separate.")
  return 0
}

public func run(_ args: [String]) -> Int32 {
  if args == ["--unverified"] || args == ["--train", "--unverified"]
    || args == ["--qemu", "--unverified"]
  {
    if args.first != "--qemu" {
      for arch in architectures { unverified(arch) }
      for arch in ["aarch64", "x64"] {
        print("NOT VERIFIED\t\(arch)\t-\tw10.reference-class.\(arch)")
      }
    }
    if args.first != "--unverified" {
      for key in qemuMilestones { print("NOT VERIFIED\tqemu-aarch64\t-\t\(key)") }
    }
    return 1
  }
  if args.first == "--train" {
    guard args.count == 5, let refs = readInventory(args[1], .physical),
      let dev = readInventory(args[3], .qemu)
    else {
      print("invalid train inventories")
      return 2
    }
    let physical = score(refs, args[2], nil, .physical)
    let qemu = score(dev, args[4], nil, .qemu)
    guard sameArmBuilds(refs, dev) else {
      print("NOT VERIFIED QEMU/physical Arm build-set binding")
      return 1
    }
    return physical == 0 && qemu == 0 ? 0 : 1
  }
  let target: Reference.Target = args.first == "--qemu" ? .qemu : .physical
  let paths = target == .qemu ? Array(args.dropFirst()) : args
  guard (2...3).contains(paths.count) else {
    print(
      "usage: tarwin-conformance [--qemu] <inventory> <archive> [absolute-adapter] | --train <physical-inventory> <physical-archive> <qemu-inventory> <qemu-archive> | --unverified"
    )
    return 2
  }
  guard let refs = readInventory(paths[0], target) else {
    print("NOT VERIFIED missing or invalid \(target.rawValue) inventory")
    if target == .physical {
      for arch in architectures { unverified(arch) }
    } else {
      for key in qemuMilestones { print("NOT VERIFIED qemu " + key) }
    }
    return 2
  }
  return score(refs, paths[1], paths.count == 3 ? paths[2] : nil, target)
}
