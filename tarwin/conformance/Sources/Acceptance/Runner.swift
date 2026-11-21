import Foundation

public func run(_ args: [String]) -> Int32 {
  guard (2...3).contains(args.count) else {
    print("usage: tarwin-conformance <inventory.tsv> <evidence-directory> [absolute-lab-adapter]")
    return 2
  }
  guard let inventory = try? String(contentsOfFile: args[0], encoding: .utf8) else {
    print("NOT VERIFIED reference inventory unavailable")
    return 2
  }
  var refs = [Reference]()
  var ids = Set<String>()
  for line in inventory.components(separatedBy: .newlines)
  where !line.isEmpty && !line.hasPrefix("#") {
    guard let ref = reference(line), ids.insert(ref.serial).inserted else {
      print("invalid or duplicate physical reference")
      return 2
    }
    refs.append(ref)
  }
  var blocked = 0
  func report(_ key: String, _ result: Verdict) {
    print("\(result.rawValue) \(key)")
    if result != .passed { blocked += 1 }
  }
  for arch in ["aarch64", "x64", "rv64"] where !refs.contains(where: { $0.arch == arch }) {
    report("physical reference: " + arch, .missing)
  }
  let root = args[1]
  if args.count == 3 {
    guard args[2].hasPrefix("/"), !FileManager.default.fileExists(atPath: root),
      (try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false))
        != nil
    else {
      print("collection needs an absolute adapter and a new evidence directory")
      return 2
    }
  }
  for ref in refs {
    print("reference \(ref.serial) (\(ref.arch))")
    if args.count == 3 && !collect(args[2], root, ref) {
      report("lab collection: " + ref.serial, .missing)
    }
    for key in deviceCases(ref) {
      let value = evidence(root, ref, key, "tarwin", 1)
      report(key, value == "pass" ? .passed : value == "fail" ? .missed : .missing)
    }
    for b in budgets(ref.battery) { report(b.name, budgetVerdict(root, ref, b)) }
  }
  if blocked > 0 {
    print("TRAIN BLOCKED: \(blocked) failed or unverified gates")
    return 1
  }
  print(
    "All catalogued physical-reference gates passed; review captures and coverage before release.")
  return 0
}
