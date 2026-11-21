import XCTest
import IOSurface
@testable import TesseraHostKit

final class HostTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testMissingDiskIsLeftForKernel() throws {
        let url = try temporary().appendingPathComponent("disk")
        XCTAssertNil(try DiskImage.prepareForBoot(at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testLegacyDiskBackedUpWithoutReformatting() throws {
        let url = try temporary().appendingPathComponent("disk")
        let legacy = Data("TRFSDISK\n1\nlegacy data".utf8)
        try legacy.write(to: url)
        let backup = try XCTUnwrap(DiskImage.prepareForBoot(at: url))
        XCTAssertEqual(try Data(contentsOf: backup), legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(try DiskImage.prepareForBoot(at: url))
    }
    func testOtherDisksUntouchedAndIOErrorsPropagate() throws {
        let url = try temporary().appendingPathComponent("disk")
        for bytes in [Data(), Data("TRFSDISK\n2\n".utf8), Data(repeating: 1, count: 8192)] {
            try bytes.write(to: url)
            XCTAssertNil(try DiskImage.prepareForBoot(at: url))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        XCTAssertThrowsError(try DiskImage.prepareForBoot(at: url.appendingPathComponent("child")))
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
        let host = FakeHost(); let devices = HostDevices(display: host); let kernel = StubKernel(devices: devices)
        host.expectation = expectation(description: "ready")
        kernel.start(config: KernelConfig(diskPath: disk.path, systemImagePath: "", panicRecordPath: ""), host: host)
        waitForExpectations(timeout: 8); kernel.shutdown()
        XCTAssertEqual(host.stages, ["firmware", "tarwind", "tessera.init", "services", "MosaicDisplay", "desktop"])
        XCTAssertGreaterThan(host.frames, 0); XCTAssertTrue(host.panics.isEmpty)
    }
    func testStubDoesNotTouchDataDisk() throws {
        let disk = try temporary().appendingPathComponent("disk"), contents = Data("not a stub disk".utf8)
        try contents.write(to: disk)
        let host = FakeHost(); host.expectation = expectation(description: "stub ready without disk IO")
        let kernel = StubKernel(devices: HostDevices(display: host))
        kernel.start(config: KernelConfig(diskPath: disk.path, systemImagePath: "", panicRecordPath: "", outputs: []), host: host)
        waitForExpectations(timeout: 8); kernel.shutdown()
        XCTAssertTrue(host.panics.isEmpty); XCTAssertEqual(try Data(contentsOf: disk), contents)
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
