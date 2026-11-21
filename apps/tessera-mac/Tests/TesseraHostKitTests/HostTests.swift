import XCTest
import IOSurface
@testable import TesseraHostKit

final class HostTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testDiskCreateOpen() throws {
        let url = try temporary().appendingPathComponent("disk")
        let disk = try DiskImage.create(at: url, size: 1048576)
        XCTAssertEqual(try DiskImage.open(at: url).uuid, disk.uuid)
        XCTAssertEqual(try disk.incrementBootCount(), 1)
        XCTAssertEqual(try disk.incrementBootCount(), 2)
        XCTAssertThrowsError(try DiskImage.create(at: url))
    }
    func testBadAndEmptyHeader() throws {
        let url = try temporary().appendingPathComponent("disk")
        try Data().write(to: url); XCTAssertThrowsError(try DiskImage.open(at: url))
        try Data(repeating: 1, count: 8192).write(to: url); XCTAssertThrowsError(try DiskImage.open(at: url))
        XCTAssertThrowsError(try DiskImage.create(at: url, size: 1))
    }
    func testConfigCoding() throws {
        for outputs in [[DisplayOutput()], []] {
            let config = KernelConfig(diskPath: "disk", systemImagePath: "image", panicRecordPath: "panic", taskExecutablePath: "task", outputs: outputs)
            XCTAssertEqual(try JSONDecoder().decode(KernelConfig.self, from: JSONEncoder().encode(config)), config)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(KernelConfig.self, from: Data()))
    }
    func testStubBoot() throws {
        let disk = try temporary().appendingPathComponent("disk")
        _ = try DiskImage.create(at: disk, size: 1048576)
        let host = FakeHost(); let devices = HostDevices(display: host); let kernel = StubKernel(devices: devices)
        host.expectation = expectation(description: "ready")
        kernel.start(config: KernelConfig(diskPath: disk.path, systemImagePath: "", panicRecordPath: ""), host: host)
        waitForExpectations(timeout: 8); kernel.shutdown()
        XCTAssertEqual(host.stages, ["firmware", "tarwind", "tessera.init", "services", "MosaicDisplay", "desktop"])
        XCTAssertGreaterThan(host.frames, 0); XCTAssertTrue(host.panics.isEmpty)
    }
    func testStubDiskFailure() {
        let host = FakeHost(); let kernel = StubKernel(devices: HostDevices(display: host))
        kernel.start(config: KernelConfig(diskPath: "/nonexistent/disk", systemImagePath: "", panicRecordPath: ""), host: host)
        XCTAssertEqual(host.panics.count, 1); XCTAssertEqual(host.frames, 0); kernel.shutdown()
    }
}
private final class FakeHost: KernelHost, DisplayProvider {
    var stages: [String] = [], panics: [[UInt8]] = []
    var frames = 0
    var expectation: XCTestExpectation?
    func bootStage(_ name: String) { stages.append(name) }
    func ready() { expectation?.fulfill() }
    func console(_ line: String) {}
    func panic(record: [UInt8]) { panics.append(record) }
    func outputChanged(_ output: DisplayOutput) {}
    func present(_ surface: IOSurface, output: Int, frame: UInt64) { frames += 1 }
}
