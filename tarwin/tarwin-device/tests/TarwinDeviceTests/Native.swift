import XCTest

@testable import TarwinDevice

final class NativeTests: XCTestCase {
  func testPrivateConfigDispatchRejectsDifferentDeviceStaleEpochAndAttenuatedRights() {
    let h = PinnedIoHandle(koid: 9, kind: .deviceSlot, rights: 516)
    var slot = DeviceSlotState(group: 13)
    XCTAssertTrue(slot.assign(true, 77, { g, e in return true }))
    let r = DeviceOperation.configRead
    let w = DeviceOperation.configWrite
    var writes: Int = 0
    let read: (UInt32, UInt32) -> ConfigReply = { off, width in return .value(8) }
    let policy: (UInt32, UInt32) -> ConfigPolicy = { off, width in
      return ConfigPolicy(writable: 1, plainReadWrite: true)
    }
    let write: (UInt32, UInt32, UInt32) -> Bool = { off, width, v in
      writes += 1
      return true
    }
    XCTAssertTrue(
      slotConfigCall(r, 77, 1, 9, h, slot, 0, 4, 0, policy, read, write) == ConfigReply.value(8))
    XCTAssertTrue(
      slotConfigCall(w, 77, 1, 10, h, slot, 0x60, 1, 9, policy, read, write) == ConfigReply.denied)
    XCTAssertTrue(
      slotConfigCall(w, 77, 0, 9, h, slot, 0x60, 1, 9, policy, read, write) == ConfigReply.denied)
    XCTAssertTrue(
      slotConfigCall(w, 77, 1, 9, h, slot, 0x60, 1, 9, policy, read, write) == ConfigReply.value(0))
    XCTAssertTrue(
      slotConfigCall(w, 77, 1, 9, h, slot, 0x60, 1, 7, policy, read, write) == ConfigReply.denied)
    let thin = PinnedIoHandle(koid: 9, kind: .deviceSlot, rights: 4)
    XCTAssertTrue(!thin.permits(w, 9))
    XCTAssertTrue(!thin.permits(.fenceWait, 9))
    XCTAssertTrue(writes == 1)
  }
}
