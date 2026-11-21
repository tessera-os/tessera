import IOSurface
import Metal
import TarwinGPU
import TarwinObject
import TarwinSyscall

@MainActor
public protocol HostedGPUAccounting: AnyObject {
  func charge(_ allocation: inout GpuAllocation, client: UInt64) -> Bool
  func release(_ allocation: inout GpuAllocation, client: UInt64) -> Bool
}

@MainActor
public protocol HostedFenceSink: AnyObject {
  func signal(_ value: UInt64) -> Bool
  func disconnect()
}

@MainActor
public final class HostedRenderFence {
  private let event: any MTLSharedEvent
  private let sink: any HostedFenceSink
  private var disconnected = false

  init?(device: any MTLDevice, sink: any HostedFenceSink) {
    guard let event = device.makeSharedEvent() else { return nil }
    self.event = event
    self.sink = sink
  }

  public var completedValue: UInt64 { event.signaledValue }

  func finish(_ value: UInt64) -> Bool {
    guard !disconnected, value > completedValue else { return false }
    event.signaledValue = value
    return sink.signal(value)
  }

  func disconnect() {
    guard !disconnected else { return }
    disconnected = true
    sink.disconnect()
  }

  public static func signal<S: FenceScheduler & ~Copyable>(
    _ value: UInt64, on fence: inout FenceObject, name: UInt64,
    table: HandleReadView, scheduler: inout S,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    fence.invoke(
      number: TarwinCall.fenceSignal, name: name, value: value, priority: 0,
      table: table, scheduler: &scheduler, retire: retire) == .ready
  }
}

enum MetalBacking {
  static func make(
    device: any MTLDevice, width: Int, height: Int
  ) -> (IOSurface, any MTLTexture)? {
    guard (1...16384).contains(width), (1...16384).contains(height),
      let surface = IOSurface(properties: [
        .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: 0x42475241,
      ]),
      let texture = texture(device: device, surface: surface)
    else { return nil }
    return (surface, texture)
  }

  static func texture(device: any MTLDevice, surface: IOSurface) -> (any MTLTexture)? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: surface.width, height: surface.height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget, .shaderRead]
    return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
  }
}
