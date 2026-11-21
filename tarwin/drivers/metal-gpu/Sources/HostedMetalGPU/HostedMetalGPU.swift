import IOSurface
import Metal
import MosaicMetal
import TarwinGPU
import TvGpuGuest

public struct HostedOutputMode: Equatable, Sendable {
  public let output, generation: UInt64
  public let width, height: Int
  public let scale: Double
  public let refreshHz: Int

  public init?(
    output: UInt64, generation: UInt64, width: Int, height: Int, scale: Double, refreshHz: Int
  ) {
    guard output > 0, generation > 0, (1...16384).contains(width), (1...16384).contains(height),
      scale.isFinite, scale > 0, refreshHz > 0
    else { return nil }
    self.output = output
    self.generation = generation
    self.width = width
    self.height = height
    self.scale = scale
    self.refreshHz = refreshHz
  }
}

public struct HostedFrameID: Equatable, Sendable {
  public let output, generation, serial: UInt64

  public init(output: UInt64, generation: UInt64, serial: UInt64) {
    self.output = output
    self.generation = generation
    self.serial = serial
  }
}

public struct HostedOutputFrame {
  public let id: HostedFrameID
  public let surface: IOSurface

  public init(id: HostedFrameID, surface: IOSurface) {
    self.id = id
    self.surface = surface
  }
}

public enum HostedPresentation: Equatable, Sendable {
  case presented(HostedFrameID, time: Double)
  case discarded(HostedFrameID)
}

public struct HostedPlacement {
  public let client: UInt64
  public let command: MetalSurfaceCommand
  public let x, y: Int32

  public init(client: UInt64, command: MetalSurfaceCommand, x: Int32, y: Int32) {
    self.client = client
    self.command = command
    self.x = x
    self.y = y
  }
}

public struct HostedCompositionResult {
  public let receipts: [MosaicReceipt]
  public let frame: HostedOutputFrame?
}

@MainActor
public final class HostedMetalGPU {
  private struct SurfaceKey: Hashable {
    let client, surface: UInt64
  }

  public let device: any MTLDevice
  private let queue: any MTLCommandQueue
  private let accounting: any HostedGPUAccounting
  private var allocationID: UInt64 = 0
  private var surfaces: [SurfaceKey: Surface] = [:]
  private var usedEpochs: [SurfaceKey: UInt64] = [:]
  private var outputs: [UInt64: Output] = [:]

  public init?(device: any MTLDevice, accounting: any HostedGPUAccounting) {
    guard let queue = device.makeCommandQueue() else { return nil }
    self.device = device
    self.queue = queue
    self.accounting = accounting
  }

  public func register(
    client: UInt64, compositor: UInt64, epoch: UInt64, surface: UInt64,
    width: UInt32, height: UInt32, fence sink: any HostedFenceSink
  ) -> (MosaicGrant, HostedRenderFence)? {
    let key = SurfaceKey(client: client, surface: surface)
    guard surfaces[key] == nil, epoch > usedEpochs[key, default: 0], allocationID < .max,
      client != 0, compositor != 0, surface != 0,
      let (backing, texture) = MetalBacking.make(
        device: device, width: Int(width), height: Int(height)),
      let grant = MosaicGrant(
        client: client, compositor: compositor, epoch: epoch, surface: surface,
        width: width, height: height, chargedBytes: UInt64(backing.allocationSize)),
      let gpu = MetalSurfaceDevice(grant: grant, queue: queue, target: texture),
      let fence = HostedRenderFence(device: device, sink: sink),
      let allocation = GpuAllocation(
        id: allocationID + 1, bytes: UInt64(backing.allocationSize), backing: .system)
    else { return nil }

    allocationID += 1
    let entry = Surface(grant: grant, gpu: gpu, texture: texture, fence: fence, allocation: allocation)
    guard accounting.charge(&entry.allocation, client: client) else { return nil }
    surfaces[key] = entry
    usedEpochs[key] = epoch
    return (grant, fence)
  }

