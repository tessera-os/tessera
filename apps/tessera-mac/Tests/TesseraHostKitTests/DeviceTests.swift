import XCTest
import HostedDeviceWire
import TarwinArchHosted
@testable import TesseraHostKit

final class DeviceTests: XCTestCase {
    func testChannelCopiesFrameAndCloses() {
        var received = Data()
        let channel = DeviceFrameChannel { received = $0 }
        Data([1, 2, 3]).withUnsafeBytes { channel.send(frame: $0) }
        XCTAssertEqual(received, Data([1, 2, 3]))
        var calls = 0
        channel.onReceive = { _ in calls += 1 }
        channel.receive(Data()); XCTAssertEqual(calls, 1)
        channel.close(); channel.receive(Data()); XCTAssertEqual(calls, 1)
    }
    func testRegistryAndDriverRoundTrip() throws {
        let registry = HostDeviceRegistry()
        let pong = expectation(description: "H6 driver pongs"); pong.expectedFulfillmentCount = 3
        let devices = try HostedServiceDevices(registry: registry) { data in
            data.withUnsafeBytes { bytes in
                if FrameView(bytes)?.kind == Wire.pong { pong.fulfill() }
            }
        }
        XCTAssertEqual(devices.nextCharacter(), 0)
        XCTAssertThrowsError(try devices.receive(Data()))
        XCTAssertThrowsError(try devices.receive(Data(repeating: 0, count: 32)))
        for (family, kind) in [(1, "hid"), (2, "audio"), (3, "power")] {
            let provider = try XCTUnwrap(registry.lookup(kind: kind))
            XCTAssertThrowsError(try { let p = try provider.open(slot: 1); _ = p.rawName }())
            var bytes = Data(count: 32)
            let encoded = bytes.withUnsafeMutableBytes {
                FrameView.encode(family: UInt16(family), kind: Wire.ping, sequence: 1,
                    timestampNs: 1, payload: UnsafeRawBufferPointer(start: nil, count: 0), into: $0)
            }
            XCTAssertEqual(encoded, 32)
            try devices.receive(bytes)
        }
        wait(for: [pong], timeout: 3)
    }
}
