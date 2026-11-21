import Foundation
import XCTest
import MacAudioHost
import XPC
@testable import TesseraHostKit

@objc private protocol AudioLinkReceiver {
    func attach(_ link: AudioLinkEnvelope, reply: @escaping (Bool) -> Void)
}

private final class AudioReceiver: NSObject, NSXPCListenerDelegate, AudioLinkReceiver {
    let host: MacAudioHost
    var connections: [NSXPCConnection] = []
    init(host: MacAudioHost) { self.host = host }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AudioLinkReceiver.self)
        connection.exportedObject = self; connections.append(connection); connection.resume(); return true
    }
    func attach(_ link: AudioLinkEnvelope, reply: @escaping (Bool) -> Void) {
        do { _ = try host.attach(link.object); reply(true) }
        catch { reply(false) }
    }
}

final class AudioTests: XCTestCase {
    func testRawXPCLinksAttachAndStartBothEndpoints() throws {
        var devices: HostedServiceDevices!
        let hostChannel = DeviceFrameChannel { data in
            DispatchQueue.main.async { try! devices.receive(data) }
        }
        let host = MacAudioHost(channel: hostChannel, useHAL: false, automaticPositions: false)
        let receiver = AudioReceiver(host: host)
        let listener = NSXPCListener.anonymous(); listener.delegate = receiver; listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: AudioLinkReceiver.self); connection.resume()
        defer {
            host.shutdown(); connection.invalidate(); receiver.connections.forEach { $0.invalidate() }; listener.invalidate()
        }
        let proxy = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { XCTFail("\($0)") } as? AudioLinkReceiver)
        devices = try HostedServiceDevices(registry: .init()) { hostChannel.receive($0) }
        let started = expectation(description: "both endpoints started via status 0x102"); started.expectedFulfillmentCount = 2
        try devices.startAudio(sendLink: { proxy.attach($0, reply: $1) }) { line in
            XCTAssertTrue(line.hasSuffix("started (0x102)"), line); started.fulfill()
        }
        wait(for: [started], timeout: 5)
        XCTAssertNotNil(host.playback); XCTAssertNotNil(host.capture)
        let rejected = expectation(description: "empty dictionary rejected")
        proxy.attach(AudioLinkEnvelope(xpc_dictionary_create(nil, nil, 0))) { attached in
            XCTAssertFalse(attached); rejected.fulfill()
        }
        wait(for: [rejected], timeout: 3)
    }
    func testFailedAttachDoesNotSendAudioCommands() throws {
        var sent = 0
        let devices = try HostedServiceDevices(registry: .init()) { _ in sent += 1 }
        let failed = expectation(description: "both failed attaches reported"); failed.expectedFulfillmentCount = 2
        try devices.startAudio(sendLink: { _, reply in reply(false) }) { line in
            XCTAssertTrue(line.hasSuffix("attach failed")); failed.fulfill()
        }
        wait(for: [failed], timeout: 2); XCTAssertEqual(sent, 0)
    }
}
