import TarwinObject
import TarwinSyscall
import XCTest

@testable import TarwinDevice

final class BindingTests: XCTestCase {
  func testPinnedDispatchUsesTheCanonicalNumberAndCurrentHandleGeneration() {
    var slot = unusedHandleSlot()
    XCTAssertTrue(slot.install(91, TarwinKind.deviceSlot, 4, 4))
    let value = slot.name(7, 5)
    XCTAssertEqual(DeviceOperation(callNumber: TarwinCall.deviceSlotConfigRead), .configRead)
    XCTAssertNil(DeviceOperation(callNumber: TarwinCall.channelCreate))
    var balance = 0
    let pin: (UInt64) -> Bool = { id in
      balance += 1
      return id == 91
    }
    let release: (UInt64) -> Void = { _ in balance -= 1 }
    let use: (borrowing PinnedIoHandle) -> Bool = { h in
      balance == 1 && h.permits(.configRead, 91) && !h.permits(.configWrite, 91)
    }
    XCTAssertEqual(
      withPinnedIoHandle(
        value, salt: 7, index: 5, snapshot: slot, pin: pin, release: release, perform: use), true)
    XCTAssertNil(
      withPinnedIoHandle(
        value, salt: 7, index: 6, snapshot: slot, pin: pin, release: release, perform: use))
    XCTAssertEqual(slot.revoke(), 91)
    XCTAssertTrue(slot.install(92, TarwinKind.deviceSlot, 4, 4))
    XCTAssertNil(
      withPinnedIoHandle(
        value, salt: 7, index: 5, snapshot: slot, pin: pin, release: release, perform: use))
    XCTAssertEqual(balance, 0)
  }
}
