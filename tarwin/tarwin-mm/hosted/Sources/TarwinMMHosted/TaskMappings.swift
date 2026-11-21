import Darwin
import TarwinTaskProtocol

public struct HostedTaskCommandMappings: HostedTaskMappings {
  public typealias Exchange = (TaskCommand, mach_port_t?) throws -> TaskCommandReply

  private let exchange: Exchange

  public init(exchange: @escaping Exchange) { self.exchange = exchange }

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
}
