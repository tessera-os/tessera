import TRFS
import TRFSHosted
import TarwinBlockHosted

public enum ProofError: Error, Equatable {
  case invalidChallenge, badVolume, missingFile, wrongFile, wrongReply, deniedConnection
  case timeout, disconnected, system(Int32), appExit(Int32), networkDecisions
}

public enum DiskProof {
  public static let filename = "hosted-io-proof"

  /// Call only after tarwind releases its exclusive lock. This never creates or repairs an image.
  public static func verify(path: String, challenge: [UInt8]) throws {
    guard challenge.count == 32 else { throw ProofError.invalidChallenge }
    let block = try HostedBlockDevice.open(path: path, readOnly: true)
    let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
    let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
    defer { scratch.deallocate(); bytes.deallocate() }
    guard var volume = TrfsVolume(media: HostedTrfsMedia(device: block), scratch: scratch),
      volume.mount(), let root = volume.snapshot else { throw ProofError.badVolume }
    guard case .file(let id) = volume.lookup(1, name: Array(filename.utf8), in: root)
    else { throw ProofError.missingFile }
    guard volume.length(id, in: root) == 32,
      volume.readPage(id, index: 0, in: root, into: bytes) == 32,
      bytes.prefix(32).elementsEqual(challenge) else { throw ProofError.wrongFile }
  }
}
