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
