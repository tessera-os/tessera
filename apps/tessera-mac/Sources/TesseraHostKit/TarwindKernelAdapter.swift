import Foundation
import TarwinArchHosted
import TarwindKernel

private final class KernelCallbacks: TarwindSystemVolumeVerifier, @unchecked Sendable {
    weak var host: KernelHost?
    let systemImage: SystemImage?
    var measuredSystemVolume = false
    init(_ host: KernelHost, systemImage: SystemImage?) {
        self.host = host; self.systemImage = systemImage
    }
    func systemVolumeRoot(path: String) throws -> [UInt8] {
        guard let systemImage, systemImage.url.path == path else {
            throw DiskError.io("System image is not pinned by the XPC service")
        }
        return systemImage.root
    }
    func measureSystemVolume(root: [UInt8]) -> Bool {
        measuredSystemVolume = root == systemImage?.root
        return measuredSystemVolume
    }
    func bootStage(_ name: String) { DispatchQueue.main.async { self.host?.bootStage(name) } }
    func ready() { DispatchQueue.main.async { self.host?.ready() } }
    func console(_ line: String) { DispatchQueue.main.async { self.host?.console(line) } }
    func panic(record: [UInt8]) { DispatchQueue.main.async { self.host?.panic(record: record) } }
}

public final class TarwindKernelAdapter: HostedKernel, KernelHost {
    private let devices: HostDevices
    private let systemImage: SystemImage?
    private let boot: (TarwindConfig, any TarwindHost) throws -> Tarwind
    private var kernel: Tarwind?
    private var desktop: StubKernel?
    private var callbacks: KernelCallbacks?
    private weak var host: KernelHost?
    public init(devices: HostDevices, registry: HostDeviceRegistry = HostDeviceRegistry(),
                systemImage: SystemImage? = nil) {
        self.devices = devices; self.systemImage = systemImage
        boot = { try Tarwind.boot($0, host: $1, devices: registry) }
    }
    init(devices: HostDevices, boot: @escaping (TarwindConfig, any TarwindHost) throws -> Tarwind) {
        self.devices = devices; self.boot = boot; systemImage = nil
    }
    public func start(config: KernelConfig, host: KernelHost) {
        shutdown(); self.host = host
        let callbacks = KernelCallbacks(host, systemImage: systemImage); self.callbacks = callbacks
        do {
            host.console("Kernel: TarwindKernel")
            kernel = try boot(TarwindConfig(diskPath: config.diskPath,
                systemImagePath: systemImage?.url.path ?? "", panicRecordPath: config.panicRecordPath,
                taskExecutablePath: config.taskExecutablePath), callbacks)
            if systemImage != nil {
                guard callbacks.measuredSystemVolume else { throw DiskError.io("System volume was not mounted") }
                host.console("TRFS system volume verified")
            }
            let desktop = StubKernel(devices: devices, desktopOnly: true)
            self.desktop = desktop; desktop.start(config: config, host: self)
        } catch {
            callbacks.host = nil
            kernel?.shutdown(); kernel = nil
            if systemImage == nil {
                host.console("Kernel boot failed: \(error); falling back to StubKernel")
                let fallback = StubKernel(devices: devices)
                desktop = fallback; fallback.start(config: config, host: host)
            } else {
                let message = "Kernel boot failed: \(error)"
                host.console(message)
                host.panic(record: Array(message.utf8))
            }
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
