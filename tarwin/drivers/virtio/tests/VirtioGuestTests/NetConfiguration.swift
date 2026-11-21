import VirtioGuest
import XCTest

final class NetConfigurationTests: XCTestCase {
  func testOnlyReadsNegotiatedFieldsAndRetriesTornSnapshot() {
    let b: [UInt8] = [2, 1, 2, 3, 4, 5, 1, 0, 0, 0, 0xdc, 5]
    var generation: UInt32 = 0
    let config = NetConfiguration.snapshot(
      features: UInt64(NetConfiguration.deviceBits), configBytes: 12,
      generation: { generation },
      read: { i in
        if i == 10 { generation = 1 }
        return b[i]
      })
    XCTAssertEqual(config?.mac, Array(b.prefix(6)))
    XCTAssertEqual(config?.mtu, 1500)
    XCTAssertEqual(config?.linkUp, true)
    let mac = NetConfiguration.snapshot(
      features: 32, configBytes: 6, generation: { 1 },
      read: {
        XCTAssertLessThan($0, 6)
        return b[$0]
      })
    XCTAssertNotNil(mac)
    XCTAssertNil(mac?.mtu)
    XCTAssertNil(mac?.linkUp)
  }
  func testRejectsShortChangingAndInvalidSnapshots() {
    let bits = UInt64(NetConfiguration.deviceBits)
    var g: UInt32 = 0
    XCTAssertNil(
      NetConfiguration.snapshot(
        features: bits, configBytes: 11, generation: { 0 },
        read: { _ in
          XCTFail("short configuration read")
          return 0
        }))
    XCTAssertNil(
      NetConfiguration.snapshot(
        features: bits, configBytes: 12,
        generation: {
          g += 1
          return g
        }, read: { _ in 2 }))
    XCTAssertEqual(g, 16)
    XCTAssertNil(
      NetConfiguration.snapshot(
        features: bits, configBytes: 12,
        generation: { 0 }, read: { _ in 255 }))
  }
}
