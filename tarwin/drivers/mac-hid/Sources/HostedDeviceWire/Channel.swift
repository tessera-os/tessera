import Dispatch
import XPC

public protocol HostedDeviceChannel: AnyObject {
  var onReceive: ((UnsafeRawBufferPointer) -> Void)? { get set }
  func send(frame bytes: UnsafeRawBufferPointer)
  func close()
}

public final class LoopbackChannel: HostedDeviceChannel {
  public var onReceive: ((UnsafeRawBufferPointer) -> Void)?
  public weak var peer: LoopbackChannel?
  private var closed = false
  public init() {}
  public static func pair() -> (LoopbackChannel, LoopbackChannel) {
    let a = LoopbackChannel(), b = LoopbackChannel(); a.peer = b; b.peer = a
    return (a, b)
  }
  public func send(frame bytes: UnsafeRawBufferPointer) {
    if !closed, let peer, !peer.closed { peer.onReceive?(bytes) }
  }
  public func close() { closed = true; onReceive = nil }
}

public final class XPCDeviceChannel: HostedDeviceChannel, @unchecked Sendable {
  public var onReceive: ((UnsafeRawBufferPointer) -> Void)?
  public var onSharedMemory: ((xpc_object_t) -> Void)?
  private let connection: xpc_connection_t
  private let queue = DispatchQueue(label: "tarwin.devices.receive", qos: .userInteractive)
  public convenience init(serviceName: String = "dev.tessera.tarwind.devices") {
    self.init(connection: xpc_connection_create_mach_service(serviceName, nil, 0))
  }
  public convenience init(endpoint: xpc_endpoint_t) {
    self.init(connection: xpc_connection_create_from_endpoint(endpoint))
  }
  public init(connection: xpc_connection_t) {
    self.connection = connection
    xpc_connection_set_target_queue(connection, queue)
    xpc_connection_set_event_handler(connection) { [weak self] message in
      guard let self, xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
      var count = 0
      if let data = xpc_dictionary_get_data(message, "tw.frame", &count), count <= 32 + Wire.maximumPayload {
        let bytes = UnsafeRawBufferPointer(start: data, count: count)
        if let frame = FrameView(bytes), frame.kind == Wire.ping, frame.payload.isEmpty {
          withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { storage in
            let out = UnsafeMutableRawBufferPointer(storage)
            _ = FrameView.encode(family: frame.family, kind: Wire.pong, sequence: frame.sequence,
              timestampNs: frame.timestampNs, payload: .init(start: nil, count: 0), into: out)
            self.send(frame: UnsafeRawBufferPointer(out))
          }
        } else { self.onReceive?(bytes) }
      }
      if let memory = xpc_dictionary_get_value(message, "tw.shmem"), xpc_get_type(memory) == XPC_TYPE_SHMEM {
        self.onSharedMemory?(memory)
      }
    }
    xpc_connection_resume(connection)
  }
  public func send(frame bytes: UnsafeRawBufferPointer) {
    guard FrameView(bytes) != nil else { return }
    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_data(message, "tw.frame", bytes.baseAddress, bytes.count)
    xpc_connection_send_message(connection, message)
  }
  public func sendSharedMemory(_ region: UnsafeMutableRawPointer, count: Int) {
    guard count > 0 else { return }
    let memory = xpc_shmem_create(region, count)
    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_value(message, "tw.shmem", memory)
    xpc_connection_send_message(connection, message)
  }
  public func close() { xpc_connection_cancel(connection) }
}
