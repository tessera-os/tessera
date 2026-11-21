import CryptoKit
import Darwin
import Synchronization
import TRFS
import TarwinBlockHosted

/// TRFS media over a hosted disk image: 4096-byte TRFS blocks map 1:1 to
/// image blocks, flush is F_FULLFSYNC.
public struct HostedTrfsMedia: TrfsMedia {
  public let device: HostedBlockDevice
  public init(device: HostedBlockDevice) { self.device = device }
  public var blocks: UInt64 { device.blocks }
  public func read(_ block: UInt64, into: UnsafeMutableRawBufferPointer) -> Bool {
    device.read(block, into: into)
  }
  public func write(_ block: UInt64, from: UnsafeRawBufferPointer) -> Bool {
    device.write(block, from: from)
  }
  public func flush() -> Bool { device.flush() }
  public func sha256(_ bytes: UnsafeRawBufferPointer) -> TrfsDigest {
    SHA256.hash(data: bytes).withUnsafeBytes { TrfsDigest($0)! }
  }
}

public enum HostedTrfsError: Error, Equatable {
  case disk(HostedDiskError), format, mount, measure
}

/// One live TRFS volume on a hosted disk image. All access goes through
/// `withVolume`, which serializes callers; the volume owns one private
/// 4096-byte scratch page for its whole life.
public final class HostedTrfsDisk: @unchecked Sendable {
  public let device: HostedBlockDevice
  private let scratch: UnsafeMutableRawBufferPointer
  private let lock = Mutex(())
  private var volume: TrfsVolume<HostedTrfsMedia>

  private init(device: HostedBlockDevice) {
    self.device = device
    scratch = .allocate(byteCount: 4096, alignment: 4096)
    scratch.initializeMemory(as: UInt8.self, repeating: 0)
    volume = TrfsVolume(media: HostedTrfsMedia(device: device), scratch: scratch)!
  }
  deinit { scratch.deallocate() }

  /// The writable data volume. A missing image is created sparse and
  /// formatted; an existing image is only mounted and never reformatted,
  /// so a damaged disk fails instead of losing data.
  public static func openData(path: String, blocks: UInt64) throws -> HostedTrfsDisk {
    do {
      let d = HostedTrfsDisk(device: try HostedBlockDevice.open(path: path))
      guard d.withVolume({ $0.mount() }) else { throw HostedTrfsError.mount }
      return d
    } catch HostedDiskError.notFound {
      let d: HostedTrfsDisk
      do { d = HostedTrfsDisk(device: try HostedBlockDevice.create(path: path, blocks: blocks)) }
      catch let e as HostedDiskError { throw HostedTrfsError.disk(e) }
      guard d.withVolume({ $0.formatBlank() }) else {
        unlink(path)
        throw HostedTrfsError.format
      }
      return d
    } catch let e as HostedDiskError {
      throw HostedTrfsError.disk(e)
    }
  }

  /// The signed system volume, read-only. `bootSetRoot` is the verifier's
  /// raw 32-byte root; mounting fails closed, with no fallback.
  public static func openSystem(
    path: String, bootSetRoot: UnsafeRawBufferPointer, measure: (TrfsDigest) -> Bool
  ) throws -> HostedTrfsDisk {
    let d: HostedTrfsDisk
    do { d = HostedTrfsDisk(device: try HostedBlockDevice.open(path: path, readOnly: true)) }
    catch let e as HostedDiskError { throw HostedTrfsError.disk(e) }
    guard d.withVolume({ $0.mountSystem(bootSetRoot: bootSetRoot, measure: measure) }) else {
      throw HostedTrfsError.measure
    }
    return d
  }

  public func withVolume<R>(_ body: (inout TrfsVolume<HostedTrfsMedia>) throws -> R) rethrows -> R {
    try lock.withLock { _ in try body(&volume) }
  }

  /// `<Disks>/<name>.trfs`, with the directory created on demand.
  public static func imagePath(name: String, home: String? = nil) throws -> String {
    try HostedBlockDevice.disksDirectory(home: home) + "/" + name + ".trfs"
  }
}
