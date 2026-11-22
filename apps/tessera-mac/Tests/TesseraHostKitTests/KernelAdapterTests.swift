import XCTest
import IOSurface
@testable import TesseraHostKit

final class KernelAdapterTests: XCTestCase {
    private func configuration(outputs: [DisplayOutput] = [DisplayOutput(width: 64, height: 64)]) throws -> KernelConfig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let disk = directory.appendingPathComponent("disk")
        return KernelConfig(diskPath: disk.path, panicRecordPath: "", outputs: outputs)
    }
    func testRealBootAndDisplay() throws {
        let host = AdapterHost()
        host.readyExpectation = expectation(description: "real ready")
        host.frameExpectation = expectation(description: "preview frame")
        let kernel = KernelFactory.make(devices: HostDevices(display: host))
        XCTAssertTrue(kernel is TarwindKernelAdapter)
        kernel.start(config: try configuration(), host: host)
        waitForExpectations(timeout: 8); kernel.shutdown(); kernel.shutdown()
        XCTAssertEqual(host.stages, ["time", "objects", "syscalls", "storage", "network", "scheduler", "ready"])
        XCTAssertTrue(host.panics.isEmpty)
        XCTAssertTrue(host.lines.contains("Kernel: TarwindKernel"))
    }
    func testRealBootWithoutOutputs() throws {
        let host = AdapterHost(); host.readyExpectation = expectation(description: "ready without display")
        let kernel = TarwindKernelAdapter(devices: HostDevices(display: host))
        kernel.start(config: try configuration(outputs: []), host: host)
        waitForExpectations(timeout: 8); kernel.shutdown()
        XCTAssertEqual(host.frames, 0); XCTAssertTrue(host.panics.isEmpty)
        XCTAssertTrue(KernelFactory.make(devices: HostDevices(display: host), stubKernel: true) is StubKernel)
    }
    func testBootFailureFallsBack() throws {
        enum Failure: Error { case unavailable }
        let host = AdapterHost(); host.readyExpectation = expectation(description: "fallback ready")
        let kernel = TarwindKernelAdapter(devices: HostDevices(display: host)) { config, _ in
            XCTAssertFalse(config.diskPath.isEmpty)
            XCTAssertEqual(config.taskExecutablePath, "task-fixture")
            throw Failure.unavailable
        }
        var config = try configuration(); config.taskExecutablePath = "task-fixture"
        kernel.start(config: config, host: host)
        waitForExpectations(timeout: 8); kernel.shutdown()
        XCTAssertTrue(host.lines.contains { $0.hasPrefix("Kernel boot failed:") })
        XCTAssertEqual(host.stages.last, "desktop"); XCTAssertGreaterThan(host.frames, 0)
        XCTAssertTrue(host.panics.isEmpty)
    }

    func testMissingPinnedImageDoesNotFallBackOrReportReady() throws {
        let host = AdapterHost()
        let config = try configuration()
        let missing = URL(fileURLWithPath: config.diskPath).appendingPathExtension("missing")
        let kernel = TarwindKernelAdapter(devices: HostDevices(display: host),
            systemImage: SystemImage(url: missing, root: [UInt8](repeating: 0, count: 32)))
        let ready = expectation(description: "must not signal ready")
        ready.isInverted = true; host.readyExpectation = ready
        kernel.start(config: config, host: host)
        waitForExpectations(timeout: 0.1)
        XCTAssertEqual(host.panics.count, 1)
        XCTAssertEqual(host.frames, 0)
        XCTAssertFalse(host.lines.contains("TRFS system volume verified"))
    }

    func testRootMetadataDecodesExactly32Bytes() {
        XCTAssertEqual(SystemImage.decodeRoot(String(repeating: "a0", count: 32)), Array(repeating: 160, count: 32))
        XCTAssertNil(SystemImage.decodeRoot(String(repeating: "a0", count: 31)))
        XCTAssertNil(SystemImage.decodeRoot(String(repeating: "+1", count: 32)))
        XCTAssertNil(SystemImage.decodeRoot(String(repeating: "é", count: 32)))
    }
}

private final class AdapterHost: KernelHost, DisplayProvider {
    var stages: [String] = [], lines: [String] = [], panics: [[UInt8]] = []
    var frames = 0
    var readyExpectation: XCTestExpectation?, frameExpectation: XCTestExpectation?
    func bootStage(_ name: String) { stages.append(name) }
    func ready() { readyExpectation?.fulfill(); readyExpectation = nil }
    func console(_ line: String) { lines.append(line) }
    func panic(record: [UInt8]) { panics.append(record) }
    func outputChanged(_ output: DisplayOutput) {}
    func present(_ surface: IOSurface, output: Int, frame: UInt64) {
        frames += 1; frameExpectation?.fulfill(); frameExpectation = nil
    }
}
