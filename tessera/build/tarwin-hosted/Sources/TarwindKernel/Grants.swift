import Foundation
import TarwinArchHosted
import TarwinNetHosted
import TarwinObject

/// Namespace volumes are explicit authorities, not host filesystem paths.
public enum TarwindVolume: Hashable, Sendable {
  case data, system, shared(String)
}

/// One-to-one LibTessera Rights bits; write and create are independent.
public struct TarwindRights: OptionSet, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static let duplicate = Self(rawValue: 1 << 0)
  public static let transfer = Self(rawValue: 1 << 1)
  public static let read = Self(rawValue: 1 << 2)
  public static let write = Self(rawValue: 1 << 3)
  public static let map = Self(rawValue: 1 << 4)
  public static let execute = Self(rawValue: 1 << 5)
  public static let signal = Self(rawValue: 1 << 6)
  public static let wait = Self(rawValue: 1 << 7)
  public static let inspect = Self(rawValue: 1 << 8)
  public static let manage = Self(rawValue: 1 << 9)
  public static let setProperty = Self(rawValue: 1 << 10)
  public static let enumerate = Self(rawValue: 1 << 11)
  public static let create = Self(rawValue: 1 << 12)
  public static let delete = Self(rawValue: 1 << 13)
  public static let traverse = Self(rawValue: 1 << 14)
  public static let grant = Self(rawValue: 1 << 15)
  static let mutation: Self = [.write, .create, .delete, .setProperty, .manage]
}

/// Initial authorities installed by the trusted launcher.
public enum TarwindGrant: Sendable {
  case namespace(volume: TarwindVolume, path: String, rights: TarwindRights)
  case network(NetPolicy)
  case device(kind: String)
}

/// Terminal process outcome, retained independently of the live process record.
public enum TarwindExit: Sendable, Equatable {
  case exited(Int32)
  case killed(HostException.Kind)
}

public enum TarwindGrantError: Error {
  case invalidRights, invalidPath, readOnly, duplicateNetwork, accessDenied
}

struct NamespaceGrant {
  let volume: TarwindVolume
  let path: String
}

extension Tarwind {
  @discardableResult func grant(process: TarwindProcessID, _ grant: TarwindGrant) throws -> UInt64? {
    try state.lock.withLock {
      guard !state.stopped, let record = state.processes[process] else { throw TarwindError.invalidProcess }
      switch grant {
      case .network(let policy):
        guard !record.hasNetworkGrant else { throw TarwindGrantError.duplicateNetwork }
        policy.setEntitlements(record.networkEntitlements, for: record.networkAppID)
        record.network = HostedNetwork(policy: policy)
        record.hasNetworkGrant = true
        return nil
      case .device(let kind):
        guard state.devices.lookup(kind: kind) != nil else { throw TarwindError.unavailable }
        record.deviceGrants.insert(kind)
        return nil
      case .namespace(let volume, let path, let rights):
        guard rights.rawValue & ~UInt64(0xffff) == 0 else { throw TarwindGrantError.invalidRights }
        guard path.hasPrefix("/"), !path.contains("\0"),
          !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw TarwindGrantError.invalidPath }
        switch volume {
        case .system:
          guard rights.intersection(.mutation).isEmpty else { throw TarwindGrantError.readOnly }
          guard state.systemVolume != nil else { throw TarwindResourceError.missingVolume }
        case .data:
          guard state.dataVolume != nil else { throw TarwindResourceError.missingVolume }
        case .shared(let name):
          guard let folder = state.sharedFolders[name] else { throw TarwindResourceError.unknownShare }
          guard !folder.volume.readOnly || rights.intersection(.mutation).isEmpty else {
            throw TarwindGrantError.readOnly
          }
        }
        guard state.headers.count < 1024,
          let value = ObjectHeader(source: state.source, ownerJob: 1, kind: TarwinKind.node,
            maximumRights: rights.rawValue) else { throw TarwindError.unavailable }
        let header = state.arena.store(consume value)
        state.headers.append(header)
        defer { if header.pointee.release() == .destroy { state.retired.append(UnsafePointer(header)) } }
        guard case .installed(let handle) = record.table.pointee.install(UnsafePointer(header), rights: rights.rawValue)
        else { throw TarwindError.unavailable }
        record.namespaces[header.pointee.koid] = NamespaceGrant(volume: volume, path: path)
        return handle
      }
    }
  }
}
