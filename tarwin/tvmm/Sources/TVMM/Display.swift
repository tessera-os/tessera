public struct PixelRect {
  public let x: UInt64
  public let y: UInt64
  public let width: UInt64
  public let height: UInt64

  public init(x: UInt64, y: UInt64, width: UInt64, height: UInt64) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}
public struct Scanout {
  public let width: UInt64
  public let height: UInt64
  public let surface: UInt64

  public init(width: UInt64, height: UInt64, surface: UInt64) {
    self.width = width
    self.height = height
    self.surface = surface
  }
}
public struct ImageResource {
  public let id: UInt64
  public let image: UInt64
  public let width: UInt64
  public let height: UInt64
  public internal(set) var pinned: UInt64
  public internal(set) var backingBytes: UInt64

  public init(
    id: UInt64, image: UInt64, width: UInt64, height: UInt64, pinned: UInt64, backingBytes: UInt64
  ) {
    self.id = id
    self.image = image
    self.width = width
    self.height = height
    self.pinned = pinned
    self.backingBytes = backingBytes
  }
}
func pixelRect(_ bytes: [UInt8]) -> PixelRect {
  return PixelRect(
    x: vword(bytes, 24, 4), y: vword(bytes, 28, 4), width: vword(bytes, 32, 4),
    height: vword(bytes, 36, 4))
}
func covered(_ r: PixelRect, _ image: ImageResource) -> Bool {
  return r.width != 0 && r.height != 0 && r.x < image.width && r.width <= image.width - r.x
    && r.y < image.height && r.height <= image.height - r.y
}
func little(_ out: inout [UInt8], _ n: UInt64, _ width: Int) {
  for i in 0..<width { out.append(UInt8((n >> UInt64(8 * i)) & 255)) }
}
func gpuReply(_ status: UInt64, _ command: [UInt8]) -> [UInt8] {
  var out: [UInt8] = []
  little(&out, status, 4)
  let fence = vword(command, 4, 4) & 1
  little(&out, fence, 4)
  little(&out, fence == 0 ? UInt64(0) : vword(command, 8, 8), 8)
  little(&out, 0, 8)
  return out
}

// A separately sandboxed device instance per guest. Host image IDs and surface
// handles never appear on the wire. Callbacks return only AFTER completion;
// the reply then echoes the request's fence. Destruction drains scanout users.
public struct DisplayController {
  public let limit: UInt64
  public let maxImages: Int
  public let outputs: [Scanout]
  public internal(set) var charged: UInt64 = 0
  public internal(set) var images: [ImageResource] = []

  public init(limit: UInt64, maxImages: Int, outputs: [Scanout]) {
    self.limit = limit
    self.maxImages = maxImages
    self.outputs = outputs
  }

