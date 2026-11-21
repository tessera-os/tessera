#if canImport(Metal)
  import Metal
  import TvGpuGuest

  /// Device-side implementation for a user-mode Metal provider. One instance
  /// per preauthorized surface; call on its serialized driver queue. The
  /// compositor retains exclusive scanout ownership until it returns release.
  public final class MetalSurfaceDevice {
    private let grant: MosaicGrant, queue: any MTLCommandQueue, target: any MTLTexture
    private var issued: UInt64 = 0, submitted: MetalSurfaceCommand?, buffer: (any MTLCommandBuffer)?
    private var delivered = false, retired = false, composing = false
    public init?(grant: MosaicGrant, queue: any MTLCommandQueue, target: any MTLTexture) {
      guard Self.compatible(target, grant, queue.device), target.usage.contains(.renderTarget),
        !target.isFramebufferOnly
      else { return nil }
      self.grant = grant
      self.queue = queue
      self.target = target
    }
    private static func compatible(_ t: any MTLTexture, _ g: MosaicGrant, _ device: any MTLDevice)
      -> Bool
    {
      t.device.registryID == device.registryID && t.textureType == .type2D
        && t.pixelFormat == .bgra8Unorm && t.sampleCount == 1 && t.width == Int(g.width)
        && t.height == Int(g.height) && t.storageMode != .memoryless
    }
    /// resolveRead validates the retained source belongs to this client, is
    /// readable and does not alias the destination backing (including views).
    /// No shader, user pointer, or unverified pipeline crosses this interface.
    public func submit(
      bytes: [UInt8], by client: UInt64,
      resolveRead: (UInt64) -> (any MTLTexture)?
    ) -> MosaicSubmission {
      guard !retired, submitted == nil, client == grant.client,
        let c = MetalSurfaceCommand(bytes: bytes, grant: grant), c.serial > issued,
        let b = queue.makeCommandBuffer()
      else { return .notSubmitted }
      switch c.operation {
      case .clear(let value):
        func channel(_ shift: Int) -> Double { Double((value >> shift) & 255) / 255 }
        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.texture = target
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColorMake(channel(16), channel(8), channel(0), channel(24))
        guard let e = b.makeRenderCommandEncoder(descriptor: pass) else { return .notSubmitted }
        e.endEncoding()
      case .blit(let id):
        guard let t = resolveRead(id), Self.compatible(t, grant, queue.device),
          !t.isFramebufferOnly, t !== target,
          let e = b.makeBlitCommandEncoder()
        else { return .notSubmitted }
        e.copy(
          from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
          sourceSize: .init(width: target.width, height: target.height, depth: 1),
          to: target, destinationSlice: 0, destinationLevel: 0,
          destinationOrigin: .init(x: 0, y: 0, z: 0))
        e.endEncoding()
      }
      issued = c.serial
      submitted = c
      buffer = b
      delivered = false
      b.commit()
      return .accepted
    }
    /// Called from the driver completion loop. A scheduled buffer is not a
    /// completion and must not signal the exported timeline.
    public func poll() -> MosaicReceipt? {
      guard !retired, !delivered, let command = submitted, let b = buffer else { return nil }
      switch b.status {
      case .completed:
        delivered = true
        return MosaicReceipt(.rendered, command: command)
      case .error:
        retired = true
        return MosaicReceipt(.failed, command: command)
      default: return nil
      }
    }
    public func release(by compositor: UInt64, epoch: UInt64, serial: UInt64) -> MosaicReceipt? {
      guard !retired, !composing, delivered, compositor == grant.compositor, let c = submitted,
        epoch == c.epoch, serial == c.serial
      else { return nil }
      buffer = nil
      submitted = nil
      delivered = false
      return MosaicReceipt(.released, command: c)
    }
    public func revoke() { retired = true }

    func sample(by compositor: UInt64, command: MetalSurfaceCommand) -> (
      MosaicGrant, any MTLTexture
    )? {
      guard !composing, !retired, delivered, compositor == grant.compositor, submitted == command
      else { return nil }
      return (grant, target)
    }
    func holdForCopy() { composing = true }
    func endCopy() { composing = false }
  }
#endif
