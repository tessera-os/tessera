import Darwin
import TarwinTaskProtocol
import TarwinTaskTransport

public struct HostedTaskCommandMappings: HostedTaskMappings {
  public typealias Exchange = (TaskCommand, mach_port_t?) throws -> TaskCommandReply

  private let exchange: Exchange

  public init(exchange: @escaping Exchange) { self.exchange = exchange }

  public init(
    task: SpawnedTask, timeout: mach_msg_timeout_t = 5_000,
    onTransportFailure: @escaping (TaskTransportError) -> Void
  ) {
    self.init { command, entry in
      switch task.command(command, memoryEntry: entry ?? 0, timeout: timeout) {
      case .success(let reply): return reply
      case .failure(let error):
        onTransportFailure(error)
        throw error
      }
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
}
