import Foundation
import HostedDeviceWire
import MacHIDDriver
import MacAudioDriver
import MacAudioWire
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
    private var audioCommands: [UInt32: UInt16] = [:]
    private var audioStatus: ((String) -> Void)?
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
            channels[Int(frame.family - 1)].receive(data)
            if frame.family == 2, frame.kind == AudioKind.status, frame.payload.count == 8 {
                let endpoint = UInt32(Wire.read(frame.payload, 0, 4))
                let command = UInt16(Wire.read(frame.payload, 4, 2))
                let status = Wire.read(frame.payload, 6, 2)
                guard audioCommands[endpoint] == command, let endpoint = AudioEndpoint(rawValue: endpoint) else { return }
                guard status == 0 else {
                    audioCommands.removeValue(forKey: endpoint.rawValue)
                    audioStatus?("AUDIO \(endpoint) command \(command) failed: \(status)"); return
                }
                do {
                    if command == AudioKind.open {
                        audioCommands[endpoint.rawValue] = AudioKind.configure; try audio.configure(endpoint)
                    } else if command == AudioKind.configure {
                        audioCommands[endpoint.rawValue] = AudioKind.start; try audio.start(endpoint)
                    } else if command == AudioKind.start {
                        audioCommands.removeValue(forKey: endpoint.rawValue); audioStatus?("AUDIO \(endpoint) started (0x102)")
                    }
                } catch { audioStatus?("AUDIO \(endpoint): \(error)") }
            }
        }
    }
    public func startAudio(sendLink: (AudioLinkEnvelope, @escaping (Bool) -> Void) -> Void,
                           status: @escaping (String) -> Void) throws {
        audioStatus = status
        let configuration = AudioConfiguration(sampleRate: 48000, channels: 2, format: .f32)!
        for endpoint in AudioEndpoint.allCases {
            let object = try audio.makeLink(endpoint, configuration: configuration, capacity: 16384)
            sendLink(AudioLinkEnvelope(object)) { [weak self] attached in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard attached else { status("AUDIO \(endpoint) attach failed"); return }
                    do {
                        self.audioCommands[endpoint.rawValue] = AudioKind.open
                        try self.audio.open(endpoint)
                    } catch { status("AUDIO \(endpoint): \(error)") }
                }
            }
        }
    }
    public func inputEvents(output: DisplayOutput) -> [HostEvent] {
        var events: [HostEvent] = []
        while let report = hid.ring.pop() {
            let bytes = (0..<Int(report.reportLength)).map { report.bytes[$0] }
            events.append(HostEvent(kind: "hidReport.\(report.deviceId)", report: Data(bytes)))
            if report.deviceId == 3, report.reportLength == 13, report.bytes[0] & 2 != 0 {
                let x = UInt16(report.bytes[1]) | UInt16(report.bytes[2]) << 8
                let y = UInt16(report.bytes[3]) | UInt16(report.bytes[4]) << 8
                events.append(HostEvent(kind: "pointer", x: Double(x) / 65535 * Double(output.width),
                                        y: Double(y) / 65535 * Double(output.height)))
            }
            guard report.deviceId == 1, report.reportLength == 8 else { continue }
            let keys = Set((2..<8).map { report.bytes[$0] }.filter { $0 != 0 })
            let shift = report.bytes[0] & 0x22 != 0
            for key in keys.subtracting(held).sorted() {
                let value: UInt32?
                if (4...29).contains(key) { value = UInt32(key - 4) + (shift ? 65 : 97) }
                else if key == 44 { value = 32 }
                else if key == 40 { value = 10 }
                else if (30...38).contains(key) { value = UInt32(key - 30 + 49) }
                else if key == 39 { value = 48 }
                else { value = nil }
                if let value, let scalar = UnicodeScalar(value) { events.append(HostEvent(kind: "keyDown", text: String(scalar))) }
                if key == 42 { events.append(HostEvent(kind: "keyDown", keyCode: 51)) }
            }
            held = keys
        }
        return events
    }
    deinit { channels.forEach { $0.close() } }
}
