import Foundation
import TarwinABI
import TarwinIPCChannels
import TarwinObject
import TarwinSync
import TarwinTime

final class Arena {
  private var cleanup: [() -> Void] = []
  func raw(count: Int, alignment: Int = 16) -> UnsafeMutableRawBufferPointer {
    let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: alignment)
    bytes.initializeMemory(as: UInt8.self, repeating: 0)
    cleanup.append { bytes.deallocate() }
    return bytes
  }
  func store<T: ~Copyable>(_ value: consuming T) -> UnsafeMutablePointer<T> {
    let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
    p.initialize(to: value)
    cleanup.append { p.deinitialize(count: 1); p.deallocate() }
    return p
  }
  func uninitialized<T: ~Copyable>(_ type: T.Type, count: Int) -> UnsafeMutableBufferPointer<T> {
    let p = UnsafeMutablePointer<T>.allocate(capacity: count)
    cleanup.append { p.deallocate() }
    return .init(start: p, count: count)
  }
  func initialized<T>(_ value: T, count: Int) -> UnsafeMutableBufferPointer<T> {
    let buffer = uninitialized(T.self, count: count)
    buffer.initialize(repeating: value)
    cleanup.append { buffer.deinitialize() }
    return buffer
  }
  deinit { for release in cleanup.reversed() { release() } }
}

final class KernelProcess {
  let name: String
  let table: UnsafeMutablePointer<HandleTable>
  var buffers: [TarwindKernelBuffer] = []
  init(name: String, arena: Arena, salt: UInt8) {
    self.name = name
    let cells = arena.uninitialized(HandleCell.self, count: 256)
    table = arena.store(HandleTable(storage: cells, salt: salt)!)
    self.cells = cells
  }
  private let cells: UnsafeMutableBufferPointer<HandleCell>
  deinit { table.pointee.drain { _ in }; cells.deinitialize() }
  func span(_ address: UInt64, count: UInt64) -> UnsafeMutableRawBufferPointer? {
    if count == 0 { return .init(start: nil, count: 0) }
    for buffer in buffers where address >= buffer.address {
      let offset = address - buffer.address
      if offset <= UInt64(buffer.count), count <= UInt64(buffer.count) - offset {
        return .init(rebasing: buffer.bytes[Int(offset)..<Int(offset + count)])
      }
    }
    return nil
  }
}

final class PendingCall {
  let id: TarwindContinuationID
  let process: TarwindProcessID
  let ticket: SleepTicket
  let object: UnsafePointer<ObjectHeader>?
  let mask: UInt32
  let name: UInt64
  var timer: TimerKey?
  init(id: TarwindContinuationID, process: TarwindProcessID, ticket: SleepTicket,
    object: UnsafePointer<ObjectHeader>?, mask: UInt32, name: UInt64) {
    self.id = id; self.process = process; self.ticket = ticket
    self.object = object; self.mask = mask; self.name = name
  }
}

final class WaitStorage {
  let queue = UnsafeMutablePointer<AddressQueue>.allocate(capacity: 1)
  private let buckets = UnsafeMutablePointer<AddressBucket>.allocate(capacity: 16)
  private let sleepers = UnsafeMutablePointer<AddressSleeper>.allocate(capacity: 64)
  init() {
    for i in 0..<16 { (buckets + i).initialize(to: AddressBucket()) }
    for i in 0..<64 { (sleepers + i).initialize(to: AddressSleeper()) }
    queue.initialize(to: AddressQueue(buckets: .init(start: buckets, count: 16),
      sleepers: .init(start: sleepers, count: 64), pageBytes: 4096)!)
  }
  deinit {
    queue.deinitialize(count: 1); queue.deallocate()
    buckets.deinitialize(count: 16); buckets.deallocate()
    sleepers.deinitialize(count: 64); sleepers.deallocate()
  }
}
