import Foundation
import TRFSHosted
import TarwinMMHosted
import Testing

private final class TrfsTaskMappings: HostedTaskMappings {
  var commands: [HostedMapCommand] = []
  func map(_ command: HostedMapCommand) throws { commands.append(command) }
  func unmap(address: UInt64, size: UInt64) throws {
    commands.removeAll { $0.address >= address && $0.address < address + size }
  }
}

@Test func liveTrfsSnapshotFaultMapsAuthenticatedPage() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("tarwin-live-trfs-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = try HostedTrfsDisk.imagePath(name: "System", home: directory.path)
  let disk = try HostedTrfsDisk.openData(path: path, blocks: 1 << 14)
  let file = try #require(disk.withVolume {
    $0.create(1, name: Array("code".utf8), kind: .file)
  })
  let expected = Array(repeating: UInt8(0x5a), count: 4096)
  try #require(disk.withVolume { volume in
    expected.withUnsafeBytes { volume.writePage(file, index: 0, bytes: $0) }
  })
  let root = try #require(disk.withVolume { $0.snapshot })
  let backing = HostedFileBacking.trfsSnapshot(size: 4096) { block, buffer in
    disk.withVolume { volume in
      volume.readPage(file, index: block, in: root, into: buffer) ?? 0
    }
  }
  let page = hostedPageSize
  let task = TrfsTaskMappings()
  let address = page
  let space = try HostedAddressSpace(window: page..<(3 * page), task: task)
  try space.reserveFile(
    address: address, size: page, backing: backing, offset: 0, protection: .read)
  #expect(try space.fault(address: address + 17, access: .read) == .mapped)
  let entry = try #require(task.commands.first?.entry)
  let mapped = try entry.mapLocally(protection: .read)
  let pointer = try #require(UnsafeRawPointer(bitPattern: UInt(mapped.address)))
  #expect(pointer.load(as: UInt8.self) == 0x5a)
  #expect(space.footprint == page)
}
