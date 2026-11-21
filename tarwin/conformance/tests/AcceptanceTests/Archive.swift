import Foundation
import Testing

@testable import Acceptance

@Test func failedAdapterCannotBecomeASuccessfulArchivedCollection() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let ref = try #require(reference("physical\tx64\tboard\tt1\tl1\tno\tyes\tno"))
  #expect(!collect("/usr/bin/false", root.path, ref))
  #expect(!completedCollection(root.path, ref))
  #expect(collect("/usr/bin/true", root.path, ref))
  #expect(completedCollection(root.path, ref))
  let changed = try #require(reference("physical\tx64\tboard\tt1\tl1\tno\tno\tno"))
  #expect(!completedCollection(root.path, changed))
  let url = root.appendingPathComponent("board.complete.tsv")
  let alt = root.appendingPathComponent("copy")
  try FileManager.default.moveItem(at: url, to: alt)
  try FileManager.default.createSymbolicLink(at: url, withDestinationURL: alt)
  #expect(!completedCollection(root.path, ref))
}

@Test func allTenTrialsAndFasterFilesystemAreRequired() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let ref = try #require(reference("physical\tx64\tboard\tt1\tl1\tno\tno\tno"))
  let b = try #require(budgets(false).first { $0.name == "metadata.lookup" })
  let dir = root.appendingPathComponent("board/metadata.lookup")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  func write(_ system: String, _ i: Int, _ n: Int) throws {
    let stem = dir.appendingPathComponent("\(system)-\(i)")
    let row = [
      "26.11.1", "physical", "x64", "board", b.name, system,
      system == "tarwin" ? "t1" : "l1", String(i), String(n),
    ]
    try Data(row.joined(separator: "\t").utf8).write(to: stem.appendingPathExtension("tsv"))
    try Data("fixture only".utf8).write(to: stem.appendingPathExtension("log"))
  }
  for i in 1...10 {
    try write("linux-ext4", i, 100)
    try write("tarwin", i, 95)
    if i < 10 { try write("linux-btrfs", i, 101) }
  }
  #expect(budgetVerdict(root.path, ref, b) == .missing)
  try write("linux-btrfs", 10, 101)
  #expect(budgetVerdict(root.path, ref, b) == .missed)
  for i in 1...10 { try write("tarwin", i, 96) }
  #expect(budgetVerdict(root.path, ref, b) == .passed)
}
