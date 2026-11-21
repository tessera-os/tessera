import TarwinBlock
import TarwinBlockWire
import TarwinDevice
import TarwinIPC

/// Single-client, depth-one hosted A.4 queue shared by disk model checks.
final class BlockChannel {
  private let memory = UnsafeMutableRawBufferPointer.allocate(
    byteCount: 4096 + 8192, alignment: 4096)
  private let credits = UnsafeMutableBufferPointer<PortSlot>.allocate(capacity: 1)
  private let bindings = UnsafeMutableBufferPointer<BlockPortSlot>.allocate(capacity: 1)
  private var scheduler: PortBlockQueue, user: TestClient
  var epoch: UInt64 { scheduler.epoch }
  var notifications: Int { user.notifications }
  private var requests: RingEndpoint, service: RingEndpoint, replies: RingEndpoint,
    client: RingEndpoint
  init(capacity: UInt64, blockBytes: UInt32) {
    let m = IoRingMapping(initializing: memory, count: 64, stride: 64)!
    requests = m.endpoint(completion: false, producer: true)!
    service = m.endpoint(completion: false, producer: false)!
    replies = m.endpoint(completion: true, producer: true)!
    client = m.endpoint(completion: true, producer: false)!
    credits.initialize(repeating: PortSlot())
    bindings.baseAddress!.initialize(to: BlockPortSlot())
    user = TestClient(port: CompletionPort(storage: credits)!)
    scheduler = PortBlockQueue(
      capacity: capacity, blockBytes: blockBytes, queueCount: 1, depth: 1, slots: bindings)!
  }
  func request(
    _ command: BlockCommand, key: UInt64, payload: BlockPayload, record: inout RingRecord
  ) throws -> UInt64 {
    let id = scheduler.submit(command, object: 2, key: key, port: 1, ports: &user)
    guard id != 0,
      case .ring(.transferred) = scheduler.publish(
        queue: 0, payload: { _, _ in payload }, ring: &requests),
      case .transferred = service.pop(into: &record)
    else { throw Failure("Block request did not reach driver ring") }
    return id
  }
  func finish(
    _ done: BlockCompletion, id: UInt64, key: UInt64, bytes: UInt64, retire: (UInt64) -> Bool
  ) throws {
    var record = RingRecord()
    guard case .transferred = replies.push(done.record()),
      case .transferred = client.pop(into: &record),
      scheduler.receive(queue: 0, record: record) == id,
      scheduler.release(id: id, at: 77, ports: &user, retireBuffers: retire),
      let packet = user.port.take(), packet.kind == 3, packet.key == key, packet.error == 0,
      packet.result0 == bytes,
      user.references == 0
    else { throw Failure("Block completion did not reach client port") }
  }
  deinit {
    bindings.deinitialize()
    bindings.deallocate()
    credits.deinitialize()
    credits.deallocate()
    memory.deallocate()
  }
}
