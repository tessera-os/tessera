import Dispatch
import Synchronization
import TarwinIPC
import XCTest

final class SharedMemory: @unchecked Sendable {
  let raw: UnsafeMutableRawPointer
  let cells: UnsafeMutableBufferPointer<Atomic<UInt32>>
  var view: UnsafeBufferPointer<Atomic<UInt32>> { UnsafeBufferPointer(cells) }
  init(stride: Int) {
    let bytes = 4096 + 128 * stride
    raw = .allocate(byteCount: bytes, alignment: 4096)
    cells = .init(
      start: raw.bindMemory(to: Atomic<UInt32>.self, capacity: bytes / 4), count: bytes / 4)
    for i in cells.indices { cells.initializeElement(at: i, to: Atomic(0)) }
    cells[0].store(RingFormat.magic, ordering: .relaxed)
    cells[1].store(1, ordering: .relaxed)
    cells[2].store(64, ordering: .relaxed)
    cells[3].store(UInt32(stride), ordering: .relaxed)
  }
  deinit {
    cells.deinitialize()
    raw.deallocate()
  }
}

final class RingEndpointTests: XCTestCase {
  func testBothStridesBackpressureAndCapturedGeometry() {
    for stride in [64, 128] {
      let m = SharedMemory(stride: stride)
      defer { withExtendedLifetime(m) {} }
      var p = RingEndpoint(fresh: m.view, completion: true, producer: true)!
      var c = RingEndpoint(fresh: m.view, completion: true, producer: false)!
      m.cells[2].store(.max, ordering: .relaxed)
      m.cells[3].store(4, ordering: .relaxed)
      var r = RingRecord()
      XCTAssertEqual(c.pop(into: &r), .wait)
      for i in 1...64 {
        r.words[0] = UInt32(i)
        r.words[stride / 4 - 1] = UInt32(i + 100)
        XCTAssertEqual(p.push(r), .transferred(notifyPeer: true))
      }
      XCTAssertEqual(p.push(r), .wait)
      for i in 1...64 {
        XCTAssertEqual(c.pop(into: &r), .transferred(notifyPeer: true))
        XCTAssertEqual(r.words[0], UInt32(i))
        XCTAssertEqual(r.words[stride / 4 - 1], UInt32(i + 100))
        if stride == 64 { XCTAssertEqual(r.words[31], 0) }
      }
      XCTAssertEqual(p.push(r), .transferred(notifyPeer: false))
      XCTAssertEqual(c.pop(into: &r), .transferred(notifyPeer: false))
      XCTAssertEqual(r.words[0], 64)
      XCTAssertEqual(m.cells[16].load(ordering: .relaxed), 0)  // submission ring untouched
    }
  }

  func testJumpingPeerCursorPermanentlyFailsClosed() {
    let m = SharedMemory(stride: 64)
    defer { withExtendedLifetime(m) {} }
    var c = RingEndpoint(fresh: m.view, completion: false, producer: false)!
    var r = RingRecord()
    m.cells[16].store(65, ordering: .releasing)
    XCTAssertEqual(c.pop(into: &r), .invalidPeer)
    m.cells[16].store(1, ordering: .releasing)
    XCTAssertEqual(c.pop(into: &r), .invalidPeer)
    XCTAssertEqual(m.cells[32].load(ordering: .acquiring), 0)
  }

  func testConcurrentPublicationAndWakeupsAcrossRepeatedWraps() {
    let m = SharedMemory(stride: 64)
    let pReady = DispatchSemaphore(value: 0)
    let cReady = DispatchSemaphore(value: 0)
    let data = DispatchSemaphore(value: 0)
    let space = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) {
      var p = RingEndpoint(fresh: m.view, completion: false, producer: true)!
      pReady.signal()
      guard cReady.wait(timeout: .now() + 5) == .success else { return XCTFail("attach timed out") }
      var r = RingRecord()
      for i in 1...4096 {
        r.words[0] = UInt32(i)
        r.words[15] = ~UInt32(i)
        while true {
          switch p.push(r) {
          case .transferred(let notify): if notify { data.signal() }
          case .wait:
            guard space.wait(timeout: .now() + 3) == .success else {
              return XCTFail("lost space wake")
            }
            continue
          default: return XCTFail("producer cursor rejected")
          }
          break
        }
      }
    }
    DispatchQueue.global().async(group: group) {
      var c = RingEndpoint(fresh: m.view, completion: false, producer: false)!
      cReady.signal()
      guard pReady.wait(timeout: .now() + 5) == .success else { return XCTFail("attach timed out") }
      var r = RingRecord()
      for i in 1...4096 {
        while true {
          switch c.pop(into: &r) {
          case .transferred(let notify): if notify { space.signal() }
          case .wait:
            guard data.wait(timeout: .now() + 3) == .success else {
              return XCTFail("lost data wake")
            }
            continue
          default: return XCTFail("consumer cursor rejected")
          }
          break
        }
        XCTAssertEqual(r.words[0], UInt32(i))
        XCTAssertEqual(r.words[15], ~UInt32(i))
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
  }
}
