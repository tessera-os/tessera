import XCTest
import Darwin
import TarwinHostedGate
import TarwinABI
import TarwinArchHosted
@testable import TesseraHostKit

final class TaskTests: XCTestCase {
    func testGateErrorsAndEmptyRegistry() {
        let launcher = TaskLauncher(registry: HostDeviceRegistry(), log: { _ in })
        XCTAssertNotEqual(launcher.handle(GateRequest(threadID: 9, number: DemoCall.console, arguments: CallRegisters())).result.status, 0)
        XCTAssertNotEqual(launcher.handle(GateRequest(threadID: 1, number: 0, arguments: CallRegisters())).result.status, 0)
        XCTAssertEqual(launcher.handle(GateRequest(threadID: 1, number: DemoCall.input, arguments: CallRegisters())).result.first, 0)
        XCTAssertThrowsError(try launcher.launch(executable: "/nonexistent/task"))
        launcher.shutdown()
    }
    func testProviderRoundTrip() throws {
        let provider = try DemoDeviceProvider(kind: "hid") { request in GateReply(result: CallResult(first: request.arguments[0])) }
        defer { provider.close() }
        XCTAssertThrowsError(try { let port = try provider.open(slot: 1); _ = port.rawName }())
        let send = try provider.open(slot: 0)
        XCTAssertEqual(try GateWire.call(on: send.rawName, number: DemoCall.input, value: 65).result.first, 65)
        XCTAssertThrowsError(try GateWire.call(on: 0, number: DemoCall.input))
    }
    func testChildCheckInAndGate() throws {
        let registry = HostDeviceRegistry()
        let displayed = expectation(description: "task display")
        displayed.assertForOverFulfill = false
        let display = try DemoDeviceProvider(kind: "display") { _ in
            displayed.fulfill(); return GateReply(result: CallResult())
        }
        let hid = try DemoDeviceProvider(kind: "hid") { _ in GateReply(result: CallResult()) }
        registry.register(display); registry.register(hid)
        defer { display.close(); hid.close() }
        var checkedIn = false
        let launcher = TaskLauncher(registry: registry) { if $0.contains("TASK CHECKED IN") { checkedIn = true } }
        var directory = Bundle(for: TaskTests.self).bundleURL.deletingLastPathComponent()
        while directory.path != "/" && !FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("tessera-test-task").path) {
            directory.deleteLastPathComponent()
        }
        let executable = directory.appendingPathComponent("tessera-test-task").path
        try launcher.launch(executable: executable, command: .resumeThread(id: 1))
        defer { launcher.shutdown() }
        wait(for: [displayed], timeout: 5)
        XCTAssertTrue(checkedIn)
    }
}
