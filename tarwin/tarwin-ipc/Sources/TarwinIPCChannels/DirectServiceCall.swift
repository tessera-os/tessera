import TarwinIPC
import TarwinObject
import TarwinSched

/// Kernel-private immutable input and pinned, disjoint per-thread output.
/// Handle names must already be captured in the thread's register-save area,
/// not a writable user alias. Both table writers are held in process order.
public struct ServiceMessage {
  let bytes: UnsafeRawBufferPointer
  let names: UnsafeBufferPointer<UInt64>
  public init(bytes: UnsafeRawBufferPointer, names: UnsafeBufferPointer<UInt64>) {
    self.bytes = bytes
    self.names = names
  }

  func deliver(
    to area: ServiceArea, sender: inout HandleTable, receiver: inout HandleTable,
    invalidate: (UInt64) -> Void
  ) -> Bool {
    guard bytes.count <= 128, names.count <= 4, bytes.count <= area.bytes.count,
      names.count <= area.names.count, receiver.owns(area.table), receiver.freeCount >= names.count
    else { return false }
    var i = 0
    guard
      case .allowed = sender.moveForChannel(
        names, invalidate: invalidate,
        take: { (g: consuming ObjectGrant) in
          guard case .installed(let name) = receiver.installMoved(g) else {
            preconditionFailure("receiver table changed under writer lock")
          }
          area.names[i] = name
          i += 1
        })
    else { return false }
    if bytes.count != 0 {
      area.bytes.baseAddress!.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
    }
    area.size.pointee = ChannelSize(bytes: bytes.count, handles: names.count)
    return true
  }
}

public struct ServiceArea {
  let bytes: UnsafeMutableRawBufferPointer
  let names: UnsafeMutableBufferPointer<UInt64>
  let size: UnsafeMutablePointer<ChannelSize>
  let table: HandleReadView
  /// Pin the area and its process table until withdrawal, reply or revocation.
  public init(
    bytes: UnsafeMutableRawBufferPointer, names: UnsafeMutableBufferPointer<UInt64>,
    size: UnsafeMutablePointer<ChannelSize>, table: borrowing HandleTable
  ) {
    self.bytes = bytes
    self.names = names
    self.size = size
    self.table = table.reader
  }
}

public struct WaitingService {
  let wait: BootstrapCPU.Receiver
  let area: ServiceArea
  public func withdraw(cpu: inout BootstrapCPU, now: UInt64) -> Bool {
    cpu.withdraw(wait, now: now)
  }
}

/// One transaction in the service owner's table. Closing either peer or
/// cancelling the call must revoke the loan before releasing either task.
public struct DirectServiceCall: ~Copyable {
  private let loan: BootstrapCPU.Donation
  private var call: ServiceCall
  private let replyArea: ServiceArea
  private let serverTable: HandleReadView
  init(
    loan: BootstrapCPU.Donation, transaction: UInt64, deadline: UInt64,
    replyArea: ServiceArea, serverTable: HandleReadView
  ) {
    self.loan = loan
    self.replyArea = replyArea
    self.serverTable = serverTable
    self.call = ServiceCall(
      transaction: transaction, deadline: deadline, context: loan.caller,
      server: loan.receiver.thread, state: .serving)
  }
  public var state: ServiceState { call.state }

  public mutating func reply(
    transaction: UInt64, channel: borrowing ChannelPair, now: UInt64, cpu: inout BootstrapCPU,
    message: ServiceMessage, sender: inout HandleTable,
    receiver: inout HandleTable, invalidate: (UInt64) -> Void
  ) -> Bool {
    guard let open = channel.serviceOpen(loan.receiver.service) else { return false }
    if !open {
      _ = cancel(peerClosed: true, now: now, cpu: &cpu)
      return false
    }
    if expire(now, cpu: &cpu) { return false }
    var next = call
    guard sender.owns(serverTable), next.reply(transaction, cpu.running, now),
      cpu.reply(
        loan, now: now,
        deliver: {
          message.deliver(
            to: replyArea, sender: &sender, receiver: &receiver, invalidate: invalidate)
        })
    else { return false }
    call = next
    return true
  }

  public mutating func expire(_ now: UInt64, cpu: inout BootstrapCPU) -> Bool {
    var next = call
    guard next.expire(now), cpu.revoke(loan, now: now) else { return false }
    call = next
    return true
  }

  public mutating func cancel(peerClosed: Bool, now: UInt64, cpu: inout BootstrapCPU) -> Bool {
    var next = call
    guard next.cancel(peerClosed), cpu.revoke(loan, now: now) else { return false }
    call = next
    return true
  }
}
