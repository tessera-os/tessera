import HostedMetalGPU
import Metal

enum PresentationEvent: Sendable {
  case blitCompleted(success: Bool)
  case drawablePresented(time: Double)
}

@MainActor
protocol PresentationEventSource {
  func observe(_ receive: @escaping @MainActor (PresentationEvent) -> Void)
}

struct MetalPresentationEvents: PresentationEventSource {
  let buffer: any MTLCommandBuffer
  let drawable: any MTLDrawable

  func observe(_ receive: @escaping @MainActor (PresentationEvent) -> Void) {
    buffer.addCompletedHandler { buffer in
      let success = buffer.status == .completed
      Task { @MainActor in receive(.blitCompleted(success: success)) }
    }
    drawable.addPresentedHandler { drawable in
      let time = drawable.presentedTime
      Task { @MainActor in receive(.drawablePresented(time: time)) }
    }
  }
}

@MainActor
final class PresentationTracker {
  private struct Flight {
    let id: HostedFrameID
    var gpuFinished = false
    var drawableDropped = false
  }

  private var generation: UInt64?
  private var flight: Flight?
  private let report: (HostedPresentation) -> Void

  init(report: @escaping (HostedPresentation) -> Void) {
    self.report = report
  }

  var inFlight: HostedFrameID? { flight?.id }

  func setGeneration(_ generation: UInt64?) {
    self.generation = generation
    if let flight, flight.id.generation != generation, flight.gpuFinished {
      finish(.discarded(flight.id))
    }
  }

  func begin(_ id: HostedFrameID, events: any PresentationEventSource) {
    precondition(flight == nil && id.generation == generation)
    flight = Flight(id: id)
    events.observe { [weak self] event in self?.receive(event, for: id) }
  }

  private func receive(_ event: PresentationEvent, for id: HostedFrameID) {
    guard let flight, flight.id == id else { return }
    switch event {
    case .blitCompleted(let success):
      if !success || generation != id.generation || flight.drawableDropped {
        finish(.discarded(id))
      } else {
        self.flight?.gpuFinished = true
      }
    case .drawablePresented(let time):
      if time.isFinite, time > 0, generation == id.generation, !flight.drawableDropped {
        finish(.presented(id, time: time))
      } else if flight.gpuFinished {
        finish(.discarded(id))
      } else {
        self.flight?.drawableDropped = true
      }
    }
  }

  private func finish(_ result: HostedPresentation) {
    flight = nil
    report(result)
  }
}
