import Dispatch
import Synchronization
import TarwinIPC
import XCTest

@testable import TarwinDevice

// Exactly one worker per lane. The pinned words and latched wake events
// are shared; both endpoints attach before either worker may transfer.
private final class Worker: @unchecked Sendable {
  var lane: RingEndpoint
  init(_ lane: consuming RingEndpoint) { self.lane = lane }
  func transfer(
    producer: Bool, failed: borrowing Atomic<Bool>, ready: DispatchSemaphore,
    peer: DispatchSemaphore
  ) {
    var row = RingRecord()
    var index = 0
    while index < 8192 && !failed.load(ordering: .relaxed) {
      if producer { for j in 0..<32 { row.words[j] = UInt32(index + j) } }
      let step = producer ? lane.push(row) : lane.pop(into: &row)
      switch step {
      case .transferred(let notify):
        if notify { peer.signal() }
        if !producer {
          for j in 0..<32 where row.words[j] != UInt32(index + j) {
            failed.store(true, ordering: .relaxed)
            return
          }
        }
        index += 1
      case .wait:
        if ready.wait(timeout: .now() + .seconds(5)) != .success {
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
final class ConcurrentRingTests: XCTestCase {
  func testSpscPublicationAndLatchedWakeupsAcrossRepeatedSlotReuse() {
    let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096 + 16384, alignment: 4096)
    defer { memory.deallocate() }
    let pair = IoRingMapping(initializing: memory, count: 64, stride: 128)!
    let tx = Worker(pair.endpoint(completion: false, producer: true)!)
    let rx = Worker(pair.endpoint(completion: false, producer: false)!)
    let failed = Atomic(false)
    let data = DispatchSemaphore(value: 0)
    let space = DispatchSemaphore(value: 0)
    DispatchQueue.concurrentPerform(iterations: 2) { i in
      (i == 0 ? tx : rx).transfer(
        producer: i == 0, failed: failed, ready: i == 0 ? space : data, peer: i == 0 ? data : space)
    }
    XCTAssertFalse(failed.load(ordering: .relaxed))
  }
}
