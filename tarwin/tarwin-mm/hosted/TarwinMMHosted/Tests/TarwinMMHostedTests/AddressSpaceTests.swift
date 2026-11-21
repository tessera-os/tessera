import Testing
import TarwinMMHosted

private enum TransportError: Error { case unavailable }

private final class TaskMappings: HostedTaskMappings {
  var commands: [HostedMapCommand] = []
  var fail = false

  func map(_ command: HostedMapCommand) throws {
    if fail { throw TransportError.unavailable }
    commands.append(command)
  }

  func unmap(address: UInt64, size: UInt64) throws {
    if fail { throw TransportError.unavailable }
    commands.removeAll { (address..<(address + size)).contains($0.address) }
  }
}

@Test func fileFaultCopiesOnlyAuthenticatedBytesAndCommitsAfterMap() throws {
  let page = hostedPageSize
  let task = TaskMappings()
  let space = try HostedAddressSpace(window: page..<(8 * page), task: task)
  var reads: [UInt64] = []
  let backing = HostedFileBacking(size: page + 1) { offset, buffer in
    reads.append(offset)
    buffer.initializeMemory(as: UInt8.self, repeating: 0xff)
    return offset == page ? 1 : buffer.count
  }
  try space.reserveFile(address: page, size: 2 * page, backing: backing, offset: 0, protection: .read)
  #expect(try space.fault(address: 2 * page, access: .write) == .protection)
  #expect(try space.fault(address: 3 * page, access: .read) == .unmapped)
  #expect(reads.isEmpty)
  task.fail = true
  #expect(throws: TransportError.unavailable) {
    try space.fault(address: 2 * page, access: .read)
  }
  #expect(space.footprint == 0)
  task.fail = false
  #expect(try space.fault(address: 2 * page + 10, access: .read) == .mapped)
  #expect(reads == [page, page])
  #expect(space.footprint == page)
  let entry = try #require(task.commands.first?.entry)
  #expect(entry.protection == .read)
  let mapping = try entry.mapLocally(protection: .read)
  let pointer = try #require(UnsafeRawPointer(bitPattern: UInt(mapping.address)))
  #expect(pointer.load(as: UInt8.self) == 0xff)
  #expect(pointer.load(fromByteOffset: 1, as: UInt8.self) == 0)
  task.fail = true
  #expect(throws: TransportError.unavailable) { try space.unmap(address: page, size: 2 * page) }
  #expect(space.footprint == page)
  task.fail = false
  try space.unmap(address: page, size: 2 * page)
  #expect(space.footprint == 0)
}

@Test func sharedReadOnlyFileFaultsUseOneEntryPerPage() throws {
  let page = hostedPageSize
  let task = TaskMappings()
  let space = try HostedAddressSpace(window: page..<(8 * page), task: task)
  var reads = 0
  let backing = HostedFileBacking(size: page) { _, buffer in
    reads += 1
    return buffer.count
  }
  try space.reserveFile(address: page, size: page, backing: backing, offset: 0, protection: .read)
  try space.reserveFile(address: 2 * page, size: page, backing: backing, offset: 0, protection: .read)
  #expect(try space.fault(address: page, access: .read) == .mapped)
  #expect(try space.fault(address: 2 * page, access: .read) == .mapped)
  #expect(reads == 1)
  #expect(task.commands[0].entry === task.commands[1].entry)
  #expect(space.footprint == page)
}

@Test func trfsFaultCombinesFourBlocksAndRejectsShortBlock() throws {
  let page = hostedPageSize
  let task = TaskMappings()
  let space = try HostedAddressSpace(window: page..<(4 * page), task: task)
  var blocks: [UInt64] = []
  var short = false
  let backing = HostedFileBacking.trfsSnapshot(size: page + 1) { index, buffer in
    blocks.append(index)
    buffer.initializeMemory(as: UInt8.self, repeating: UInt8(index + 1))
    if index == 4 { return short ? 0 : 1 }
    return buffer.count
  }
  try space.reserveFile(address: page, size: 2 * page, backing: backing, offset: 0, protection: .read)
  #expect(try space.fault(address: page, access: .read) == .mapped)
  short = true
  #expect(throws: HostedFaultError.incompleteRead) {
    try space.fault(address: 2 * page, access: .read)
  }
  #expect(space.footprint == page)
  short = false
  #expect(try space.fault(address: 2 * page, access: .read) == .mapped)
  #expect(blocks == [0, 1, 2, 3, 4, 4])
  let mapped = try task.commands[1].entry.mapLocally(protection: .read)
  let bytes = try #require(UnsafePointer<UInt8>(bitPattern: UInt(mapped.address)))
  #expect(bytes[0] == 5)
  #expect(bytes[1] == 0)
}