  public func submit(
    _ bytes: [UInt8], client: UInt64, surface: UInt64, now: UInt64,
    deadline: UInt64, readable: Set<UInt64> = []
  ) -> MosaicSubmission {
    let key = SurfaceKey(client: client, surface: surface)
    guard let entry = surfaces[key], !entry.retiring, entry.pending == nil, now < deadline,
      let command = MetalSurfaceCommand(bytes: bytes, grant: entry.grant),
      command.deadline == deadline,
      !surfaces.values.contains(where: { $0.readSource == key })
    else { return .notSubmitted }

    var readSource: SurfaceKey?
    let result = entry.gpu?.submit(bytes: bytes, by: client) { id in
      let sourceKey = SurfaceKey(client: client, surface: id)
      guard sourceKey != key, readable.contains(id), let source = surfaces[sourceKey],
        !source.retiring, source.pending == nil, source.grant.epoch == entry.grant.epoch,
        source.grant.compositor == entry.grant.compositor
      else { return nil }
      readSource = sourceKey
      return source.texture
    } ?? .notSubmitted
    if case .accepted = result {
      entry.pending = command
      entry.readSource = readSource
    }
    return result
  }

  public func pollRenders() -> [MosaicReceipt] {
    var receipts: [MosaicReceipt] = []
    for entry in surfaces.values {
      guard let command = entry.pending, let receipt = entry.gpu?.poll() else { continue }
      entry.readSource = nil
      if receipt.phase == .rendered, !entry.retiring, entry.fence.finish(receipt.serial) {
        entry.rendered = true
        receipts.append(receipt)
      } else {
        lose(entry)
        receipts.append(MosaicReceipt(.failed, command: command))
      }
    }
    return receipts
  }

  /// Stop admission and refund only after submissions, copies and retained hit maps drain.
  @discardableResult
  public func retireSurface(client: UInt64, surface: UInt64, epoch: UInt64) -> Bool {
    let key = SurfaceKey(client: client, surface: surface)
    guard let entry = surfaces[key], entry.grant.epoch == epoch else { return false }
    entry.retiring = true
    guard (entry.pending == nil || entry.rendered),
      !surfaces.values.contains(where: { $0.readSource == key }),
      !outputs.values.contains(where: { $0.pending?.keys.contains(key) == true
        || $0.latched?.keys.contains(key) == true })
    else { return false }
    lose(entry)
    entry.gpu = nil
    entry.texture = nil
    guard accounting.release(&entry.allocation, client: client) else { return false }
    surfaces.removeValue(forKey: key)
    return true
  }

  public func configure(_ mode: HostedOutputMode, compositor: UInt64) -> Bool {
    guard compositor != 0 else { return false }
    let output = outputs[mode.output] ?? Output()
    guard mode.generation > output.generation else { return false }
    invalidate(output, generation: mode.generation)
    output.mode = mode
    output.compositor = compositor
    outputs[mode.output] = output
    return true
  }

  @discardableResult
  public func removeOutput(_ id: UInt64, generation: UInt64) -> Bool {
    guard let output = outputs[id], output.generation == generation, output.mode != nil else {
      return false
    }
    invalidate(output, generation: generation)
    return true
  }

  private func invalidate(_ output: Output, generation: UInt64) {
    output.latched?.composition.retire()
    output.latched = nil
    output.mode = nil
    output.generation = generation
  }

  public func compose(
    output id: UInt64, generation: UInt64, compositor: UInt64, placements: [HostedPlacement]
  ) -> Bool {
    guard let output = outputs[id], let mode = output.mode, mode.generation == generation,
      output.compositor == compositor, output.pending == nil, output.serial < .max,
      placements.count <= 256
    else { return false }
    var layers: [MosaicLayer] = []
    var keys: [SurfaceKey] = []
    for p in placements {
      let key = SurfaceKey(client: p.client, surface: p.command.surface)
      guard let surface = surfaces[key], !surface.retiring, surface.rendered,
        surface.pending == p.command, let gpu = surface.gpu
      else { return false }
      keys.append(key)
      layers.append(MosaicLayer(device: gpu, frame: p.command, x: p.x, y: p.y))
    }
    guard let (surface, texture) = MetalBacking.make(
      device: device, width: mode.width, height: mode.height),
      let copy = MosaicComposition.begin(
        by: compositor, backbuffer: texture, queue: queue, layers: layers)
    else { return false }
    output.serial += 1
    let frame = HostedOutputFrame(
      id: HostedFrameID(output: id, generation: generation, serial: output.serial), surface: surface)
    output.pending = Composition(frame: frame, composition: copy, keys: keys)
    return true
  }

