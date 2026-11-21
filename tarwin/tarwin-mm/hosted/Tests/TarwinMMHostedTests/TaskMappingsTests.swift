import Darwin
import TarwinMMHosted
import TarwinTaskProtocol
import Testing

@Test func wireMapSendsANarrowedCapabilityAndPrivateCopy() throws {
  let page = hostedPageSize
  let entry = try HostedMemoryEntry.anonymous(size: 2 * page)
  let original = try entry.mapLocally(protection: [.read, .write])
  try [UInt8(21)].withUnsafeBytes { try original.write($0, offset: page) }
  let command = try HostedMapCommand(
    address: 4 * page, size: page, entryOffset: page, entry: entry,
    protection: [.read, .write], copy: true)
  let transport = HostedTaskCommandMappings { wire, right in
    let port = try #require(right)
    guard case .map(let mapping) = wire else {
      Issue.record("expected map")
      return TaskCommandReply(status: KERN_INVALID_ARGUMENT)
    }
    #expect(mapping.address == command.address)
    #expect(mapping.length == page)
    #expect(mapping.offset == 0)
    #expect(mapping.copy)
    let rw = VM_PROT_READ | VM_PROT_WRITE
    var address: UInt64 = 0
    let result = mach_vm_map(
      mach_task_self_, &address, page, 0, VM_FLAGS_ANYWHERE, port, 0, 0, rw, rw, VM_INHERIT_NONE)
    #expect(result == KERN_SUCCESS)
    guard result == KERN_SUCCESS else { return TaskCommandReply(status: result) }
    defer { mach_vm_deallocate(mach_task_self_, address, page) }
    let bytes = try #require(UnsafeMutablePointer<UInt8>(bitPattern: UInt(address)))
    #expect(bytes.pointee == 21)
    bytes.pointee = 99
    var outside: UInt64 = 0
    #expect(mach_vm_map(
      mach_task_self_, &outside, page, 0, VM_FLAGS_ANYWHERE, port, page, 0, rw, rw,
      VM_INHERIT_NONE) != KERN_SUCCESS)
    return TaskCommandReply(status: KERN_SUCCESS)
  }
  try transport.map(command)
  try transport.map(command)
  #expect(UnsafeRawPointer(bitPattern: UInt(original.address + page))!.load(as: UInt8.self) == 21)
}
