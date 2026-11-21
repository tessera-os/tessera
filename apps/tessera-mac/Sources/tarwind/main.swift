import Foundation
import Darwin
import TesseraHostKit
import IOSurface
import TarwinArchHosted

private var panicFD: Int32 = -1
private func crashHandler(_ signal: Int32) {
    let message: StaticString = "tarwind fatal signal; hosted kernel terminated\n"
    if panicFD >= 0 { _ = write(panicFD, message.utf8Start, message.utf8CodeUnitCount); _ = fsync(panicFD) }
    _exit(128 + signal)
}
final class Service: NSObject, NSXPCListenerDelegate, TarwindControl, KernelHost, DisplayProvider {
    var connection: NSXPCConnection?
    var config: KernelConfig?
    var kernel: HostedKernel?
    let registry = HostDeviceRegistry()
    var deviceDrivers: HostedServiceDevices?
    var inputTimer: DispatchSourceTimer?
    var launcher: TaskLauncher?
    lazy var devices = HostDevices(display: self)
    var state = "stopped"
    var remote: TesseraHost? { connection?.remoteObjectProxyWithErrorHandler { NSLog("Host: %@", "\($0)") } as? TesseraHost }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard self.connection == nil else { return false }
        self.connection = connection
        connection.exportedInterface = NSXPCInterface(with: TarwindControl.self)
        connection.exportedObject = self; connection.remoteObjectInterface = XPCInterfaces.host()
        connection.invalidationHandler = { exit(0) }; connection.resume(); return true
    }
    func start(_ data: Data) {
        DispatchQueue.main.async {
            do {
                let config = try JSONDecoder().decode(KernelConfig.self, from: data)
                self.shutdownKernel(); self.config = config
                self.deviceDrivers = try HostedServiceDevices(registry: self.registry) { [weak self] data in
                    self?.remote?.deviceFrame(["tw.frame": data])
                }
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now(), repeating: 1.0 / 60)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    let value = self.deviceDrivers?.nextCharacter() ?? 0
                    if value != 0, let scalar = UnicodeScalar(UInt32(value)) {
                        self.devices.hid?.deliver(HostEvent(kind: "keyDown", text: String(scalar)))
                    }
                }
                self.inputTimer = timer; timer.resume()
                panicFD = Darwin.open(config.panicRecordPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
                self.state = "booting"; self.kernel = KernelFactory.make(devices: self.devices)
                self.kernel?.start(config: config, host: self)
            } catch { self.panic(record: Array("Invalid config: \(error)".utf8)) }
        }
    }
    func shutdownKernel() {
        launcher?.shutdown(); launcher = nil
        inputTimer?.cancel(); inputTimer = nil
        kernel?.shutdown(); kernel = nil; state = "stopped"
        if panicFD >= 0 { close(panicFD); panicFD = -1 }
    }
    func deviceFrame(_ dictionary: [String: Data]) {
        guard let data = dictionary["tw.frame"] else { return }
        DispatchQueue.main.async {
            do { try self.deviceDrivers?.receive(data) }
            catch { self.console("Device frame rejected: \(error)") }
        }
    }
    func shutdown() { DispatchQueue.main.async { self.shutdownKernel() } }
    func restart() { if let config, let data = try? JSONEncoder().encode(config) { start(data) } }
    func recovery() { console("Recovery requested (stub)"); restart() }
    func deliver(_ data: Data) {
        DispatchQueue.main.async { if let event = try? JSONDecoder().decode(HostEvent.self, from: data) { self.devices.hid?.deliver(event) } }
    }
    func resize(_ data: Data) {
        DispatchQueue.main.async { if let output = try? JSONDecoder().decode(DisplayOutput.self, from: data) { (self.kernel as? StubKernel)?.resize(output) } }
    }
    func status(_ reply: @escaping (String) -> Void) { DispatchQueue.main.async { reply(self.state) } }
    func bootStage(_ name: String) { remote?.bootStage(name) }
    func ready() {
        do {
            let launcher = TaskLauncher(registry: registry) { [weak self] in self?.console($0) }
            self.launcher = launcher
            try launcher.launch(executable: config!.taskExecutablePath)
            console("TASK COMMAND protect: success")
            state = "ready"; remote?.ready()
        } catch { panic(record: Array("Task launch failed: \(error)".utf8)) }
    }
    func console(_ line: String) { remote?.console(line) }
    func panic(record: [UInt8]) {
        if let config { try? Data(record).write(to: URL(fileURLWithPath: config.panicRecordPath)) }
        remote?.panic(Data(record)); state = "panic"
    }
    func outputChanged(_ output: DisplayOutput) { if let data = try? JSONEncoder().encode(output) { remote?.outputChanged(data) } }
    func present(_ surface: IOSurface, output: Int, frame: UInt64) { remote?.present(surface, output: output, frame: frame) }
}
for number in [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGFPE] { signal(number, crashHandler) }
let service = Service()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
RunLoop.main.run()
