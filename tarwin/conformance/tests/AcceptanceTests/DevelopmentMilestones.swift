import Foundation
import Testing

@testable import Acceptance

@Test func buildSetsAndProvenanceMustMatchAcrossArchives() throws {
  let arm = try #require(reference("physical\taarch64\tboard\ttrain-abc\tlinux-abc\tyes\tno\tno"))
  let rv = try #require(reference("physical\trv64\trv\ttrain-rv\tlinux-rv\tno\tno\tno"))
  let row = "qemu\taarch64\tvirt-1\ttrain-abc"
  let dev = try #require(qemuReference(row))
  #expect(dev.row == row && reference(row) == nil && qemuReference(arm.row) == nil)
  #expect(qemuReference(row.replacingOccurrences(of: "virt-1", with: "collection.tsv")) == nil)
  #expect(sameArmBuilds([arm, rv], [dev]))
  #expect(!sameArmBuilds([rv], [dev]))
  #expect(!sameArmBuilds([arm], [arm]))
  #expect(!sameArmBuilds([arm], [try #require(qemuReference("qemu\taarch64\tvirt-1\tother"))]))
  #expect(samples(dev).map(\.key) == qemuMilestones)
  #expect(samples(arm).allSatisfy { !qemuMilestones.contains($0.key) })
}

@Test func qemuArchiveCannotPassPhysicalOrAcceptChangedCapture() throws {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let root = base.appendingPathComponent("archive")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: base) }
  let ref = try #require(qemuReference("qemu\taarch64\tvirt\ttrain1"))
  let inventory = base.appendingPathComponent("inventory")
  try Data((ref.row + "\n").utf8).write(to: inventory)
  let args = ["--qemu", inventory.path, root.path]
  let id = try #require(archiveID(root.path, [ref], create: true))
  for s in samples(ref) {
    let url = root.appendingPathComponent(ref.serial).appendingPathComponent(s.stem)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let row = [
      "26.11.1", "qemu", ref.arch, ref.serial, s.key, s.system, ref.tarwin, String(s.trial), "pass",
    ]
    try Data(row.joined(separator: "\t").utf8).write(to: url.appendingPathExtension("tsv"))
    try Data("synthetic unit-test capture only".utf8).write(to: url.appendingPathExtension("log"))
  }
  #expect(run(args) == 1)  // unsealed
  try #require(collect("/usr/bin/true", root.path, ref, id))
  #expect(run(args) == 0)
  #expect(run(Array(args.dropFirst())) != 0)  // cannot score QEMU as physical
  let cp = root.appendingPathComponent("virt/w1.ipc/tarwin-1.log")
  try Data("changed".utf8).write(to: cp)
  #expect(run(args) == 1)
}
