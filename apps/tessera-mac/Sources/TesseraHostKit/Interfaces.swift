import Foundation
import IOSurface

public struct DisplayOutput: Codable, Equatable {
    public var id: Int, width: Int, height: Int
    public var scale: Double
    public init(id: Int = 0, width: Int = 1100, height: Int = 720, scale: Double = 1) {
        self.id = id; self.width = width; self.height = height; self.scale = scale
    }
}
public struct KernelConfig: Codable, Equatable {
    public var diskPath, systemImagePath, panicRecordPath, taskExecutablePath: String
    public var outputs: [DisplayOutput]
    public init(diskPath: String, systemImagePath: String, panicRecordPath: String,
                taskExecutablePath: String = "", outputs: [DisplayOutput] = [DisplayOutput()]) {
        self.diskPath = diskPath; self.systemImagePath = systemImagePath
        self.panicRecordPath = panicRecordPath; self.taskExecutablePath = taskExecutablePath; self.outputs = outputs
    }
}
public struct HostEvent: Codable {
    public var kind: String
    public var x: Double, y: Double
    public var text: String
    public var keyCode: UInt16
    public init(kind: String, x: Double = 0, y: Double = 0, text: String = "", keyCode: UInt16 = 0) {
        self.kind = kind; self.x = x; self.y = y; self.text = text; self.keyCode = keyCode
    }
}
public protocol KernelHost: AnyObject {
    func bootStage(_ name: String)
    func ready()
    func console(_ line: String)
    func panic(record: [UInt8])
}
public protocol DisplayProvider: AnyObject {
    func outputChanged(_ output: DisplayOutput)
    func present(_ surface: IOSurface, output: Int, frame: UInt64)
}
public protocol HIDProvider: AnyObject { func deliver(_ event: HostEvent) }
public final class HostDevices {
    public let display: DisplayProvider
    public weak var hid: HIDProvider?
    public init(display: DisplayProvider) { self.display = display }
}
public protocol HostedKernel: AnyObject {
    func start(config: KernelConfig, host: KernelHost)
    func shutdown()
}
public enum KernelFactory {
    public static func make(devices: HostDevices) -> HostedKernel { StubKernel(devices: devices) }
}
@objc public protocol TarwindControl {
    func start(_ config: Data)
    func shutdown()
    func restart()
    func recovery()
    func deliver(_ event: Data)
    func resize(_ output: Data)
    func status(_ reply: @escaping (String) -> Void)
}
@objc public protocol TesseraHost {
    func bootStage(_ name: String)
    func ready()
    func console(_ line: String)
    func panic(_ record: Data)
    func outputChanged(_ output: Data)
    func present(_ surface: IOSurface, output: Int, frame: UInt64)
    func audio(_ payload: Data)
    func power(_ payload: Data)
}
public enum XPCInterfaces {
    public static func host() -> NSXPCInterface {
        let interface = NSXPCInterface(with: TesseraHost.self)
        interface.setClasses(NSSet(object: IOSurface.self) as! Set<AnyHashable>,
            for: #selector(TesseraHost.present(_:output:frame:)), argumentIndex: 0, ofReply: false)
        return interface
    }
}