  /// A successful collect returns producer receipts even if the output was resized.
  /// It never changes the latched hit map.
  public func collect(output id: UInt64) -> HostedCompositionResult? {
    guard let output = outputs[id], let pending = output.pending, !pending.offered,
      let receipts = pending.composition.collect()
    else { return nil }
    var failed = false
    for (key, receipt) in zip(pending.keys, receipts) {
      guard let surface = surfaces[key] else { continue }
      if receipt.phase == .released {
        surface.pending = nil
        surface.rendered = false
      } else {
        failed = true
        lose(surface)
      }
    }
    guard !failed, output.mode?.generation == pending.frame.id.generation else {
      pending.composition.retire()
      output.pending = nil
      return HostedCompositionResult(receipts: receipts, frame: nil)
    }
    pending.offered = true
    return HostedCompositionResult(receipts: receipts, frame: pending.frame)
  }

  /// Only the trusted display transport may acknowledge a frame.
  @discardableResult
  public func finishPresentation(_ result: HostedPresentation) -> Bool {
    let id: HostedFrameID
    switch result {
    case .presented(let frame, _), .discarded(let frame): id = frame
    }
    guard let output = outputs[id.output], let pending = output.pending,
      pending.offered, pending.frame.id == id
    else { return false }
    output.pending = nil
    if case .presented(_, let time) = result, time.isFinite, time > 0,
      output.mode?.generation == id.generation,
      pending.composition.latch(by: output.compositor)
    {
      output.latched?.composition.retire()
      output.latched = pending
      return true
    }
    pending.composition.retire()
    if case .discarded = result { return true }
    return false
  }

  public func hit(output id: UInt64, generation: UInt64, x: UInt32, y: UInt32) -> MosaicHit? {
    guard let output = outputs[id], output.mode?.generation == generation,
      let hit = output.latched?.composition.hit(x: x, y: y),
      let surface = surfaces[SurfaceKey(client: hit.client, surface: hit.surface)],
      !surface.retired, !surface.retiring, surface.grant.epoch == hit.epoch
    else { return nil }
    return hit
  }

  private func lose(_ entry: Surface) {
    entry.retiring = true
    entry.retired = true
    entry.gpu?.revoke()
    entry.fence.disconnect()
    entry.pending = nil
    entry.rendered = false
  }

  private final class Surface {
    let grant: MosaicGrant
    var gpu: MetalSurfaceDevice?
    var texture: (any MTLTexture)?
    let fence: HostedRenderFence
    var allocation: GpuAllocation
    var pending: MetalSurfaceCommand?
    var readSource: SurfaceKey?
    var rendered = false
    var retiring = false
    var retired = false

    init(
      grant: MosaicGrant, gpu: MetalSurfaceDevice, texture: any MTLTexture,
      fence: HostedRenderFence, allocation: consuming GpuAllocation
    ) {
      self.grant = grant
      self.gpu = gpu
      self.texture = texture
      self.fence = fence
      self.allocation = allocation
    }
  }

  private final class Output {
    var mode: HostedOutputMode?
    var compositor: UInt64 = 0
    var generation: UInt64 = 0
    var serial: UInt64 = 0
    var pending: Composition?
    var latched: Composition?
  }

  private final class Composition {
    let frame: HostedOutputFrame
    let composition: MosaicComposition
    let keys: [SurfaceKey]
    var offered = false

    init(frame: HostedOutputFrame, composition: MosaicComposition, keys: [SurfaceKey]) {
      self.frame = frame
      self.composition = composition
      self.keys = keys
    }
  }
}
