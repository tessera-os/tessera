import Darwin
import Foundation
import libkern

public let hostedPageSize: UInt64 = 1 << 14

public struct HostedProtection: OptionSet, Sendable {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let read = Self(rawValue: VM_PROT_READ)
  public static let write = Self(rawValue: VM_PROT_WRITE)
  public static let execute = Self(rawValue: VM_PROT_EXECUTE)

  public var isValid: Bool {
    let known: Self = [.read, .write, .execute]
    return isSubset(of: known) && !isSuperset(of: [.write, .execute])
  }
}

public enum HostedMemoryError: Error, Equatable {
  case unsupportedHost
  case invalidRange
  case invalidProtection
  case rollbackFailed
  case notPurgeable
  case posix(Int32)
  case mach(kern_return_t)
}

func checkMach(_ code: kern_return_t) throws {
  guard code == KERN_SUCCESS else { throw HostedMemoryError.mach(code) }
}

public enum HostedPurgeState: Equatable, Sendable {
  case nonvolatile, volatile, empty
}

public final class HostedMemoryEntry {
  private final class Identity {}

  public let port: mach_port_t
  public let size: UInt64
  public let protection: HostedProtection
  private let object: Identity
  let objectOffset: UInt64
  var objectID: ObjectIdentifier { ObjectIdentifier(object) }

  private init(
    port: mach_port_t, size: UInt64, protection: HostedProtection, object: Identity,
    objectOffset: UInt64
  ) {
    self.port = port
    self.size = size
    self.protection = protection
    self.object = object
    self.objectOffset = objectOffset
  }

  deinit { mach_port_deallocate(mach_task_self_, port) }

  public static func anonymous(size: UInt64, purgeable: Bool = false) throws -> HostedMemoryEntry {
    let rw: HostedProtection = [.read, .write]
    let flags = MAP_MEM_NAMED_CREATE | (purgeable ? MAP_MEM_PURGABLE : 0)
    return try make(size: size, offset: 0, protection: rw, flags: flags, parent: 0)
  }

  public func restricted(to protection: HostedProtection) throws -> HostedMemoryEntry {
    try restricted(to: protection, offset: 0, size: size)
  }

  public func restricted(
    to protection: HostedProtection, offset: UInt64, size: UInt64
  ) throws -> HostedMemoryEntry {
    guard offset % hostedPageSize == 0, offset <= self.size, size <= self.size - offset else {
      throw HostedMemoryError.invalidRange
    }
    guard protection.isSubset(of: self.protection) else { throw HostedMemoryError.invalidProtection }
    if protection == self.protection && offset == 0 && size == self.size { return self }
    return try Self.make(
      size: size, offset: offset, protection: protection, flags: 0, parent: port,
      object: object, objectOffset: objectOffset + offset)
  }

  public static func sealedCode(
    size: UInt64, verifiedBytes: UnsafeRawBufferPointer
  ) throws -> HostedMemoryEntry {
    #if !arch(arm64)
    throw HostedMemoryError.unsupportedHost
    #else
    guard getpagesize() == hostedPageSize else { throw HostedMemoryError.unsupportedHost }
    guard size > 0, size % hostedPageSize == 0, size <= UInt64(Int.max),
      !verifiedBytes.isEmpty, verifiedBytes.count <= Int(size), let source = verifiedBytes.baseAddress
    else { throw HostedMemoryError.invalidRange }
    let count = Int(size)
    let jit = mmap(nil, count, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0)
    guard let jit, jit != MAP_FAILED else { throw HostedMemoryError.posix(errno) }
    defer { munmap(jit, count) }
    pthread_jit_write_protect_np(0)
    jit.copyMemory(from: source, byteCount: verifiedBytes.count)
    sys_icache_invalidate(jit, count)
    pthread_jit_write_protect_np(1)
    guard mprotect(jit, count, PROT_READ | PROT_EXEC) == 0 else {
      throw HostedMemoryError.posix(errno)
    }
    return try make(
      size: size, offset: UInt64(UInt(bitPattern: jit)), protection: [.read, .execute],
      flags: MAP_MEM_VM_SHARE, parent: 0)
    #endif
  }

  public func privateCopy() throws -> HostedMemoryEntry {
    let mapping = try mapLocally(protection: protection)
    return try withExtendedLifetime(mapping) {
      try Self.make(
        size: size, offset: mapping.address, protection: protection, flags: MAP_MEM_VM_COPY,
        parent: 0)
    }
  }