@Test func jetsamSignalsInBandOrderAndChoosesLargestEligibleVictim() {
  let processes = [
    HostedPressureProcess(id: 1, band: 0, footprint: 1000, limit: 1),
    HostedPressureProcess(id: 2, band: 5, footprint: 100, limit: 1),
    HostedPressureProcess(id: 3, band: 6, footprint: 20, limit: 1),
    HostedPressureProcess(id: 4, band: 6, footprint: 30, limit: 1),
  ]
  var signaled: [UInt64] = []
  var killed: [HostedJetsamEvent] = []
  let result = HostedJetsam.handle(
    .critical, processes: processes, signal: { id, _ in signaled.append(id) },
    reclaimed: { false }, terminate: { killed.append($0) })
  #expect(signaled == [3, 4, 2, 1])
  #expect(killed.map(\.process) == [4])
  #expect(result == killed.first.map(HostedJetsamResult.terminated))
  #expect(HostedJetsam.enforceLimit(of: processes[0], terminate: { _ in }) == .noAction)
  #expect(HostedJetsam.enforceLimit(of: processes[1], terminate: { killed.append($0) })
    == killed.last.map(HostedJetsamResult.terminated))
  #expect(killed.last?.reason == .footprintLimit)
  #expect(HostedJetsam.handle(
    .critical, processes: [processes[0]], signal: { _, _ in },
    reclaimed: { false }, terminate: { _ in }) == .noEligibleProcess)
}

@Test func pressureReclaimsOldestCleanFilePagesAndVolatileEntriesBeforeJetsam() throws {
  let page = hostedPageSize
  let task = TaskMappings()
  let space = try HostedAddressSpace(window: page..<(8 * page), task: task)
  var reads: [UInt64] = []
  let backing = HostedFileBacking(size: 3 * page) { offset, buffer in
    reads.append(offset)
    buffer.initializeMemory(as: UInt8.self, repeating: 42)
    return buffer.count
  }
  let volatile = try HostedPurgeableMemory(size: page)
  let protected = try HostedPurgeableMemory(size: page)
  let rw: HostedProtection = [.read, .write]
  try space.reserveFile(address: page, size: 2 * page, backing: backing, offset: 0, protection: .read)
  try space.reserveFile(address: 3 * page, size: page, backing: backing, offset: 2 * page, protection: rw)
  try space.map(.init(address: 4 * page, size: page, entry: volatile.entry, protection: rw))
  try space.map(.init(address: 5 * page, size: page, entry: protected.entry, protection: rw))
  #expect(try space.fault(address: 2 * page, access: .read) == .mapped)
  try volatile.makeVolatile()
  #expect(try space.fault(address: page, access: .read) == .mapped)
  #expect(try space.fault(address: 3 * page, access: .write) == .mapped)

  let spaces = [HostedPressureAddressSpace(id: 1, band: 6, limit: 0, space: space)]
  var signaled: [UInt64] = []
  var killed: [HostedJetsamEvent] = []
  func pressure(_ level: HostedMemoryPressure, enough: () -> Bool) throws -> HostedJetsamResult {
    try HostedJetsam.handle(level, addressSpaces: spaces,
      signal: { id, _ in signaled.append(id) }, reclaimed: enough, terminate: { killed.append($0) })
  }
  #expect(space.footprint == 5 * page)
  #expect(try pressure(.normal) { false } == .noAction)
  #expect(signaled.isEmpty)
  #expect(try pressure(.warning) { space.footprint <= 4 * page } == .noAction)
  #expect(!task.commands.contains { $0.address == 2 * page })
  #expect(task.commands.contains { $0.address == page })
  #expect(try volatile.state() == .volatile)
  #expect(space.occupiedRanges.contains { $0.contains(2 * page) })

  #expect(try pressure(.critical) { space.footprint <= 3 * page } == .noAction)
  #expect(try volatile.state() == .empty)
  #expect(task.commands.contains { $0.address == page })
  #expect(killed.isEmpty)

  #expect(try space.fault(address: 2 * page, access: .read) == .mapped)
  #expect(reads == [page, 0, 2 * page, page])
  let reloaded = try #require(task.commands.last).entry.mapLocally(protection: .read)
  let bytes = try #require(UnsafeRawPointer(bitPattern: UInt(reloaded.address)))
  #expect(bytes.load(as: UInt8.self) == 42)

  #expect(try pressure(.critical) { false } == killed.last.map(HostedJetsamResult.terminated))
  #expect(signaled == [1, 1, 1])
  #expect(killed.count == 1)
  #expect(killed.first?.footprint == 2 * page)
  #expect(try protected.state() == .nonvolatile)
  #expect(task.commands.contains { $0.address == 3 * page })
  #expect(try !volatile.makeNonvolatile())
  #expect(space.footprint == 3 * page)
}

@Test func failedPressureUnmapKeepsTheFilePageChargedAndCanBeRetried() throws {
  let page = hostedPageSize
  let task = TaskMappings()
  let space = try HostedAddressSpace(window: page..<(2 * page), task: task)
  try space.reserveFile(address: page, size: page,
    backing: HostedFileBacking(size: page) { _, buffer in buffer.count }, offset: 0, protection: .read)
  #expect(try space.fault(address: page, access: .read) == .mapped)
  let spaces = [HostedPressureAddressSpace(id: 1, band: 6, limit: 0, space: space)]
  func reclaim() throws -> HostedJetsamResult {
    try HostedJetsam.handle(.warning, addressSpaces: spaces,
      signal: { _, _ in }, reclaimed: { false }, terminate: { _ in Issue.record("unexpected jetsam") })
  }
  task.fail = true
  #expect(throws: TransportError.unavailable) { try reclaim() }
  #expect(space.footprint == page)
  #expect(try space.fault(address: page, access: .read) == .notPresentOnHost)
  task.fail = false
  #expect(try reclaim() == .noAction)
  #expect(space.footprint == 0)
  #expect(try space.fault(address: page, access: .read) == .mapped)
}
