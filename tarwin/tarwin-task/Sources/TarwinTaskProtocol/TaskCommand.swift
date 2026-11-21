/// The Mach header and (for map) the memory-entry descriptor precede this payload.
public enum TaskCommand: Sendable {
  case map(TaskMapping)
  case protect(address: UInt64, length: UInt64, protection: UInt32)
  case unmap(address: UInt64, length: UInt64)
  case createThread(id: UInt64, entry: UInt64, argument: UInt64, stack: UInt64, tls: UInt64)
  case setThreadState(id: UInt64, state: TaskThreadState)
  case suspendThread(id: UInt64)
  case resumeThread(id: UInt64)
  case terminate
  case snapshot(address: UInt64, size: UInt64)

  public enum Opcode: UInt32, Sendable {
    case map = 1
    case protect = 2
    case unmap = 3
    case createThread = 4
    case setThreadState = 5
    case suspendThread = 6
    case resumeThread = 7
    case terminate = 8
    case snapshot = 9

    public var byteCount: Int {
      switch self {
      case .map: 40
      case .protect: 32
      case .unmap, .snapshot: 24
      case .createThread: 48
      case .setThreadState: 288
      case .suspendThread, .resumeThread: 16
      case .terminate: 8
      }
    }

    public var carriesMemoryEntry: Bool { self == .map }
  }

  public static let version: UInt32 = 1
  public static let messageID: Int32 = 0x5457_0101
  public static let maximumByteCount = 288

  public var opcode: Opcode {
    switch self {
    case .map: .map
    case .protect: .protect
    case .unmap: .unmap
    case .createThread: .createThread
    case .setThreadState: .setThreadState
    case .suspendThread: .suspendThread
    case .resumeThread: .resumeThread
    case .terminate: .terminate
    case .snapshot: .snapshot
    }
  }

  public init?(decoding bytes: UnsafeRawBufferPointer) {
    guard bytes.count >= 8, read32(bytes, 0) == Self.version,
      let opcode = Opcode(rawValue: read32(bytes, 4)), bytes.count == opcode.byteCount
    else { return nil }

    switch opcode {
    case .map:
      let flags = read32(bytes, 36)
      guard flags <= 1 else { return nil }
      self = .map(TaskMapping(
        address: read64(bytes, 8), length: read64(bytes, 16), offset: read64(bytes, 24),
        protection: read32(bytes, 32), copy: flags == 1))
    case .protect:
      guard read32(bytes, 28) == 0 else { return nil }
      self = .protect(
        address: read64(bytes, 8), length: read64(bytes, 16), protection: read32(bytes, 24))
    case .unmap:
      self = .unmap(address: read64(bytes, 8), length: read64(bytes, 16))
    case .createThread:
      self = .createThread(
        id: read64(bytes, 8), entry: read64(bytes, 16), argument: read64(bytes, 24),
        stack: read64(bytes, 32), tls: read64(bytes, 40))
    case .setThreadState:
      guard read32(bytes, 284) == 0 else { return nil }
      var registers = InlineArray<31, UInt64>(repeating: 0)
      for i in 0..<31 { registers[i] = read64(bytes, 16 + 8 * i) }
      self = .setThreadState(
        id: read64(bytes, 8), state: TaskThreadState(
          registers: registers, stack: read64(bytes, 264), pc: read64(bytes, 272),
          cpsr: read32(bytes, 280)))
    case .suspendThread:
      self = .suspendThread(id: read64(bytes, 8))
    case .resumeThread:
      self = .resumeThread(id: read64(bytes, 8))
    case .terminate:
      self = .terminate
    case .snapshot:
      self = .snapshot(address: read64(bytes, 8), size: read64(bytes, 16))
    }
  }

  /// Encodes into the exact payload slice; no Mach padding or trailer is included.
  public func encode(into bytes: UnsafeMutableRawBufferPointer) -> Bool {
    let opcode = self.opcode
    guard bytes.count == opcode.byteCount else { return false }
    write(Self.version, bytes, 0)
    write(opcode.rawValue, bytes, 4)

    switch self {
    case .map(let mapping):
      write(mapping.address, bytes, 8)
      write(mapping.length, bytes, 16)
      write(mapping.offset, bytes, 24)
      write(mapping.protection, bytes, 32)
      write(UInt32(mapping.copy ? 1 : 0), bytes, 36)
    case .protect(let address, let length, let protection):
      write(address, bytes, 8)
      write(length, bytes, 16)
      write(protection, bytes, 24)
      write(UInt32(0), bytes, 28)
    case .unmap(let address, let length), .snapshot(let address, let length):
      write(address, bytes, 8)
      write(length, bytes, 16)
    case .createThread(let id, let entry, let argument, let stack, let tls):
      write(id, bytes, 8)
      write(entry, bytes, 16)
      write(argument, bytes, 24)
      write(stack, bytes, 32)
      write(tls, bytes, 40)
    case .setThreadState(let id, let state):
      write(id, bytes, 8)
      for i in 0..<31 { write(state.registers[i], bytes, 16 + 8 * i) }
      write(state.stack, bytes, 264)
      write(state.pc, bytes, 272)
      write(state.cpsr, bytes, 280)
      write(UInt32(0), bytes, 284)
    case .suspendThread(let id), .resumeThread(let id):
      write(id, bytes, 8)
    case .terminate:
      break
    }
    return true
  }
}

public struct TaskMapping: Sendable {
  public let address, length, offset: UInt64
  public let protection: UInt32
  public let copy: Bool

  public init(address: UInt64, length: UInt64, offset: UInt64, protection: UInt32, copy: Bool) {
    self.address = address
    self.length = length
    self.offset = offset
    self.protection = protection
    self.copy = copy
  }
}

public struct TaskThreadState: Sendable {
  public let registers: InlineArray<31, UInt64>
  public let stack, pc: UInt64
  public let cpsr: UInt32

  public init(registers: InlineArray<31, UInt64>, stack: UInt64, pc: UInt64, cpsr: UInt32) {
    self.registers = registers
    self.stack = stack
    self.pc = pc
    self.cpsr = cpsr
  }
}

public struct TaskCommandReply: Sendable {
  public static let messageID: Int32 = 0x5457_0102
  public static let byteCount = 8
  public let status: Int32
  /// An owned send right on a successful snapshot reply. The caller deallocates it.
  public let memoryEntry: UInt32?

  public init(status: Int32, memoryEntry: UInt32? = nil) {
    self.status = status
    self.memoryEntry = memoryEntry
  }

  public init?(decoding bytes: UnsafeRawBufferPointer) {
    guard bytes.count == Self.byteCount, read32(bytes, 0) == TaskCommand.version else { return nil }
    self.init(status: Int32(bitPattern: read32(bytes, 4)))
  }

  public func encode(into bytes: UnsafeMutableRawBufferPointer) -> Bool {
    guard bytes.count == Self.byteCount else { return false }
    write(TaskCommand.version, bytes, 0)
    write(UInt32(bitPattern: status), bytes, 4)
    return true
  }
}

private func read32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
  UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
}

private func read64(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
  UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
}

private func write<T: FixedWidthInteger>(
  _ word: T, _ bytes: UnsafeMutableRawBufferPointer, _ offset: Int
) {
  for i in 0..<MemoryLayout<T>.size {
    bytes[offset + i] = UInt8(truncatingIfNeeded: word >> (8 * i))
  }
}
