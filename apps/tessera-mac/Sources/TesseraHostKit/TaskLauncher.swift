import Foundation
import Darwin
import TarwinTaskTransport
import TarwinTaskProtocol
import TarwinHostedGate
import TarwinABI
import TarwinArchHosted

public final class DemoDeviceProvider: HostDeviceProvider, @unchecked Sendable {
    public let kind: String
    private let receive: HostPort
    private let handler: (GateRequest) -> GateReply
    private let lock = NSLock()
    private var active = true
    public init(kind: String, handler: @escaping (GateRequest) -> GateReply) throws {
        self.kind = kind; self.handler = handler; receive = try HostPort.receive()
        DispatchQueue(label: "tessera.device.\(kind)").async { [weak self] in
            while let self, self.running { GateWire.serve(on: self.receive.rawName, handler: self.handler) }
        }
    }
    private var running: Bool { lock.lock(); defer { lock.unlock() }; return active }
    public func close() { lock.lock(); active = false; lock.unlock() }
    public func open(slot: UInt32) throws -> HostPort {
        guard slot == 0 else { throw GateWire.WireError.invalid }; return try receive.makeSend()
    }
}

public final class TaskLauncher {
    private var task: SpawnedTask?
    private let registry: HostDeviceRegistry
    private let log: (String) -> Void
    private let input: () -> UInt64
    private let queue = DispatchQueue(label: "tessera.task.gate")
    private var worker: DispatchWorkItem?
    private let lock = NSLock()
    private var active = false
    private var running: Bool { lock.lock(); defer { lock.unlock() }; return active }
    public init(registry: HostDeviceRegistry, input: @escaping () -> UInt64 = { 0 }, log: @escaping (String) -> Void) {
        self.registry = registry; self.input = input; self.log = log
    }
    public func launch(executable: String, command: TaskCommand = .protect(address: TaskWindow.base, length: 16384, protection: 0)) throws {
        shutdown()
        let child = try TaskSpawner.spawn(executable: executable)
        task = child; lock.lock(); active = true; lock.unlock()
        log("TASK CHECKED IN pid=\(child.pid)")
        let item = DispatchWorkItem { [weak self, child] in
            while let self, self.running {
                GateWire.serve(on: child.gateReceive) { self.handle($0) }
            }
        }
        worker = item; queue.async(execute: item)
        let reply = try child.command(command).get()
        guard reply.status == KERN_SUCCESS else { shutdown(); throw GateWire.WireError.mach(reply.status) }
    }
    public func handle(_ request: GateRequest) -> GateReply {
        guard request.threadID == 1 else { return GateReply(result: CallResult(status: 1)) }
        if request.number == DemoCall.console {
            log("TASK: Hello from the Swift protocol test task"); return GateReply(result: CallResult(status: 0))
        }
        let kind: String
        switch request.number {
        case DemoCall.display: kind = "display"
        case DemoCall.input: return GateReply(result: CallResult(first: input()))
        default: log("TASK unsupported gate \(request.number)"); return GateReply(result: CallResult(status: 1))
        }
        do {
            guard let provider = registry.lookup(kind: kind) else { return GateReply(result: CallResult(status: 1)) }
            let port = try provider.open(slot: 0)
            return try GateWire.call(on: port.rawName, number: request.number, value: request.arguments[0])
        } catch { log("TASK device error: \(error)"); return GateReply(result: CallResult(status: 1)) }
    }
    public func shutdown() {
        guard let child = task else { return }
        _ = child.command(.terminate, timeout: 1000)
        lock.lock(); active = false; lock.unlock()
        queue.sync {}
        task = nil
        if waitpid(child.pid, nil, WNOHANG) == 0 { kill(child.pid, SIGKILL); while waitpid(child.pid, nil, 0) == -1 && errno == EINTR {} }
        worker = nil
    }
    deinit { shutdown() }
}
