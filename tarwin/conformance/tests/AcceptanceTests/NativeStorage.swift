import Foundation
import Testing

@testable import Acceptance

@Test func storageSampleCannotSubstituteAnotherTransportOrBackend() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let ref = try #require(
    reference("physical\taarch64\tboard\ttrain\tlinux\tno\tno\tno\tstorage=nvme,virtio-blk"))
  let key = "storage.native.nvme.bounded-read-bytes"
  let dir = root.appendingPathComponent("board").appendingPathComponent(key)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try Data("unit-test fixture only".utf8).write(to: dir.appendingPathComponent("tarwin-1.log"))
  for (target, arch, reportedKey, expected) in [
    ("qemu", "aarch64", key, nil),
    ("hosted", "aarch64", key, nil),
    ("physical", "x64", key, nil),
    ("physical", "aarch64", "storage.native.virtio-blk.bounded-read-bytes", nil),
    ("physical", "aarch64", key, "pass"),
  ] {
    let row = ["26.11.1", target, arch, "board", reportedKey, "tarwin", "train", "1", "pass"]
    try Data(row.joined(separator: "\t").utf8).write(to: dir.appendingPathComponent("tarwin-1.tsv"))
    #expect(evidence(root.path, ref, key, "tarwin", 1) == expected)
  }
}

@Test func nativeStoragePlanIsScopedToEveryEnrolledTransport() throws {
  for arch in ["x64", "rv64", "aarch64"] {
    let base = "physical\t\(arch)\tboard\ttrain\tlinux\tno\tno\tno" + (arch == "x64" ? "\tvmx" : "")
    let full = base + "\tstorage=nvme,virtio-blk"
    let ref = try #require(reference(full))
    #expect(ref.row == full)
    let required = samples(ref).filter { $0.key.hasPrefix("storage.native.") }
    #expect(required.allSatisfy { $0.trial == 1 && $0.system == "tarwin" })
    let keys = Set(required.map(\.key))
    #expect(keys.count == required.count)
    for transport in ["nvme", "virtio-blk"] {
      for witness in [
        "bounded-read-bytes", "isolated-requester", "protected-pages-denied",
        "adjacent-pages-denied",
        "wrong-direction-denied", "stale-generation-denied", "failed-invalidation-quarantine",
        "queue-specific-authority", "revoke-before-reuse",
      ] {
        #expect(keys.contains("storage.native.\(transport).\(witness)"))
      }
    }
    let none = try #require(reference(base + "\tstorage=none"))
    #expect(none.row == base + "\tstorage=none")
    #expect(
      samples(none).map(\.key).filter { $0.hasPrefix("storage.native.") } == [
        "storage.native.unenrolled-denied"
      ])
    for invalid in [
      "", "none,nvme", "Nvme", "nvme,nvme", "a/b", "nvme,", String(repeating: "x", count: 33),
    ] {
      #expect(reference(base + "\tstorage=" + invalid) == nil)
    }
  }
  let dev = try #require(qemuReference("qemu\taarch64\tvirt\ttrain"))
  #expect(!samples(dev).contains { $0.key.hasPrefix("storage.native.") })
}

@Test func changedTransportListCannotReuseCollectionAndLegacyInventoryCannotRunAdapter() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let row = "physical\tx64\tboard\ttrain\tlinux\tno\tno\tno\tvmx"
  let original = try #require(reference(row + "\tstorage=nvme,virtio-blk"))
  let dropped = try #require(reference(row + "\tstorage=nvme"))
  _ = try #require(archiveID(root.path, [original], create: true))
  #expect(archiveID(root.path, [dropped], create: false) == nil)
  let inventory = root.appendingPathComponent("inventory")
  try Data(row.utf8).write(to: inventory)
  let archive = root.appendingPathComponent("legacy")
  #expect(run([inventory.path, archive.path, "/usr/bin/true"]) == 1)
  #expect(
    !FileManager.default.fileExists(atPath: archive.appendingPathComponent("board.plan.tsv").path))
}
