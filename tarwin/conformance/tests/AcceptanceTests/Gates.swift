import Foundation
import Testing

@testable import Acceptance

@Test func physicalRows() {
  let row = "physical\tx64\tboard\tbuild\t6.18\tyes\tno\tyes"
  #expect(reference(row) != nil)
  for (key, value) in [
    ("physical", "qemu"), ("board", "../bad"), ("x64", "armv7"), ("no", "unknown"),
  ] {
    #expect(reference(row.replacingOccurrences(of: key, with: value)) == nil)
  }
}

@Test func means() {
  #expect(geometricMean([1, 2]) == nil)
  for invalid in [0.0, -.infinity, .infinity, .nan] {
    #expect(geometricMean([invalid] + Array(repeating: 1, count: 9)) == nil)
  }
  #expect(abs((geometricMean([1, 4, 1, 4, 1, 4, 1, 4, 1, 4]) ?? 0) - 2) < 1e-10)
  #expect(positive("1foo") == nil)
}

@Test func catalog() {
  let keys = cases() + budgets(true).map(\.name)
  #expect(Set(keys).count == keys.count)
  #expect(budgets(true).count == budgets(false).count + 2)
}

@Test func bindsEvidenceToBuildAndRejectsSymlinks() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let ref = try #require(reference("physical\tx64\tboard\tbuild\tlinux\tno\tno\tno"))
  let dir = root.appendingPathComponent("board/test")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let log = dir.appendingPathComponent("tarwin-1.log")
  try Data([1]).write(to: log)
  let result = dir.appendingPathComponent("tarwin-1.tsv")
  let row = "26.11.1\tphysical\tx64\tboard\ttest\ttarwin\tbuild\t1\tpass"
  try row.write(to: result, atomically: true, encoding: .utf8)
  #expect(evidence(root.path, ref, "test", "tarwin", 1) == "pass")
  try row.replacingOccurrences(of: "build", with: "other").write(
    to: result, atomically: true, encoding: .utf8)
  #expect(evidence(root.path, ref, "test", "tarwin", 1) == nil)
  try FileManager.default.removeItem(at: log)
  try FileManager.default.createSymbolicLink(at: log, withDestinationURL: result)
  try row.write(to: result, atomically: true, encoding: .utf8)
  #expect(evidence(root.path, ref, "test", "tarwin", 1) == nil)
}
