// Compile-only early-mount probe. Read-only plaintext sectors here are the
// output of a trusted block transform, not an unverified raw media mapping.
import EarlyVolume

private struct ReadView: TrfsMedia {
  let disk: UnsafeRawBufferPointer
  var blocks: UInt64 { UInt64(disk.count / 4096) }
  func read(_ block: UInt64, into dst: UnsafeMutableRawBufferPointer) -> Bool {
    guard block < blocks, dst.count == 4096 else { return false }
    let i = Int(block) * 4096
    dst.copyMemory(from: .init(rebasing: disk[i..<(i + 4096)]))
    return true
  }
  func write(_ block: UInt64, from src: UnsafeRawBufferPointer) -> Bool { false }
  func flush() -> Bool { false }
  func sha256(_ bytes: UnsafeRawBufferPointer) -> TrfsDigest {
    let digest = measurementDigest(bytes)
    return withUnsafeBytes(of: digest) { TrfsDigest($0)! }
  }
}

// All buffers are caller-owned, pinned, disjoint and live for the call.
// The supplied callback is responsible for both extension and logging.
@_cdecl("profile_system_root")
public func profileSystemRoot(
  _ image: UnsafeRawPointer, _ length: Int, _ scratch: UnsafeMutableRawPointer,
  _ root: UnsafeRawPointer, _ rootLength: Int,
  _ measure: @convention(c) (UnsafeRawPointer, Int) -> Bool
) -> Bool {
  guard length >= 16384, length % 4096 == 0, rootLength >= 0,
    var v = TrfsVolume(media: ReadView(disk: .init(start: image, count: length)),
                       scratch: .init(start: scratch, count: 4096))
  else { return false }
  return v.mountSystem(bootSetRoot: .init(start: root, count: rootLength)) { digest in
    var wire = InlineArray<32, UInt8>(repeating: 0)
    guard withUnsafeMutableBytes(of: &wire, { digest.encode(into: $0) }) else { return false }
    return withUnsafeBytes(of: wire) { measure($0.baseAddress!, $0.count) }
  }
}
