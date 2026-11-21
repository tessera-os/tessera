import Darwin
import Foundation
import TarwinTaskProtocol
import TarwinTaskTransport

public struct HostedTaskCommandMappings: HostedTaskMappings, HostedLiveMemoryAccess {
  public typealias Exchange = (TaskCommand, mach_port_t?) throws -> TaskCommandReply

  private let exchange: Exchange
  private let liveRead: ((UInt64, UnsafeMutableRawBufferPointer) throws -> Void)?
  private let liveWrite: ((UInt64, UnsafeRawBufferPointer) throws -> Void)?

  public init(exchange: @escaping Exchange) {
    self.exchange = exchange
    liveRead = nil
    liveWrite = nil
  }

  public init(
    task: SpawnedTask, timeout: mach_msg_timeout_t = 5_000,
    onTransportFailure: @escaping (TaskTransportError) -> Void
  ) {
    exchange = { command, entry in
      switch task.command(command, memoryEntry: entry ?? 0, timeout: timeout) {
      case .success(let reply): return reply
      case .failure(let error):
        onTransportFailure(error)
        throw error
      }
    }
    func accept(_ result: Result<Void, TaskTransportError>) throws {
      if case .failure(let error) = result {
        if case .mach(let status) = error, status >= 0 && status < KERN_RETURN_MAX {
          throw HostedMemoryError.mach(status)
        }
        onTransportFailure(error)
        throw error
      }
    }
    liveRead = { address, buffer in
      try accept(task.readMemory(address: address, into: buffer, timeout: timeout))
    }
    liveWrite = { address, bytes in
      try accept(task.writeMemory(address: address, data: bytes, timeout: timeout))
    }
  }

  public func map(_ command: HostedMapCommand) throws {
    let view = try command.entry.restricted(
      to: command.protection, offset: command.entryOffset, size: command.size)
    let entry = command.copy ? try view.privateCopy() : view
    try withExtendedLifetime(entry) {
      try checkMach(exchange(
        .map(TaskMapping(
          address: command.address, length: command.size, offset: 0,
          protection: UInt32(bitPattern: command.protection.rawValue), copy: command.copy)),
        entry.port).status)
    }
  }

  public func unmap(address: UInt64, size: UInt64) throws {
    try checkMach(exchange(.unmap(address: address, length: size), nil).status)
  }

  public func snapshot(address: UInt64, size: UInt64) throws -> HostedMemoryEntry {
    guard size > 0, size % hostedPageSize == 0, address % hostedPageSize == 0,
      address <= UInt64.max - size
    else { throw HostedMemoryError.invalidRange }
    let reply = try exchange(.snapshot(address: address, size: size), nil)
    try checkMach(reply.status)
    guard let port = reply.memoryEntry, port != 0 else { throw HostedMemoryError.snapshotUnavailable }
    return .adoptSnapshot(port: port, size: size)
  }

  func readMemory(address: UInt64, size: Int) throws -> Data {
    guard let liveRead else { throw HostedMemoryError.liveMemoryUnavailable }
    var data = Data(count: size)
    try data.withUnsafeMutableBytes { bytes in
      try transferRanges(size) { range in
        try liveRead(address + UInt64(range.lowerBound),
          UnsafeMutableRawBufferPointer(rebasing: bytes[range]))
      }
    }
    return data
  }

  func writeMemory(address: UInt64, data: Data) throws {
    guard let liveWrite else { throw HostedMemoryError.liveMemoryUnavailable }
    try data.withUnsafeBytes { bytes in
      try transferRanges(bytes.count) { range in
        try liveWrite(address + UInt64(range.lowerBound),
          UnsafeRawBufferPointer(rebasing: bytes[range]))
      }
    }
  }

  private func transferRanges(_ size: Int, _ body: (Range<Int>) throws -> Void) rethrows {
    var offset = 0
    while offset < size {
      let end = offset + min(size - offset, Int(TaskMemoryTransfer.maximumSize))
      try body(offset..<end)
      offset = end
    }
  }
}
