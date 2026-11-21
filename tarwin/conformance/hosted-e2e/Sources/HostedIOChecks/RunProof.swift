import Foundation
import TarwindKernel
import TarwinNetHosted

struct SocketObservation {
  let appID: String?
  let proto: NetProtocol
  let endpoint: NetAddress
  let verdict: NetVerdict
  let reason: String
  let socketCreated: Bool
}

/// Per-run witnesses for a verified guest. The launcher sees the new data path but not the nonce.
public final class RunProof {
  public let dataImage: String
  private let directory: URL
  private let loopback: LoopbackWitness
  private let challenge: [UInt8]
  private var exchanged = false
  private var observedSockets = false

  public static let appID = "org.tessera.conformance.hosted-io-client"
  public static func launchGrants() -> [TarwindGrant] {
    [.namespace(volume: .data, path: "/", rights: [.read, .write, .create]), .network(networkPolicy())]
  }

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

  /// Read only the launched process's kernel journal. A guest completion is a separate witness.
  public func captureSocketDecisions(kernel: Tarwind, process: TarwindProcessID) throws {
    observedSockets = Self.matchesSockets(kernel.networkDecisions(process: process).map {
      SocketObservation(appID: $0.appID, proto: $0.protocol, endpoint: $0.endpoint,
        verdict: $0.verdict, reason: $0.reason, socketCreated: $0.socketCreated)
    })
    guard observedSockets else { throw ProofError.networkDecisions }
  }

  static func matchesSockets(_ records: [SocketObservation]) -> Bool {
    guard records.count == 2,
      records.allSatisfy({ $0.appID == appID && $0.proto == .tcp }) else { return false }
    let allowed = records[0], denied = records[1]
    return allowed.endpoint == .loopback(.v4, port: 43871) && allowed.verdict == .allow
      && allowed.socketCreated && denied.endpoint == .loopback(.v4, port: 43872)
      && denied.verdict == .deny("rule") && denied.reason == "rule" && !denied.socketCreated
  }

  /// Pass only the status of a normally exited, verified guest, never a killed task.
  public func verifyAfterShutdown(normalExit: Int32) throws {
    guard normalExit == 0 else { throw ProofError.appExit(normalExit) }
    guard observedSockets else { throw ProofError.networkDecisions }
    guard exchanged else { throw ProofError.wrongReply }
    try loopback.checkDeniedPort()
    try DiskProof.verify(path: dataImage, challenge: challenge)
  }

  deinit { try? FileManager.default.removeItem(at: directory) }
}
