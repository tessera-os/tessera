import Foundation
import TarwinLoader
import TarwinW0Verify

public enum TarwindSigningError: Error {
  case malformedImage, identity, signature, profile, train, target, entitlements, invalidArguments
  case invalidELF(String)
}

/// Issued only after authenticating a hosted debug app, never a system image.
public struct TarwindAppIdentity: Sendable {
  public let appID: String
  public let entitlements: Set<String>
}

struct DebugKeys: Decodable {
  let identity: String
  let ed25519: Data
  let mldsa65: Data
  static func load() throws -> Self {
    guard let url = Bundle.module.url(forResource: "HostedDebugKeys", withExtension: "json") else {
      throw TarwindSigningError.identity
    }
    let keys = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    guard keys.ed25519.count == 32, keys.mldsa65.count == 1952 else { throw TarwindSigningError.identity }
    return keys
  }
}

func hashWorkspace() -> [BlakeCv] {
  .init(repeating: .init(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
}

func canonicalJSON(_ value: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}

/// Independently pinned hosted debug-app trust. QEMU enrollment is never consulted.
public enum TarwindAppTrust {
  public static func admit(_ image: Data) throws -> TarwindAppIdentity {
    guard image.count <= 64 * 1024 * 1024 else { throw TarwindSigningError.malformedImage }
    var hashes = hashWorkspace()
    return try image.withUnsafeBytes { file in
      let layout = hashes.withUnsafeMutableBufferPointer {
        inspectSigningCandidate(file, machine: ElfMachine.aarch64, addressLimit: 64 << 30,
          finalized: true, requiresEntry: true, scratch: $0)
      }
      guard let layout else { throw TarwindSigningError.malformedImage }
      return try authorize(file, layout: layout)
    }
  }

  public static func authorize(_ file: UnsafeRawBufferPointer, layout _: InspectedImage) throws -> TarwindAppIdentity {
    var hashes = hashWorkspace()
    guard let layout = hashes.withUnsafeMutableBufferPointer({
      inspectSigningCandidate(file, machine: ElfMachine.aarch64, addressLimit: 64 << 30,
        finalized: true, requiresEntry: true, scratch: $0)
    }) else { throw TarwindSigningError.malformedImage }
    func bytes(_ range: Range<Int>?) throws -> Data {
      guard let range, range.lowerBound >= 0, range.upperBound <= file.count else {
        throw TarwindSigningError.malformedImage
      }
      return Data(file[range])
    }
    guard try bytes(layout.notes.profile) == Data([1, 0]) else { throw TarwindSigningError.profile }
    let train = try bytes(layout.notes.train)
    guard train.count == 9, train.prefix(6) == Data([26, 11, 1, 26, 11, 2]),
      !train.suffix(3).lexicographicallyPrecedes([26, 11, 1]) else { throw TarwindSigningError.train }
    let target = try bytes(layout.notes.target)
    guard target.withUnsafeBytes({ matchesW0Baseline($0, machine: ElfMachine.aarch64) }) else {
      throw TarwindSigningError.target
    }
    #if !arch(arm64)
    throw TarwindSigningError.target
    #else
    let keys = try DebugKeys.load()
    let envelope = try bytes(layout.notes.signature)
    guard let signature = envelope.withUnsafeBytes({ HybridEnvelope($0, descriptor: 0..<$0.count) }) else {
      throw TarwindSigningError.signature
    }
    let chain = Data(envelope[signature.chain])
    guard let claim = try JSONSerialization.jsonObject(with: chain) as? [String: String],
      Set(claim.keys) == ["identity", "scope", "appID"], claim["scope"] == "debug-app",
      claim["identity"] == keys.identity, let appID = claim["appID"], validIdentifier(appID),
      try canonicalJSON(claim) == chain else { throw TarwindSigningError.identity }
    let grants = try bytes(layout.notes.entitlements)
    guard let list = try JSONSerialization.jsonObject(with: grants) as? [String],
      list == Array(Set(list)).sorted(), list.allSatisfy(validIdentifier),
      try canonicalJSON(list) == grants else { throw TarwindSigningError.entitlements }
    var message = Data(count: 65536)
    guard let count = message.withUnsafeMutableBytes({ nativeSigningMessage(file, notes: layout.notes, into: $0) })
    else { throw TarwindSigningError.malformedImage }
    message = message.prefix(count)
    var work = [Int32](repeating: 0, count: 2048)
    let verified = message.withUnsafeBytes { msg in envelope.withUnsafeBytes { env in
      keys.ed25519.withUnsafeBytes { ed in keys.mldsa65.withUnsafeBytes { ml in
        work.withUnsafeMutableBufferPointer {
          verifyHybridSignature(message: msg, envelope: env, ed25519Key: ed, mldsa65Key: ml, work: $0)
        }
      } }
    } }
    guard verified else { throw TarwindSigningError.signature }
    return TarwindAppIdentity(appID: appID, entitlements: Set(list))
    #endif
  }
}

func validIdentifier(_ value: String) -> Bool {
  !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46
  }
}
