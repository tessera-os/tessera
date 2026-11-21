import TarwinBlock
import TarwinBlockWire
import TarwinDevice
import TarwinIPC
import TarwinIoCompletion
import USBMassStorage
import XCTest

/// Test mappings are deliberately non-contiguous and start on odd offsets.
final class Grants: USBBlockGrants {
  let list = UnsafeMutableRawBufferPointer.allocate(byteCount: 32, alignment: 8)
  let data = UnsafeMutableRawBufferPointer.allocate(byteCount: 3072, alignment: 8)
  var toDisk = false
  private(set) var length = 0
  init() {
    list.initializeMemory(as: UInt8.self, repeating: 0)
    data.initializeMemory(as: UInt8.self, repeating: 0x6b)
  }
  func prepare(_ n: Int, write: Bool) -> BlockPayload {
    length = n
    toDisk = write
    list.storeBytes(of: UInt64(0x2001), as: UInt64.self)
    list.storeBytes(of: UInt32(317), toByteOffset: 8, as: UInt32.self)
    list.storeBytes(of: UInt64(0x8007), toByteOffset: 16, as: UInt64.self)
    list.storeBytes(of: UInt32(n - 317), toByteOffset: 24, as: UInt32.self)
    return BlockPayload(list: 0x1000, vectors: 2)
  }
  var buffers: [UnsafeMutableRawBufferPointer] {
    [.init(rebasing: data[11..<328]), .init(rebasing: data[501..<501 + length - 317])]
  }
  func readable(_ address: UInt64, count: Int) -> UnsafeRawBufferPointer? {
    if address == 0x1000 && count == 32 { return .init(list) }
    return toDisk ? buffer(address, count).map(UnsafeRawBufferPointer.init) : nil
  }
  func writable(_ address: UInt64, count: Int) -> UnsafeMutableRawBufferPointer? {
    !toDisk ? buffer(address, count) : nil
  }
  private func buffer(_ address: UInt64, _ count: Int) -> UnsafeMutableRawBufferPointer? {
    if address == 0x2001 && count == 317 { return buffers[0] }
    if address == 0x8007 && count == length - 317 { return buffers[1] }
    return nil
  }
  deinit {
    data.deallocate()
    list.deallocate()
  }
}

private struct Ports: IoPorts, ~Copyable {
  var port: CompletionPort, references = 0
  mutating func retainPort(_ k: UInt64) -> Bool {
    guard k == 1 else { return false }
    references += 1
    return true
  }
  mutating func withLockedPort(_ k: UInt64, _ visit: (inout CompletionPort) -> Void) {
    precondition(k == 1)
    visit(&port)
  }
  mutating func releasePort(_ k: UInt64) { references -= 1 }
  func wakePort(_ k: UInt64, count: Int) {}
}

final class BlockChannel {
  let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: 12288, alignment: 4096)
  let credits = UnsafeMutableBufferPointer<PortSlot>.allocate(capacity: 1)
  let slots = UnsafeMutableBufferPointer<BlockPortSlot>.allocate(capacity: 1)
  private var port: Ports, queue: PortBlockQueue, publish: RingEndpoint, consume: RingEndpoint
  private var reply: RingEndpoint, collect: RingEndpoint
  var service: USBBlockService
  init(_ disk: consuming USBDisk) throws {
    let m = IoRingMapping(initializing: memory, count: 64, stride: 64)!
    publish = m.endpoint(completion: false, producer: true)!
    consume = m.endpoint(completion: false, producer: false)!
    reply = m.endpoint(completion: true, producer: true)!
    collect = m.endpoint(completion: true, producer: false)!
    credits.initialize(repeating: PortSlot())
    slots.baseAddress!.initialize(to: BlockPortSlot())
    port = Ports(port: CompletionPort(storage: credits)!)
    queue = PortBlockQueue(
      capacity: disk.blocks, blockBytes: UInt32(disk.blockBytes),
      queueCount: 1, depth: 1, slots: slots)!
    service = try USBBlockService(consume disk, epoch: queue.epoch)
  }

  func run(_ op: BlockOp, _ lba: UInt64, _ n: UInt64, grants: Grants, payload: BlockPayload)
    throws -> PortPacket
  {
    var record = RingRecord()
    let cmd = BlockCommand(op: op, lba: lba, blocks: n, qos: .standard, queue: 0)
    let id = queue.submit(cmd, object: 3, key: 99, port: 1, ports: &port)
    guard id != 0,
      case .ring(.transferred) = queue.publish(
        queue: 0,
        payload: { _, _ in payload }, ring: &publish),
      case .transferred = consume.pop(into: &record),
      let response = service.execute(record, grants: grants),
      case .transferred = reply.push(response.record()),
      case .transferred = collect.pop(into: &record),
      queue.receive(queue: 0, record: record) == id,
      queue.release(id: id, at: 10, ports: &port, retireBuffers: { $0 == id }),
      let p = port.port.take(), p.key == 99, p.kind == 3, port.references == 0
    else { throw StorageError.transport }
    return p
  }
  deinit {
    slots.deinitialize()
    slots.deallocate()
    credits.deinitialize()
    credits.deallocate()
    memory.deallocate()
  }
}
