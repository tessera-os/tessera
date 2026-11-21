import Foundation
import TarwindKernel

private final class KernelCallbacks: TarwindHost, @unchecked Sendable {
    weak var host: KernelHost?
    init(_ host: KernelHost) { self.host = host }
    func bootStage(_ name: String) { DispatchQueue.main.async { self.host?.bootStage(name) } }
    func ready() { DispatchQueue.main.async { self.host?.ready() } }
    func console(_ line: String) { DispatchQueue.main.async { self.host?.console(line) } }
    func panic(record: [UInt8]) { DispatchQueue.main.async { self.host?.panic(record: record) } }
}

public final class TarwindKernelAdapter: HostedKernel, KernelHost {
    private let devices: HostDevices
    private let boot: (TarwindConfig, any TarwindHost) throws -> Tarwind
    private var kernel: Tarwind?
    private var desktop: StubKernel?
    private var callbacks: KernelCallbacks?
    private weak var host: KernelHost?
    public init(devices: HostDevices) { self.devices = devices; boot = Tarwind.boot }
    init(devices: HostDevices, boot: @escaping (TarwindConfig, any TarwindHost) throws -> Tarwind) {
        self.devices = devices; self.boot = boot
    }
    public func start(config: KernelConfig, host: KernelHost) {
        shutdown(); self.host = host
        let callbacks = KernelCallbacks(host); self.callbacks = callbacks
        do {
            host.console("Kernel: TarwindKernel")
            kernel = try boot(TarwindConfig(diskPath: config.diskPath,
                systemImagePath: config.systemImagePath, panicRecordPath: config.panicRecordPath,
                taskExecutablePath: config.taskExecutablePath), callbacks)
            let desktop = StubKernel(devices: devices, desktopOnly: true)
            self.desktop = desktop; desktop.start(config: config, host: self)
        } catch {
            callbacks.host = nil
            host.console("Kernel boot failed: \(error); falling back to StubKernel")
            let fallback = StubKernel(devices: devices)
            desktop = fallback; fallback.start(config: config, host: host)
        }
    }
    public func resize(_ output: DisplayOutput) { desktop?.resize(output) }
    public func shutdown() {
        callbacks?.host = nil; callbacks = nil
        kernel?.shutdown(); kernel = nil; desktop?.shutdown(); desktop = nil
    }
    public func bootStage(_ name: String) {}
    public func ready() {}
    public func console(_ line: String) { host?.console(line) }
    public func panic(record: [UInt8]) { host?.panic(record: record) }
    deinit { shutdown() }
}
