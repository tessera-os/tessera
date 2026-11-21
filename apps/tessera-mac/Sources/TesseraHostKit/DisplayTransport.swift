import Foundation
import HostedMetalGPU
import MacDisplay
import Metal
import AppKit
import IOSurface

public enum DisplayTransportEvent: Codable, Equatable {
    case mode(output: UInt64, generation: UInt64, width: Int, height: Int, scale: Double, refreshHz: Int)
    case removed(output: UInt64, generation: UInt64)
    case timing(output: UInt64, generation: UInt64, deadline: UInt64, target: UInt64)
    case presented(output: UInt64, generation: UInt64, serial: UInt64, time: Double)
    case discarded(output: UInt64, generation: UInt64, serial: UInt64)

    public init(_ mode: HostedOutputMode) {
        self = .mode(output: mode.output, generation: mode.generation, width: mode.width,
                     height: mode.height, scale: mode.scale, refreshHz: mode.refreshHz)
    }
}

@MainActor public final class PreviewDisplay: MacDisplayTransport {
    private var display: MacDisplayOutput?
    private let send: (Data) -> Void
    public var mode: HostedOutputMode? { display?.mode }
    public init?(id: Int, send: @escaping (Data) -> Void) {
        guard id >= 0, let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.send = send
        display = MacDisplayOutput(id: UInt64(id) + 1, device: device, transport: self)
        if display == nil { return nil }
    }
    public func makeView() -> NSView { display!.makeView() }
    public func receive(_ surface: IOSurface, output: UInt64, generation: UInt64, serial: UInt64) -> Bool {
        display?.receive(HostedOutputFrame(id: HostedFrameID(output: output, generation: generation, serial: serial), surface: surface)) ?? false
    }
    public func stop() { display?.stop() }
    public func resume(width: Int, height: Int, scale: Double, refreshHz: Int) {
        _ = updateMode(width: width, height: height, scale: scale, refreshHz: refreshHz)
        display?.start()
    }
    public func updateMode(width: Int, height: Int, scale: Double, refreshHz: Int) -> Bool {
        display?.updateMode(width: width, height: height, scale: scale, refreshHz: refreshHz) ?? false
    }
    private func forward(_ event: DisplayTransportEvent) {
        if let data = try? JSONEncoder().encode(event) { send(data) }
    }
    public func modeChanged(_ mode: HostedOutputMode) { forward(DisplayTransportEvent(mode)) }
    public func outputRemoved(_ output: UInt64, generation: UInt64) { forward(.removed(output: output, generation: generation)) }
    public func timing(_ update: MacDisplayTiming) {
        forward(.timing(output: update.output, generation: update.generation, deadline: update.deadline, target: update.targetPresentation))
    }
    public func presentationFinished(_ result: HostedPresentation) {
        switch result {
        case .presented(let id, let time): forward(.presented(output: id.output, generation: id.generation, serial: id.serial, time: time))
        case .discarded(let id): forward(.discarded(output: id.output, generation: id.generation, serial: id.serial))
        }
    }
}
