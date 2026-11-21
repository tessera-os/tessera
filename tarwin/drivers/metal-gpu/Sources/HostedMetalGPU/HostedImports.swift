import IOSurface
import Metal
import TvGpuGuest

public final class HostedImportedSurface: Sendable {
  public let client, surface, epoch: UInt64

  init(client: UInt64, surface: UInt64, epoch: UInt64) {
    self.client = client
    self.surface = surface
    self.epoch = epoch
  }
}

public struct HostedImportedPlacement: Sendable {
  public let surface: HostedImportedSurface
  public let x, y: Int32

  public init(surface: HostedImportedSurface, x: Int32, y: Int32) {
    self.surface = surface
    self.x = x
    self.y = y
  }
}

public struct HostedImportReceipt: Sendable {
  public let surface: HostedImportedSurface
  public let phase: MosaicPhase
}

final class HostImport {
  let handle: HostedImportedSurface
  let compositor: UInt64
  let backing: IOSurface
  let texture: any MTLTexture
  var inFlight = false
  var retiring = false

  init(
    handle: HostedImportedSurface, compositor: UInt64, backing: IOSurface, texture: any MTLTexture
  ) {
    self.handle = handle
    self.compositor = compositor
    self.backing = backing
    self.texture = texture
  }
}

struct HostImportCopy {
  let sources: [HostImport]
  let buffer: any MTLCommandBuffer

  static func begin(
    sources: [HostImport], placements: [HostedImportedPlacement], target: any MTLTexture,
    queue: any MTLCommandQueue
  ) -> HostImportCopy? {
    guard let buffer = queue.makeCommandBuffer() else { return nil }
    let pass = MTLRenderPassDescriptor()
    let color = pass.colorAttachments[0]!
    color.texture = target
    color.clearColor = MTLClearColorMake(0, 0, 0, 1)
    color.loadAction = .clear
    color.storeAction = .store
    guard let render = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    render.endEncoding()
    guard let blit = buffer.makeBlitCommandEncoder() else { return nil }
    for (source, placement) in zip(sources, placements) {
      let x = Int(placement.x), y = Int(placement.y)
      let left = max(0, x), top = max(0, y)
      let width = min(target.width, x + source.texture.width) - left
      let height = min(target.height, y + source.texture.height) - top
      guard width > 0, height > 0 else { continue }
      blit.copy(
        from: source.texture, sourceSlice: 0, sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: left - x, y: top - y, z: 0),
        sourceSize: MTLSize(width: width, height: height, depth: 1),
        to: target, destinationSlice: 0, destinationLevel: 0,
        destinationOrigin: MTLOrigin(x: left, y: top, z: 0))
    }
    blit.endEncoding()
    for source in sources { source.inFlight = true }
    buffer.commit()
    return HostImportCopy(sources: sources, buffer: buffer)
  }

  func collect() -> [HostedImportReceipt]? {
    let status = buffer.status
    guard status == .completed || status == .error else { return nil }
    let succeeded = status == .completed
    return sources.map { source in
      source.inFlight = false
      if !succeeded { source.retiring = true }
      return HostedImportReceipt(surface: source.handle, phase: succeeded ? .released : .failed)
    }
  }
}
