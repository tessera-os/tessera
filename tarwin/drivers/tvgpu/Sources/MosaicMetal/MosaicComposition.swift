#if canImport(Metal)
  import Metal
  import TvGpuGuest

  public struct MosaicLayer {
    public let device: MetalSurfaceDevice, frame: MetalSurfaceCommand, x, y: Int32
    public init(device: MetalSurfaceDevice, frame: MetalSurfaceCommand, x: Int32, y: Int32) {
      self.device = device
      self.frame = frame
      self.x = x
      self.y = y
    }
  }
  public struct MosaicHit: Equatable {
    public let client, surface, epoch: UInt64
    public let x, y: UInt32
  }

  /// One compositor-owned, opaque BGRA8 frame. Layers are back-to-front.
  /// Source/target backing stores must be distinct retained allocations, not
  /// subresource aliases. The compositor serializes acquisition, revocation,
  /// completion and input. This object is not exposed to surface clients.
  public final class MosaicComposition {
    private let compositor: UInt64, layers: [MosaicLayer], grants: [MosaicGrant]
    private let target: any MTLTexture, copy: any MTLCommandBuffer
    private var finished = false, latched = false, removed = false
    private init(
      _ owner: UInt64, _ target: any MTLTexture, _ layers: [MosaicLayer],
      _ grants: [MosaicGrant], _ copy: any MTLCommandBuffer
    ) {
      compositor = owner
      self.layers = layers
      self.grants = grants
      self.target = target
      self.copy = copy
    }

    /// The output manager must exclusively acquire an unscanned backbuffer
    /// before this call. Failed admission submits nothing and takes no holds.
    public static func begin(
      by owner: UInt64, backbuffer: any MTLTexture, queue: any MTLCommandQueue,
      layers: [MosaicLayer]
    ) -> MosaicComposition? {
      guard owner != 0, layers.count <= 256,
        backbuffer.device.registryID == queue.device.registryID,
        backbuffer.pixelFormat == .bgra8Unorm, backbuffer.textureType == .type2D,
        !backbuffer.isFramebufferOnly, backbuffer.storageMode != .memoryless,
        backbuffer.width <= 16384, backbuffer.height <= 16384,
        backbuffer.usage.contains(.renderTarget),
        let b = queue.makeCommandBuffer()
      else { return nil }
      var grants: [MosaicGrant] = []
      var images: [any MTLTexture] = []
      for l in layers {
        guard let (g, t) = l.device.sample(by: owner, command: l.frame),
          t !== backbuffer, t.device.registryID == queue.device.registryID,
          !grants.contains(where: { $0.surface == g.surface })
        else { return nil }
        images.append(t)
        grants.append(g)
      }

      let pass = MTLRenderPassDescriptor()
      let color: MTLClearColor = MTLClearColorMake(0, 0, 0, 1)
      pass.colorAttachments[0].texture = backbuffer
      pass.colorAttachments[0].clearColor = color
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      guard let r = b.makeRenderCommandEncoder(descriptor: pass) else { return nil }
      r.endEncoding()
      guard let e = b.makeBlitCommandEncoder() else { return nil }
      for (i, l) in layers.enumerated() {
        let x = Int64(l.x)
        let y = Int64(l.y)
        let g = grants[i]
        let left = max(0, x)
        let top = max(0, y)
        let w = min(Int64(backbuffer.width), x + Int64(g.width)) - left
        let h = min(Int64(backbuffer.height), y + Int64(g.height)) - top
        if w <= 0 || h <= 0 { continue }
        e.copy(
          from: images[i], sourceSlice: 0, sourceLevel: 0,
          sourceOrigin: .init(x: Int(left - x), y: Int(top - y), z: 0),
          sourceSize: .init(width: Int(w), height: Int(h), depth: 1),
          to: backbuffer, destinationSlice: 0, destinationLevel: 0,
          destinationOrigin: .init(x: Int(left), y: Int(top), z: 0))
      }
      e.endEncoding()
      for l in layers { l.device.holdForCopy() }
      let result = MosaicComposition(owner, backbuffer, layers, grants, b)
      b.commit()
      return result
    }

    /// nil = not terminal or already collected. GPU completion owns source
    /// release; a display flip is not inferred. Errors retire the whole frame.
    public func collect() -> [MosaicReceipt]? {
      guard !finished else { return nil }
      let status = copy.status
      guard status == .completed || status == .error else { return nil }
      finished = true
      if status == .error { removed = true }
      var receipts = [MosaicReceipt]()
      for l in layers {
        l.device.endCopy()
        if !removed,
          let r = l.device.release(by: compositor, epoch: l.frame.epoch, serial: l.frame.serial)
        {
          receipts.append(r)
        } else {
          l.device.revoke()
          removed = true
          receipts.append(MosaicReceipt(.failed, command: l.frame))
        }
      }
      return receipts
    }

    /// The trusted output manager calls this only for the generation whose
    /// backbuffer was actually latched. Until then it retains the old hit map.
    public func latch(by owner: UInt64) -> Bool {
      guard owner == compositor, finished, !removed, !latched else { return false }
      latched = true
      return true
    }
    public func retire() {
      removed = true
      latched = false
    }
    /// Input originates at the trusted seat router. It must check the current
    /// surface/input grant again before delivering an event to the client.
    public func hit(x: UInt32, y: UInt32) -> MosaicHit? {
      guard latched, !removed, x < target.width, y < target.height else { return nil }
      for i in layers.indices.reversed() {
        let dx = Int64(x) - Int64(layers[i].x)
        let dy = Int64(y) - Int64(layers[i].y)
        let g = grants[i]
        if dx >= 0 && dy >= 0 && dx < g.width && dy < g.height {
          return MosaicHit(
            client: g.client, surface: g.surface, epoch: g.epoch, x: UInt32(dx), y: UInt32(dy))
        }
      }
      return nil
    }
  }
#endif
