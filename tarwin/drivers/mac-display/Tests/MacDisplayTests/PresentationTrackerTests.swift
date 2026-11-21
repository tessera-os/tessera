import HostedMetalGPU
@testable import MacDisplay
import XCTest

@MainActor
private final class Events: PresentationEventSource {
  private var receive: (@MainActor (PresentationEvent) -> Void)?

  func observe(_ receive: @escaping @MainActor (PresentationEvent) -> Void) {
    self.receive = receive
  }

  func send(_ event: PresentationEvent) { receive?(event) }
}

final class PresentationTrackerTests: XCTestCase {
  @MainActor
  func testOnlyCurrentNonzeroDrawableEvidencePermitsLatch() async {
    var acknowledgments: [HostedPresentation] = []
    let tracker = PresentationTracker { acknowledgments.append($0) }
    tracker.setGeneration(1)
    let frame = HostedFrameID(output: 1, generation: 1, serial: 1)
    let firstEvents = Events()
    tracker.begin(frame, events: firstEvents)
    firstEvents.send(.blitCompleted(success: true))
    XCTAssertTrue(acknowledgments.isEmpty)
    firstEvents.send(.drawablePresented(time: 50))
    XCTAssertEqual(acknowledgments, [.presented(frame, time: 50)])

    let missed = HostedFrameID(output: 1, generation: 1, serial: 2)
    let missedEvents = Events()
    tracker.begin(missed, events: missedEvents)
    missedEvents.send(.drawablePresented(time: 0))
    XCTAssertEqual(tracker.inFlight, missed)
    missedEvents.send(.blitCompleted(success: true))
    XCTAssertEqual(acknowledgments.last, .discarded(missed))

    let failed = HostedFrameID(output: 1, generation: 1, serial: 3)
    let failedEvents = Events()
    tracker.begin(failed, events: failedEvents)
    failedEvents.send(.blitCompleted(success: false))
    failedEvents.send(.drawablePresented(time: 51))
    XCTAssertEqual(acknowledgments.last, .discarded(failed))

    let stale = HostedFrameID(output: 1, generation: 1, serial: 4)
    let staleEvents = Events()
    tracker.begin(stale, events: staleEvents)
    tracker.setGeneration(2)
    staleEvents.send(.drawablePresented(time: 52))
    staleEvents.send(.blitCompleted(success: true))
    XCTAssertEqual(acknowledgments.last, .discarded(stale))

    let current = HostedFrameID(output: 1, generation: 2, serial: 5)
    let currentEvents = Events()
    tracker.begin(current, events: currentEvents)
    staleEvents.send(.drawablePresented(time: 53))
    XCTAssertEqual(tracker.inFlight, current)
    currentEvents.send(.drawablePresented(time: 54))
    XCTAssertEqual(acknowledgments, [
      .presented(frame, time: 50), .discarded(missed), .discarded(failed),
      .discarded(stale), .presented(current, time: 54),
    ])
  }
}
