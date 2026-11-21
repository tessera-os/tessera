import AppKit
import HostedDeviceWire
import MacHIDCapture
import MacAudioHost
import MacPowerHost
import TesseraHostKit

@MainActor final class AppDevices {
    let hid: HIDEventTranslator
    private let channels: [DeviceFrameChannel]
    private let audio: MacAudioHost
    private let power: MacPowerHost
    init(send: @escaping (Data) -> Void) {
        channels = (0..<3).map { _ in DeviceFrameChannel(send: send) }
        hid = HIDEventTranslator(channel: channels[0])
        audio = MacAudioHost(channel: channels[1], playback: nil, capture: nil)
        power = MacPowerHost(channel: channels[2], observe: false)
        channels[0].onReceive = { [weak hid] bytes in
            let data = Data(bytes)
            DispatchQueue.main.async { data.withUnsafeBytes { hid?.receive($0) } }
        }
        power.start()
    }
    func receive(_ data: Data) {
        data.withUnsafeBytes { bytes in
            guard let frame = FrameView(bytes), (1...3).contains(frame.family) else { return }
            channels[Int(frame.family - 1)].receive(data)
        }
    }
    func close() {
        hid.setFocused(false); audio.shutdown(); power.stop(); channels.forEach { $0.close() }
    }
}
