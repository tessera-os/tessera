import Foundation
import TarwinArchHosted
import TarwinLoaderHosted

public typealias TarwinThreadID = UInt64

/// A single gate request authenticated by the installed trap handler.
public struct TrapAuthorization: Sendable {
  public let threadID: TarwinThreadID
  public let originalPC: UInt64
  public let resumePC: UInt64
  public let number: UInt64
  public let arguments: [UInt64]

  public init?(threadID: TarwinThreadID, originalPC: UInt64, resumePC: UInt64,
    number: UInt64, arguments: [UInt64]) {
    guard threadID != 0, originalPC != 0, resumePC != 0,
      (originalPC | resumePC) & 3 == 0, arguments.count == 8 else { return nil }
    self.threadID = threadID; self.originalPC = originalPC; self.resumePC = resumePC
    self.number = number; self.arguments = arguments
  }
}

/// H2 supplies real rewriting and trap authentication; nil never grants authority.
public struct TarwindLaunchHooks: Sendable {
  public typealias Rewrite = @Sendable (
    _ image: HostedVerifiedImage, _ code: Data, _ rva: UInt64,
    _ imageBase: UInt64, _ veneersAt: UInt64
  ) throws -> (text: Data, veneers: Data, siteMap: [UInt64: UInt64])
  public let rewrite: Rewrite
  public let authorizeTrap: @Sendable (TarwindProcessID, HostException) -> TrapAuthorization?
  public let enroll: @Sendable (TarwindProcessID, [UInt64: UInt64], [UInt64: TarwinThreadID]) -> Void

  public init(rewrite: @escaping Rewrite,
    authorizeTrap: @escaping @Sendable (TarwindProcessID, HostException) -> TrapAuthorization?,
    enroll: @escaping @Sendable (TarwindProcessID, [UInt64: UInt64], [UInt64: TarwinThreadID]) -> Void) {
    self.rewrite = rewrite; self.authorizeTrap = authorizeTrap; self.enroll = enroll
  }
}
