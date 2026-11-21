import Foundation
import HostedDeviceWire
import MacHIDDriver
import MacAudioDriver
import MacPowerDriver
import TarwinArchHosted

public enum DeviceChannelError: Error { case invalidFrame }

private final class PowerPageStorage {
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 4096)
    deinit { pointer.deallocate() }
}

public final class DeviceFrameChannel: HostedDeviceChannel {
    public var onReceive: ((UnsafeRawBufferPointer) -> Void)?
    private let sender: (Data) -> Void
    public init(send: @escaping (Data) -> Void) { sender = send }
    public func send(frame bytes: UnsafeRawBufferPointer) { sender(Data(bytes)) }
    public func receive(_ data: Data) { data.withUnsafeBytes { onReceive?($0) } }
    public func close() { onReceive = nil }
}

public final class HostedServiceDevices {
    public let registry: HostDeviceRegistry
    private let channels: [DeviceFrameChannel]
    private let providers: [any HostDeviceProvider]
    private let hid: MacHIDDriver
    private let audio: MacAudioDriver
    private let power: MacPowerDriver
    private let page: PowerPageStorage
    private var held: Set<UInt8> = []
    private var pending: [UInt64] = []
    public init(registry: HostDeviceRegistry, send: @escaping (Data) -> Void) throws {
        self.registry = registry
        channels = (0..<3).map { _ in DeviceFrameChannel(send: send) }
        hid = MacHIDDriver(channel: channels[0], ring: InputRing(capacity: 256)!)
        audio = MacAudioDriver(channel: channels[1])
        let storage = PowerPageStorage(); page = storage
        guard let power = MacPowerDriver(channel: channels[2], initializing: UnsafeMutableRawBufferPointer(start: storage.pointer, count: 4096)) else {
            throw DeviceChannelError.invalidFrame
        }
        power.onPublished = { withExtendedLifetime(storage) {} }
        self.power = power
        providers = [try MacHIDDeviceProvider(driver: hid), try MacAudioDeviceProvider(driver: audio), try MacPowerDeviceProvider(driver: power)]
        providers.forEach { registry.register($0) }
    }
    public func receive(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let frame = FrameView(bytes), (1...3).contains(frame.family) else { throw DeviceChannelError.invalidFrame }
            let provider = providers[Int(frame.family - 1)]
            let port = try provider.open(slot: 0)
            try HostedDriverEndpoint.send(frame: bytes, to: port)
        }
    }
    // A demo-only US keyboard consumer; the real input service consumes HID reports.
    public func nextCharacter() -> UInt64 {
        while let report = hid.ring.pop() {
            guard report.deviceId == 1, report.reportLength == 8 else { continue }
            let keys = Set((2..<8).map { report.bytes[$0] }.filter { $0 != 0 })
            let shift = report.bytes[0] & 0x22 != 0
            for key in keys.subtracting(held).sorted() {
                if (4...29).contains(key) { pending.append(UInt64(key - 4) + (shift ? 65 : 97)) }
                else if key == 44 { pending.append(32) }
                else if key == 40 { pending.append(10) }
                else if (30...38).contains(key) { pending.append(UInt64(key - 30 + 49)) }
                else if key == 39 { pending.append(48) }
            }
            held = keys
        }
        return pending.isEmpty ? 0 : pending.removeFirst()
    }
    deinit { channels.forEach { $0.close() } }
}
