import Dispatch
import Synchronization
import XCTest

@testable import TarwinDevice

// Each worker owns one private lane; only pinned atomic ring fields and
// latched wake events cross threads. Lifetime spans the synchronous join.
private final class Exchange: @unchecked Sendable {
  let memory: UnsafeMutableRawBufferPointer
  let pair: IoRingMapping, failed = Atomic(false)
  let data = DispatchSemaphore(value: 0), space = DispatchSemaphore(value: 0)
  init() {
    memory = .allocate(byteCount: 4096 + 16384, alignment: 4096)
    precondition(IoRingMapping.initialize(memory, count: 64, stride: 128))
    pair = IoRingMapping(attaching: memory)!
  }
  deinit { memory.deallocate() }
  func transfer(_ producer: Bool) {
    var lane = pair.lane(completion: false, producer: producer)
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 128) { row in
      row.initialize(repeating: 0)
      defer { row.deinitialize() }
      var index = 0
      while index < 8192 && !failed.load(ordering: .relaxed) {
        if producer { for j in row.indices { row[j] = UInt8(truncatingIfNeeded: index + j) } }
        switch lane.transfer(row, signal: { _ = (producer ? data : space).signal() }) {
        case .transferred:
          if !producer {
            for j in row.indices where row[j] != UInt8(truncatingIfNeeded: index + j) {
              failed.store(true, ordering: .relaxed)
              return
            }
          }
          index += 1
        case .wait:
          switch lane.arm() {
          case .ready: break
          case .wait:
            if (producer ? space : data).wait(timeout: .now() + .seconds(5)) != .success {
              failed.store(true, ordering: .relaxed)
              return
            }
          default:
            failed.store(true, ordering: .relaxed)
            return
          }
        default:
          failed.store(true, ordering: .relaxed)
          return
        }
      }
    }
  }
}

final class ConcurrentRingTests: XCTestCase {
  func testSpscPublicationAndLatchedWakeupsAcrossRepeatedSlotReuse() {
    let exchange = Exchange()
    DispatchQueue.concurrentPerform(iterations: 2) { exchange.transfer($0 == 0) }
    XCTAssertFalse(exchange.failed.load(ordering: .relaxed))
  }
}