  public mutating func control(
    _ cmd: [UInt8], _ space: UInt64, _ ram: GuestAperture,
    _ allocate: (UInt64, UInt64, UInt64) -> UInt64, _ destroy: (UInt64) -> Bool,
    _ pin: ([Segment]) -> UInt64, _ unpin: (UInt64) -> Void,
    _ transfer: (UInt64, UInt64, UInt64, PixelRect) -> Bool, _ flush: (UInt64, PixelRect) -> Bool,
    _ scanout: (UInt64, UInt64, PixelRect) -> Bool
  ) -> [UInt8]? {
    if cmd.count < 24 || space < 24 { return .none }
    if vword(cmd, 4, 4) > 1 || vword(cmd, 16, 4) != 0 { return .some(gpuReply(0x1205, cmd)) }
    let op = vword(cmd, 0, 4)
    if op == 0x100 {
      if cmd.count != 24 || space < 408 || outputs.count > 16 {
        return .some(gpuReply(0x1205, cmd))
      }
      var out = gpuReply(0x1101, cmd)
      for i in 0..<16 {
        little(&out, 0, 8)
        if i < outputs.count && outputs[i].surface != 0 {
          little(&out, outputs[i].width, 4)
          little(&out, outputs[i].height, 4)
          little(&out, 1, 4)
          little(&out, 0, 4)
        } else {
          little(&out, 0, 8)
          little(&out, 0, 8)
        }
      }
      return .some(out)
    }
    if cmd.count < 32 { return .some(gpuReply(0x1205, cmd)) }
    var id = vword(cmd, 24, 4)
    if op == 0x103 || op == 0x104 || op == 0x105 {
      if cmd.count != (op == 0x105 ? 56 : 48) { return .some(gpuReply(0x1205, cmd)) }
      id = vword(cmd, op == 0x105 ? 48 : (op == 0x103 ? 44 : 40), 4)
    }
    var found = images.count
    for i in 0..<images.count {
      if images[i].id == id {
        found = i
        break
      }
    }
    if op == 0x101 {
      if cmd.count != 40 || found < images.count || id == 0 { return .some(gpuReply(0x1205, cmd)) }
      let fmt = vword(cmd, 28, 4)
      let w = vword(cmd, 32, 4)
      let h = vword(cmd, 36, 4)
      if (fmt < 1 || (fmt > 4 && fmt != 67 && fmt != 68 && fmt != 121 && fmt != 134))
        || w == 0 || h == 0
      {
        return .some(gpuReply(0x1205, cmd))
      }
      if images.count >= maxImages || w > (limit - charged) / 4 / h {
        return .some(gpuReply(0x1201, cmd))
      }
      let image = allocate(fmt, w, h)
      if image == 0 { return .some(gpuReply(0x1201, cmd)) }
      images.append(
        ImageResource(id: id, image: image, width: w, height: h, pinned: 0, backingBytes: 0))
      charged += w * h * 4
    } else if op == 0x103 {
      let slot = vword(cmd, 40, 4)
      if slot >= UInt64(outputs.count) { return .some(gpuReply(0x1202, cmd)) }
      let rect = pixelRect(cmd)
      if id != 0 && (found == images.count || !covered(rect, images[found])) {
        return .some(gpuReply(0x1205, cmd))
      }
      let handle = id == 0 ? UInt64(0) : images[found].image
      if !scanout(outputs[Int(slot)].surface, handle, rect) { return .some(gpuReply(0x1200, cmd)) }
    } else {
      if found == images.count { return .some(gpuReply(0x1203, cmd)) }
      let image = images[found]
      if op == 0x102 {
        if cmd.count != 32 || !destroy(image.image) { return .some(gpuReply(0x1200, cmd)) }
        if image.pinned != 0 { unpin(image.pinned) }
        var remaining: [ImageResource] = []
        for r in images { if r.id != id { remaining.append(r) } }
        images = remaining
        charged -= image.width * image.height * 4
      } else if op == 0x106 {
        let n = vword(cmd, 28, 4)
        if image.pinned != 0 || n == 0 || n > 16384 || UInt64(cmd.count) != 32 + n * 16 {
          return .some(gpuReply(0x1205, cmd))
        }
        var spans: [Segment] = []
        var bytes: UInt64 = 0
        for i in 0..<Int(n) {
          let base = vword(cmd, 32 + i * 16, 8)
          let len = vword(cmd, 40 + i * 16, 4)
          if len == 0 || !containsSpan(ram, base, len) { return .some(gpuReply(0x1205, cmd)) }
          bytes += len
          spans.append(Segment(address: base, length: len, writable: false))
        }
        let token = pin(spans)
        if token == 0 { return .some(gpuReply(0x1201, cmd)) }
        images[found].pinned = token
        images[found].backingBytes = bytes
      } else if op == 0x107 {
        if cmd.count != 32 || image.pinned == 0 { return .some(gpuReply(0x1205, cmd)) }
        unpin(image.pinned)
        images[found].pinned = 0
        images[found].backingBytes = 0
      } else if op == 0x104 || op == 0x105 {
        let rect = pixelRect(cmd)
        if !covered(rect, image) { return .some(gpuReply(0x1205, cmd)) }
        if op == 0x105 {
          let offset = vword(cmd, 40, 8)
          let bytes = ((rect.height - 1) * image.width + rect.width) * 4
          if image.pinned == 0 || offset > image.backingBytes || bytes > image.backingBytes - offset
            || !transfer(image.image, image.pinned, offset, rect)
          {
            return .some(gpuReply(0x1205, cmd))
          }
        } else if !flush(image.image, rect) {
          return .some(gpuReply(0x1200, cmd))
        }
      } else {
        return .some(gpuReply(0x1200, cmd))
      }
    }
    return .some(gpuReply(0x1100, cmd))
  }
}
