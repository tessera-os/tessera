import Darwin
import Foundation
import TRFS
import TRFSHosted
import TarwinHostFolder
import TarwinIPC
import TarwinReadOnlyFS
import TarwinBlockHosted

/// Supplies the verified boot-set root and commits the system-volume measurement.
public protocol TarwindSystemVolumeVerifier: TarwindHost {
  func systemVolumeRoot(path: String) throws -> [UInt8]
  func measureSystemVolume(root: [UInt8]) -> Bool
}

public enum TarwindResourceError: Error {
  case stopped, duplicateShare, invalidDirectory, unknownShare, invalidName, invalidRing
  case systemVerificationRequired, invalidSystemRoot, missingVolume
}

public struct TarwindInvalidDisk: Error, CustomStringConvertible {
  public let path: String
  public var description: String { "disk at \(path) is not a TRFS volume" }
}

func openDataVolume(path: String) throws -> HostedTrfsDisk {
  do { return try HostedTrfsDisk.openData(path: path, blocks: 1 << 16) }
  catch HostedTrfsError.mount { throw TarwindInvalidDisk(path: path) }
  catch HostedTrfsError.disk(.badGeometry) { throw TarwindInvalidDisk(path: path) }
}

func openSystemVolume(config: TarwindConfig, host: any TarwindHost) throws -> HostedTrfsDisk? {
  var info = stat()
  if lstat(config.systemImagePath, &info) != 0 {
    if errno == ENOENT { return nil }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
  guard let verifier = host as? any TarwindSystemVolumeVerifier else {
    throw TarwindResourceError.systemVerificationRequired
  }
  let root = try verifier.systemVolumeRoot(path: config.systemImagePath)
  guard root.count == 32 else { throw TarwindResourceError.invalidSystemRoot }
  return try root.withUnsafeBytes { bytes in
    try HostedTrfsDisk.openSystem(path: config.systemImagePath, bootSetRoot: bytes) { digest in
      var measured = [UInt8](repeating: 0, count: 32)
      guard measured.withUnsafeMutableBytes({ digest.encode(into: $0) }) else { return false }
      return verifier.measureSystemVolume(root: measured)
    }
  }
}

final class SharedFolder {
  let volume: HostFolderVolume
  var servers: [TarwindFolderServer] = []
  init(_ volume: HostFolderVolume) { self.volume = volume }
  func stop() { for server in servers { server.stop() }; servers.removeAll() }
}

/// Ring storage and shares must outlive the server; unsharing stops every server.
public final class TarwindFolderServer: @unchecked Sendable {
  private let lock = NSLock()
  private var server: HostFolderServer?
  init(volume: HostFolderVolume, epoch: UInt64, requests: consuming RingEndpoint,
    replies: consuming RingEndpoint) throws {
    server = HostFolderServer(volume: volume, epoch: epoch, requests: consume requests, replies: consume replies)
    guard server != nil else { throw TarwindResourceError.invalidRing }
  }
  public func step<S: ReadOnlyShares & ~Copyable>(shares: inout S,
    signalSpace: () -> Void, signalReply: () -> Void) -> ReadOnlyStep {
    lock.lock(); defer { lock.unlock() }
    guard server != nil else { return .stopped }
    return server!.step(shares: &shares, signalSpace: signalSpace, signalReply: signalReply)
  }
  func stop() { lock.withLock { server = nil } }
}

extension Tarwind {
  /// Serializes direct TRFS access with shutdown; the callback must not reenter Tarwind.
  public func withDataVolume<R>(_ body: (inout TrfsVolume<HostedTrfsMedia>) throws -> R) throws -> R {
    try state.lock.withLock {
      guard !state.stopped, let disk = state.dataVolume else { throw TarwindResourceError.missingVolume }
      return try disk.withVolume(body)
    }
  }
  /// The mounted system snapshot is integrity checked and read-only.
  public func withSystemVolume<R>(_ body: (inout TrfsVolume<HostedTrfsMedia>) throws -> R) throws -> R {
    try state.lock.withLock {
      guard !state.stopped, let disk = state.systemVolume else { throw TarwindResourceError.missingVolume }
      return try disk.withVolume(body)
    }
  }
  /// The caller retains its descriptor; only the duplicate transfers ownership.
  public func shareFolder(name: String, directoryFD: Int32, readOnly: Bool) throws {
    try state.lock.withLock {
      guard !state.stopped else { throw TarwindResourceError.stopped }
      guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
        throw TarwindResourceError.invalidName
      }
      guard state.sharedFolders[name] == nil else { throw TarwindResourceError.duplicateShare }
      let duplicate = dup(directoryFD)
      guard duplicate >= 0 else { throw TarwindResourceError.invalidDirectory }
      guard let volume = HostFolderVolume(directoryFD: duplicate, readOnly: readOnly) else {
        throw TarwindResourceError.invalidDirectory
      }
      state.sharedFolders[name] = SharedFolder(volume)
    }
  }
  public func unshareFolder(name: String) {
    state.lock.withLock { state.sharedFolders.removeValue(forKey: name)?.stop() }
  }
  public func makeFolderServer(name: String, epoch: UInt64, requests: consuming RingEndpoint,
    replies: consuming RingEndpoint) throws -> TarwindFolderServer {
    state.lock.lock(); defer { state.lock.unlock() }
    guard !state.stopped, let folder = state.sharedFolders[name] else { throw TarwindResourceError.unknownShare }
    let server = try TarwindFolderServer(volume: folder.volume, epoch: epoch,
      requests: consume requests, replies: consume replies)
    folder.servers.append(server)
    return server
  }
}
