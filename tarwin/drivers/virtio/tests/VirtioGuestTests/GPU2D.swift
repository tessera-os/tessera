import VirtioGuest
import XCTest

final class GPU2DTests: XCTestCase {
  private func resource() -> GPU2DResource {
    GPU2DResource(id: 7, scanout: 0, width: 32, height: 32, backing: 0x2000, backingBytes: 4096)!
  }
  private func response(_ r: GPU2DRequest) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: Int(r.responseBytes))
    bytes[0] = bytes.count > 24 ? 1 : 0
    bytes[1] = 0x11
    bytes[4] = 1
    bytes[8] = UInt8(r.fence)
    if bytes.count > 24 {
      bytes[32] = 32
      bytes[36] = 32
      bytes[40] = 1
    }
    return bytes
  }
  func testRetiresOnlyAfterMatchingDisableDetachAndDestroy() {
    var r = resource()
    XCTAssertNil(r.prepare(.attach))
    for op: GPU2DOp in [
      .display, .create, .attach, .upload, .scanout, .flush, .disable, .detach, .destroy,
    ] {
      let req = r.prepare(op)!
      XCTAssertFalse(r.retired)
      XCTAssertNil(r.prepare(op))
      XCTAssertTrue(r.complete(response(req)))
    }
    XCTAssertTrue(r.retired)
  }
  func testRefusesStaleFenceErrorShortReplyAndDisabledScanout() {
    for i in [0, 1, 2, 3] {
      var r = resource()
      var bytes = response(r.prepare(.display)!)
      switch i {
      case 0: bytes[8] = 0
      case 1: bytes[1] = 0x12
      case 2: bytes.removeLast()
      default: bytes[40] = 0
      }
      XCTAssertFalse(r.complete(bytes))
      XCTAssertNil(r.prepare(.create))
      XCTAssertFalse(r.retired)
    }
  }
}
