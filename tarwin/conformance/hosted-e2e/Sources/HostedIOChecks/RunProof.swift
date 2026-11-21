import Foundation
import TarwinNetHosted

/// Per-run witnesses for a verified guest. The launcher sees the new data path but not the nonce.
public final class RunProof {
  public let dataImage: String
  private let directory: URL
  private let loopback: LoopbackWitness
  private let challenge: [UInt8]
  private var exchanged = false

  public static let appID = "org.tessera.conformance.hosted-io-client"
  public static func networkPolicy() -> NetPolicy {
    let peer = NetPrefix("127.0.0.1/32")!
    return NetPolicy(rules: [
      NetRule(.allow, app: appID, proto: .tcp, direction: .outbound, prefix: peer, ports: 43871...43871),
      NetRule(.deny, app: appID, proto: .tcp, direction: .outbound, prefix: peer, ports: 43872...43872),
      NetRule(.deny),
    ])
  }

  public init() throws {
    let loopback = try LoopbackWitness()
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    var rng = SystemRandomNumberGenerator()
    let nonce = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    directory = dir; self.loopback = loopback; challenge = nonce
    dataImage = dir.appending(path: "data.trfs").path
  }

  /// Call after the signed app has been resumed, before waiting for its exit.
  public func exchangeWhileRunning() throws {
    try loopback.exchange(challenge: challenge)
    exchanged = true
  }

  /// Pass only the status of a normally exited, verified guest, never a killed task.
  public func verifyAfterShutdown(normalExit: Int32) throws {
    guard normalExit == 0 else { throw ProofError.appExit(normalExit) }
    guard exchanged else { throw ProofError.wrongReply }
    try loopback.checkDeniedPort()
    try DiskProof.verify(path: dataImage, challenge: challenge)
  }

  deinit { try? FileManager.default.removeItem(at: directory) }
}