  private static func make(
    size: UInt64, offset: UInt64, protection: HostedProtection, flags: Int32, parent: mach_port_t,
    object: Identity = Identity(), objectOffset: UInt64 = 0
  ) throws -> HostedMemoryEntry {
    #if !arch(arm64)
    throw HostedMemoryError.unsupportedHost
    #else
    guard getpagesize() == hostedPageSize else { throw HostedMemoryError.unsupportedHost }
    guard size > 0, size % hostedPageSize == 0 else { throw HostedMemoryError.invalidRange }
    guard protection.isValid, !protection.isEmpty else { throw HostedMemoryError.invalidProtection }
    var actual = size
    var port: mach_port_t = 0
    try checkMach(mach_make_memory_entry_64(
      mach_task_self_, &actual, offset, protection.rawValue | flags, &port, parent))
    guard actual == size else {
      mach_port_deallocate(mach_task_self_, port)
      throw HostedMemoryError.invalidRange
    }
    return HostedMemoryEntry(
      port: port, size: size, protection: protection, object: object, objectOffset: objectOffset)
    #endif
  }

  public func mapLocally(
    protection: HostedProtection, copy: Bool = false
  ) throws -> HostedLocalMapping {
    guard protection.isValid, protection.isSubset(of: self.protection) else {
      throw HostedMemoryError.invalidProtection
    }
    var address: UInt64 = 0
    try checkMach(mach_vm_map(
      mach_task_self_, &address, size, 0, VM_FLAGS_ANYWHERE, port, 0, copy ? 1 : 0,
      protection.rawValue, protection.rawValue, copy ? VM_INHERIT_COPY : VM_INHERIT_NONE))
    return HostedLocalMapping(address: address, size: size, protection: protection)
  }
}

public final class HostedLocalMapping {
  public let address: UInt64
  public let size: UInt64
  public let protection: HostedProtection

  fileprivate init(address: UInt64, size: UInt64, protection: HostedProtection) {
    self.address = address
    self.size = size
    self.protection = protection
  }

  deinit { mach_vm_deallocate(mach_task_self_, address, size) }

  public func write(_ bytes: UnsafeRawBufferPointer, offset: UInt64 = 0) throws {
    guard protection.contains(.write) else { throw HostedMemoryError.invalidProtection }
    guard offset <= size, UInt64(bytes.count) <= size - offset else {
      throw HostedMemoryError.invalidRange
    }
    guard let source = bytes.baseAddress, !bytes.isEmpty else { return }
    UnsafeMutableRawPointer(bitPattern: UInt(address + offset))!.copyMemory(
      from: source, byteCount: bytes.count)
  }
}

public final class HostedPurgeableMemory {
  public let entry: HostedMemoryEntry
  private let mapping: HostedLocalMapping
  private let lock = NSLock()

  public init(size: UInt64) throws {
    entry = try .anonymous(size: size, purgeable: true)
    mapping = try entry.mapLocally(protection: [.read, .write])
  }

  public func state() throws -> HostedPurgeState {
    try lock.withLock { try control(VM_PURGABLE_GET_STATE, state: 0) }
  }

  @discardableResult
  public func makeVolatile() throws -> HostedPurgeState {
    try lock.withLock { try control(VM_PURGABLE_SET_STATE, state: VM_PURGABLE_VOLATILE) }
  }

  public func makeNonvolatile() throws -> Bool {
    try lock.withLock { try control(VM_PURGABLE_SET_STATE, state: VM_PURGABLE_NONVOLATILE) != .empty }
  }

  @discardableResult
  public func discardIfVolatile() throws -> Bool {
    try lock.withLock {
      guard try control(VM_PURGABLE_GET_STATE, state: 0) == .volatile else { return false }
      return try control(VM_PURGABLE_SET_STATE, state: VM_PURGABLE_EMPTY) != .empty
    }
  }

  private func control(_ operation: vm_purgable_t, state: Int32) throws -> HostedPurgeState {
    var state = state
    try checkMach(mach_vm_purgable_control(mach_task_self_, mapping.address, operation, &state))
    switch state & VM_PURGABLE_STATE_MASK {
    case VM_PURGABLE_NONVOLATILE: return .nonvolatile
    case VM_PURGABLE_VOLATILE: return .volatile
    case VM_PURGABLE_EMPTY: return .empty
    default: throw HostedMemoryError.notPurgeable
    }
  }
}
