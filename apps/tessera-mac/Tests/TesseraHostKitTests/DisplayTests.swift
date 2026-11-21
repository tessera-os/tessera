import AppKit
import HostedMetalGPU
import IOSurface
import XCTest
@testable import TesseraHostKit

final class DisplayTests: XCTestCase {
    func testTransportRoundTripsAndRejectsInvalidData() throws {
        let events: [DisplayTransportEvent] = [
            .mode(output: 1, generation: 2, width: 64, height: 80, scale: 2, refreshHz: 60),
            .removed(output: 1, generation: 2), .timing(output: 1, generation: 2, deadline: 30, target: 40),
            .presented(output: 1, generation: 2, serial: 3, time: 4), .discarded(output: 1, generation: 2, serial: 3)
        ]
        for event in events { XCTAssertEqual(try JSONDecoder().decode(DisplayTransportEvent.self, from: JSONEncoder().encode(event)), event) }
        XCTAssertThrowsError(try JSONDecoder().decode(DisplayTransportEvent.self, from: Data()))
        XCTAssertThrowsError(try JSONDecoder().decode(DisplayTransportEvent.self, from: Data("{}".utf8)))
    }
    @MainActor func testImportedPixelsAndDoubleBufferReuseAfterRelease() throws {
        var frames: [HostedOutputFrame] = []
        var arrival: XCTestExpectation?
        let gpu = try XCTUnwrap(PreviewGPU { frames.append($0); arrival?.fulfill(); arrival = nil })
        defer { gpu.shutdown() }
        XCTAssertNil(gpu.acquireSurface(output: 0, width: 64, height: 64))
        XCTAssertNotNil(gpu.handle(.mode(output: 1, generation: 1, width: 64, height: 64, scale: 1, refreshHz: 60)))
        let first = try XCTUnwrap(gpu.acquireSurface(output: 0, width: 64, height: 64))
        write(first, color: 0xff123456)
        arrival = expectation(description: "GPU-complete first copy"); gpu.submit(first, output: 0)
        XCTAssertNil(gpu.acquireSurface(output: 0, width: 64, height: 64))
        wait(for: [arrival!], timeout: 3)
        XCTAssertEqual(frames.count, 1); XCTAssertEqual(frames[0].id, HostedFrameID(output: 1, generation: 1, serial: 1))
        XCTAssertFalse(frames[0].surface === first)
        XCTAssertEqual(read(frames[0].surface), 0xff123456)
        gpu.handle(.discarded(output: 1, generation: 1, serial: 999))
        XCTAssertNil(gpu.acquireSurface(output: 0, width: 64, height: 64))
        gpu.handle(.discarded(output: 1, generation: 1, serial: 1))
        let second = try XCTUnwrap(gpu.acquireSurface(output: 0, width: 64, height: 64))
        XCTAssertFalse(second === first); write(second, color: 0xffabcdef)
        arrival = expectation(description: "GPU-complete second copy"); gpu.submit(second, output: 0)
        wait(for: [arrival!], timeout: 3)
        XCTAssertEqual(frames.count, 2); XCTAssertEqual(read(frames[1].surface), 0xffabcdef)
        gpu.handle(.discarded(output: 1, generation: 1, serial: 2))
        let reused = try XCTUnwrap(gpu.acquireSurface(output: 0, width: 64, height: 64))
        XCTAssertTrue(reused === first); gpu.discardSurface(reused, output: 0)
        XCTAssertNotNil(gpu.handle(.mode(output: 1, generation: 2, width: 81, height: 64, scale: 1, refreshHz: 60)))
        XCTAssertNil(gpu.handle(.mode(output: 1, generation: 1, width: 64, height: 64, scale: 1, refreshHz: 60)))
        XCTAssertNil(gpu.acquireSurface(output: 0, width: 64, height: 64))
        let resized = try XCTUnwrap(gpu.acquireSurface(output: 0, width: 81, height: 64))
        XCTAssertGreaterThanOrEqual(resized.bytesPerRow, 81 * 4); XCTAssertEqual(resized.bytesPerRow % 16, 0)
        gpu.discardSurface(resized, output: 0)
        gpu.handle(.removed(output: 1, generation: 2))
        XCTAssertNil(gpu.acquireSurface(output: 0, width: 81, height: 64))
        gpu.poll(); XCTAssertEqual(frames.count, 2)
    }
    @MainActor func testMacDisplayReceivesIdentityAndReportsDiscardOnResize() throws {
        var events: [DisplayTransportEvent] = []
        let display = try XCTUnwrap(PreviewDisplay(id: 0) { events.append(try! JSONDecoder().decode(DisplayTransportEvent.self, from: $0)) })
        defer { display.stop() }
        XCTAssertFalse(display.updateMode(width: 0, height: 64, scale: 1, refreshHz: 60))
        XCTAssertTrue(display.updateMode(width: 64, height: 64, scale: 1, refreshHz: 60))
        let surface = try XCTUnwrap(IOSurface(properties: [.width: 64, .height: 64, .bytesPerElement: 4,
            .bytesPerRow: 256, .pixelFormat: UInt32(0x42475241)]))
        XCTAssertFalse(display.receive(surface, output: 2, generation: 1, serial: 1))
        XCTAssertTrue(events.contains(.discarded(output: 2, generation: 1, serial: 1)))
        XCTAssertTrue(display.receive(surface, output: 1, generation: 1, serial: 1))
        XCTAssertFalse(display.receive(surface, output: 1, generation: 1, serial: 1))
        XCTAssertTrue(display.updateMode(width: 80, height: 64, scale: 1, refreshHz: 60))
        XCTAssertTrue(events.contains(.discarded(output: 1, generation: 1, serial: 1)))
        XCTAssertEqual(display.mode?.generation, 2)
    }
    @MainActor private func write(_ surface: IOSurface, color: UInt32) {
        XCTAssertEqual(surface.lock(options: [], seed: nil), 0)
        surface.baseAddress.storeBytes(of: color, as: UInt32.self)
        surface.unlock(options: [], seed: nil)
    }
    @MainActor private func read(_ surface: IOSurface) -> UInt32 {
        XCTAssertEqual(surface.lock(options: .readOnly, seed: nil), 0)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        return surface.baseAddress.load(as: UInt32.self)
    }
}
