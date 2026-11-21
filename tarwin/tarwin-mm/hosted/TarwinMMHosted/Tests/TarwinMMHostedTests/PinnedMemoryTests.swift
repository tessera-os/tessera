import Foundation
import Testing

@testable import TarwinMMHosted

private enum GuestFailure: Error { case refused }

private final class LiveTask: HostedTaskMappings, HostedLiveMemoryAccess {
  private var ranges: [UInt64: HostedLocalMapping] = [:]
  var readCount = 0
  var writeCount = 0
  var shortRead = false

  func map(_ command: HostedMapCommand) throws {
    let entry = try command.entry.restricted(
      to: command.protection, offset: command.entryOffset, size: command.size)
    ranges[command.address] = try entry.mapLocally(protection: command.protection, copy: command.copy)
  }

  func unmap(address: UInt64, size: UInt64) throws {
    ranges = ranges.filter { !(address..<(address + size)).contains($0.key) }
  }

  func readMemory(address: UInt64, size: Int) throws -> Data {
    readCount += 1
    if shortRead { return Data() }
    var data = Data()
    try visit(address: address, size: size) { mapping, offset, count in
      let pointer = try #require(UnsafeRawPointer(bitPattern: UInt(mapping.address + offset)))
      data.append(contentsOf: UnsafeRawBufferPointer(start: pointer, count: count))
    }
    return data
  }

  func writeMemory(address: UInt64, data: Data) throws {
    writeCount += 1
    var used = 0
    try visit(address: address, size: data.count) { mapping, offset, count in
      try data.withUnsafeBytes {
        try mapping.write(UnsafeRawBufferPointer(rebasing: $0[used..<(used + count)]), offset: offset)
      }
      used += count
    }
  }

  private func visit(address: UInt64, size: Int,
    _ body: (HostedLocalMapping, UInt64, Int) throws -> Void
  ) throws {
    var cursor = address
    var remaining = size
    while remaining > 0 {
      guard let (base, mapping) = ranges.first(where: {
        cursor >= $0.key && cursor - $0.key < $0.value.size
      }) else { throw GuestFailure.refused }
      let offset = cursor - base
      let count = Int(min(UInt64(remaining), mapping.size - offset))
      try body(mapping, offset, count)
      remaining -= count
      cursor += UInt64(count)
    }
  }
}

@Test func guestCopyChecksTheEntireRangeAndUsesTheLiveCOWMapping() throws {
  let page = hostedPageSize
  let task = LiveTask()
  let space = try HostedAddressSpace(window: page..<(5 * page), task: task)
  let seed = try HostedMemoryEntry.anonymous(size: 2 * page)
  let shared = try seed.mapLocally(protection: [.read, .write])
  try Data([11, 12]).withUnsafeBytes { try shared.write($0, offset: 2 * page - 2) }
  try space.map(.init(address: page, size: page, entryOffset: page, entry: seed,
    protection: [.read, .write], copy: true))
  let ro = try HostedMemoryEntry.anonymous(size: page)
  try space.map(.init(address: 2 * page, size: page, entry: ro, protection: .read))
  let wo = try HostedMemoryEntry.anonymous(size: page)
  try space.map(.init(address: 3 * page, size: page, entry: wo, protection: .write))
  #expect(try space.copyIn(at: 2 * page - 2, count: 3) == Data([11, 12, 0]))
  #expect(throws: HostedMemoryError.invalidProtection) {
    try space.copyOut(Data([21, 22]), to: 2 * page - 1)
  }
  #expect(throws: HostedMemoryError.invalidProtection) {
    try space.copyIn(at: 3 * page, count: 1)
  }
  #expect(throws: HostedMemoryError.invalidRange) { try space.copyIn(at: 4 * page, count: 1) }
  #expect(throws: HostedMemoryError.invalidRange) { try space.copyIn(at: UInt64.max, count: 1) }
  #expect(throws: HostedMemoryError.invalidRange) { try space.copyIn(at: page, count: -1) }
  #expect(try space.copyIn(at: 5 * page, count: 0).isEmpty)
  #expect(task.writeCount == 0)
  #expect(task.readCount == 1)
  try space.copyOut(Data([31, 32]), to: 2 * page - 2)
  #expect(try space.copyIn(at: 2 * page - 2, count: 2) == Data([31, 32]))
  let pointer = try #require(UnsafeRawPointer(bitPattern: UInt(shared.address + 2 * page - 2)))
  #expect(Data(bytes: pointer, count: 2) == Data([11, 12]))
}

@Test func guestCopyFaultsInAndPinsCleanAndPurgeableMappingsUntilTheScopeEnds() throws {
  let page = hostedPageSize
  let task = LiveTask()
  let space = try HostedAddressSpace(window: page..<(4 * page), task: task)
  let purgeable = try HostedPurgeableMemory(size: page)
  try space.map(.init(address: 2 * page, size: page, entry: purgeable.entry,
    protection: [.read, .write]))
  try space.copyOut(Data([24]), to: 2 * page)
  try purgeable.makeVolatile()
  var reads = 0
  let backing = HostedFileBacking(size: page) { _, buffer in
    reads += 1
    buffer.initializeMemory(as: UInt8.self, repeating: 42)
    return buffer.count
  }
  try space.reserveFile(address: page, size: page, backing: backing, offset: 0, protection: .read)
  func pressure() throws -> HostedJetsamResult {
    try HostedJetsam.handle(.warning, addressSpaces: [.init(id: 1, band: 6, limit: 0, space: space)],
      signal: { _, _ in }, reclaimed: { false }, terminate: { _ in Issue.record("unexpected jetsam") })
  }
  #expect(reads == 0)
  func checkPinned(_ bytes: UnsafeRawBufferPointer) throws {
    #expect(Array(bytes) == [42, 24])
    #expect(reads == 1)
    #expect(try pressure() == .noAction)
    #expect(try purgeable.state() == .nonvolatile)
    #expect(try !purgeable.discardIfVolatile())
    #expect(throws: HostedMemoryError.pinned) { try space.unmap(address: page, size: page) }
    #expect(space.footprint == 2 * page)
    throw GuestFailure.refused
  }
  #expect(throws: GuestFailure.refused) { try space.withPinned(at: 2 * page - 1, count: 2, checkPinned) }
  #expect(try purgeable.state() == .volatile)
  #expect(try pressure() == .noAction)
  #expect(space.footprint == 0)
  #expect(try space.copyIn(at: page, count: 1) == Data([42]))
  #expect(reads == 2)
  task.shortRead = true
  #expect(throws: HostedFaultError.incompleteRead) { try space.copyIn(at: page, count: 1) }
  #expect(try pressure() == .noAction)
  #expect(space.footprint == 0)
}
