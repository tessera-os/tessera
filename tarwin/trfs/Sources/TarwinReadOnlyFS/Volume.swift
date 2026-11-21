/// An immutable image or partition view pinned for the mount's lifetime.
/// Reads must fail on replacement; a node never aliases a different image.
public protocol VolumeMedia {
  var byteCount: UInt64 { get }
  func read(at: UInt64, count: Int) -> [UInt8]?
}

public enum VolumeError: Error {
  case invalidMedia, io, notFound, notDirectory, isDirectory, invalidName, tooLarge
}

public protocol ReadOnlyNode {
  var id: UInt64 { get }
  var name: String { get }
  var size: Int { get }
  var directory: Bool { get }
}

public protocol ReadOnlyVolume {
  associatedtype Node: ReadOnlyNode
  static var maxNameBytes: UInt32 { get }
  var root: UInt64 { get }
  func node(_ id: UInt64) throws -> Node
  func lookup(parent: UInt64, name: [UInt8]) throws -> UInt64
  func entry(parent: UInt64, index: UInt64) throws -> Node?
  func bytes(node: UInt64, offset: UInt64, count: Int) throws -> [UInt8]
}
