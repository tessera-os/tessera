import Foundation
import HostedMetalGPU
import IOSurface
import Metal
import TarwinGPU

@MainActor private final class PreviewAccounting: HostedGPUAccounting {
    func charge(_ allocation: inout GpuAllocation, client: UInt64) -> Bool { false }
    func release(_ allocation: inout GpuAllocation, client: UInt64) -> Bool { false }
}

@MainActor public final class PreviewGPU {
    private final class Slot {
        enum State { case available, writing, copying }
        let output: UInt64
        let backing: IOSurface
        let handle: HostedImportedSurface
        var state = State.available
        var retiring = false
        init(output: UInt64, backing: IOSurface, handle: HostedImportedSurface) {
            self.output = output; self.backing = backing; self.handle = handle
        }
    }
    private let gpu: HostedMetalGPU
    private let present: (HostedOutputFrame) -> Void
    private var modes: [UInt64: HostedOutputMode] = [:]
    private var slots: [Slot] = []
    private var copying: Set<UInt64> = []
    private var waiting: Set<UInt64> = []
    private var offered: [UInt64: HostedFrameID] = [:]
    private var nextSurface: UInt64 = 0
    private var timer: DispatchSourceTimer?

    public init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(), present: @escaping (HostedOutputFrame) -> Void) {
        guard let device, let gpu = HostedMetalGPU(device: device, accounting: PreviewAccounting()) else { return nil }
        self.gpu = gpu; self.present = present
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.poll() } }
        self.timer = timer; timer.resume()
    }
    @discardableResult public func handle(_ event: DisplayTransportEvent) -> DisplayOutput? {
        switch event {
        case .mode(let output, let generation, let width, let height, let scale, let refresh):
            guard output <= UInt64(Int.max),
                  let mode = HostedOutputMode(output: output, generation: generation, width: width,
                                               height: height, scale: scale, refreshHz: refresh),
                  gpu.configure(mode, compositor: 1) else { return nil }
            retire(output: output); modes[output] = mode
            return DisplayOutput(id: Int(output - 1), width: width, height: height, scale: scale)
        case .removed(let output, let generation):
            guard gpu.removeOutput(output, generation: generation) else { return nil }
            modes.removeValue(forKey: output); retire(output: output)
        case .timing(let output, let generation, _, _):
            if modes[output]?.generation == generation { poll() }
        case .presented(let output, let generation, let serial, let time):
            guard time.isFinite, time > 0 else { return nil }
            finish(.presented(HostedFrameID(output: output, generation: generation, serial: serial), time: time))
        case .discarded(let output, let generation, let serial):
            finish(.discarded(HostedFrameID(output: output, generation: generation, serial: serial)))
        }
        return nil
    }
    public func acquireSurface(output: Int, width: Int, height: Int) -> IOSurface? {
        guard output >= 0 else { return nil }
        let id = UInt64(output) + 1
        guard let mode = modes[id], width == mode.width, height == mode.height, !waiting.contains(id) else { return nil }
        while slots.filter({ $0.output == id && !$0.retiring }).count < 2 {
            guard nextSurface < .max,
                  let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                      .pixelFormat: UInt32(0x42475241)]),
                  let handle = gpu.importSurface(surface, client: 1, compositor: 1, epoch: 1, surface: nextSurface + 1)
            else { return nil }
            nextSurface += 1; slots.append(Slot(output: id, backing: surface, handle: handle))
        }
        guard let index = slots.firstIndex(where: { $0.output == id && !$0.retiring && $0.state == .available }) else { return nil }
        let slot = slots.remove(at: index); slot.state = .writing; slots.append(slot)
        return slot.backing
    }
    public func submit(_ surface: IOSurface, output: Int) {
        guard output >= 0,
              let slot = slots.first(where: { $0.output == UInt64(output) + 1 && $0.backing === surface && $0.state == .writing }) else { return }
        guard !slot.retiring, let mode = modes[slot.output],
              gpu.compose(output: mode.output, generation: mode.generation, compositor: 1,
                          importedPlacements: [HostedImportedPlacement(surface: slot.handle, x: 0, y: 0)])
        else { slot.state = .available; cleanup(); return }
        slot.state = .copying; copying.insert(slot.output); waiting.insert(slot.output)
    }
    public func discardSurface(_ surface: IOSurface, output: Int) {
        guard output >= 0,
              let slot = slots.first(where: { $0.output == UInt64(output) + 1 && $0.backing === surface && $0.state == .writing }) else { return }
        slot.state = .available; cleanup()
    }
    func poll() {
        for output in Array(copying) {
            guard let result = gpu.collect(output: output) else { continue }
            copying.remove(output)
            for receipt in result.importedReceipts {
                guard let slot = slots.first(where: { $0.handle === receipt.surface }) else { continue }
                slot.state = .available
                if receipt.phase != .released { slot.retiring = true }
            }
            cleanup()
            if let frame = result.frame {
                offered[output] = frame.id; present(frame)
            } else { waiting.remove(output) }
        }
    }
    private func finish(_ result: HostedPresentation) {
        let id: HostedFrameID
        switch result { case .presented(let frame, _), .discarded(let frame): id = frame }
        guard offered[id.output] == id else { return }
        gpu.finishPresentation(result)
        offered.removeValue(forKey: id.output); waiting.remove(id.output)
    }
    private func retire(output: UInt64) {
        slots.filter { $0.output == output }.forEach { $0.retiring = true }
        cleanup()
    }
    private func cleanup() {
        slots.removeAll { $0.retiring && $0.state == .available && gpu.retireSurface($0.handle) }
    }
    public func shutdown() {
        timer?.cancel(); timer = nil
        for mode in modes.values { gpu.removeOutput(mode.output, generation: mode.generation); retire(output: mode.output) }
        modes.removeAll()
    }
    deinit { timer?.cancel() }
}
