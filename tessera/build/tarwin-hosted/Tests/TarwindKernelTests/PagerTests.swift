import Darwin
import Foundation
import XCTest
import TarwinArchHosted
@testable import TarwindKernel

final class PagerTests: XCTestCase {
  func probe(_ mode: String) throws -> (Int32, String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let process = Process()
    process.executableURL = Bundle(for: PagerTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("TarwindPagerProbe")
    process.arguments = [mode, directory.path]
    let output = Pipe()
    process.standardOutput = output; process.standardError = output
    let finished = expectation(description: "fault helper exits")
    process.terminationHandler = { _ in finished.fulfill() }
    try process.run()
    wait(for: [finished], timeout: 10)
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
  }
  func testPagerMapsFaultAndResumesOriginalInstruction() throws {
    let (status, output) = try probe("resume")
    XCTAssertEqual(status, 0, output)
    XCTAssertTrue(output.contains("pager mapped original fault; registry live"), output)
    XCTAssertTrue(output.contains("resumed faulting load; process survived"), output)
    XCTAssertFalse(output.contains("terminated"), output)
  }
  func testMissingDecliningThrowingAndTerminatingPagersAreFatal() throws {
    for mode in ["nil-pager", "nil-result", "throw", "terminate"] {
      let (status, output) = try probe(mode)
      XCTAssertNotEqual(status, 0, output)
      XCTAssertTrue(output.contains("; terminated"), output)
      XCTAssertFalse(output.contains("resumed faulting load"), output)
    }
  }
}
