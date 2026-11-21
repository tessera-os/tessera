import Darwin
import Testing
import TarwinMMHosted

@Test func restrictedEntryUsesSamePagesWithoutGrantingWrite() throws {
  let entry = try HostedMemoryEntry.anonymous(size: hostedPageSize)
  let writer = try entry.mapLocally(protection: [.read, .write])
  let readOnly = try entry.restricted(to: .read)
  let reader = try readOnly.mapLocally(protection: .read)
  try [UInt8(42)].withUnsafeBytes { try writer.write($0) }
  #expect(UnsafeRawPointer(bitPattern: UInt(reader.address))!.load(as: UInt8.self) == 42)
  #expect(throws: HostedMemoryError.invalidProtection) {
    try readOnly.mapLocally(protection: [.read, .write])
  }
  var address: UInt64 = 0
  #expect(mach_vm_map(
    mach_task_self_, &address, hostedPageSize, 0, VM_FLAGS_ANYWHERE, readOnly.port, 0, 0,
    VM_PROT_READ, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE) != KERN_SUCCESS)
  #expect(mach_vm_protect(
    mach_task_self_, reader.address, hostedPageSize, 0, VM_PROT_READ | VM_PROT_WRITE)
    == KERN_PROTECTION_FAILURE)
}

@Test func privateMappingDoesNotChangeTemplate() throws {
  let entry = try HostedMemoryEntry.anonymous(size: hostedPageSize)
  let original = try entry.mapLocally(protection: [.read, .write])
  try [UInt8(7)].withUnsafeBytes { try original.write($0) }
  let copy = try entry.mapLocally(protection: [.read, .write], copy: true)
  try [UInt8(8)].withUnsafeBytes { try copy.write($0) }
  #expect(UnsafeRawPointer(bitPattern: UInt(original.address))!.load(as: UInt8.self) == 7)
  #expect(UnsafeRawPointer(bitPattern: UInt(copy.address))!.load(as: UInt8.self) == 8)
}

@Test func purgeableMemoryReportsDiscardOnce() throws {
  let memory = try HostedPurgeableMemory(size: hostedPageSize)
  let user = try memory.entry.mapLocally(protection: [.read, .write])
  try [UInt8(7)].withUnsafeBytes { try user.write($0) }
  #expect(try memory.state() == .nonvolatile)
  #expect(try !memory.discardIfVolatile())
  try memory.makeVolatile()
  #expect(try memory.state() == .volatile)
  #expect(try memory.discardIfVolatile())
  #expect(try memory.state() == .empty)
  #expect(try !memory.makeNonvolatile())
  #expect(try memory.makeNonvolatile())
  #expect(UnsafeRawPointer(bitPattern: UInt(user.address))!.load(as: UInt8.self) == 0)
}
