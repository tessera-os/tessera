/// Private A.5 metadata (not a public NodeInfo): a volume-local node, size,
/// type and a single name in bytes (the mount validates its filename encoding). Only the mount may turn a node into a handle.
public struct FsEntry: Equatable {
  public let id: UInt64, size: UInt64, directory: Bool, name: [UInt8]
  public init?(id: UInt64, size: UInt64, directory: Bool, name: [UInt8]) {
    guard id != 0, name.count <= 255, !name.contains(0), !name.contains(47), name != [46],
      name != [46, 46]
    else { return nil }
    self.id = id
    self.size = size
    self.directory = directory
    self.name = name
  }
  public func bytes() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 24)
    for i in 0..<8 {
      b[i] = UInt8(truncatingIfNeeded: id >> (i * 8))
      b[i + 8] = UInt8(truncatingIfNeeded: size >> (i * 8))
    }
    b[16] = directory ? 1 : 0
    b[17] = UInt8(name.count)
    return b + name
  }
  public init?(bytes b: [UInt8]) {
    guard b.count >= 24, b.count == 24 + Int(b[17]), b[16] <= 1, b[18..<24].allSatisfy({ $0 == 0 })
    else { return nil }
    var id: UInt64 = 0
    var size: UInt64 = 0
    for i in 0..<8 {
      id |= UInt64(b[i]) << (8 * i)
      size |= UInt64(b[i + 8]) << (8 * i)
    }
    self.init(id: id, size: size, directory: b[16] == 1, name: Array(b[24...]))
  }
}
