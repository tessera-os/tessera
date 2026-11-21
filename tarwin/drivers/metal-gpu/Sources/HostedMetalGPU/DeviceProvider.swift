import Darwin
import TarwinArchHosted

public struct HostedGraphicsDeviceProvider: HostDeviceProvider {
  public enum Kind: String, Sendable {
    case metalGPU = "gpu"
    case macDisplay = "display"

    public func open(in registry: HostDeviceRegistry, slot: UInt32) throws -> HostPort {
      guard let provider = registry.lookup(kind: rawValue) else {
        throw HostError("look up graphics device", code: KERN_INVALID_NAME)
      }
      let port = try provider.open(slot: slot)
      guard port.kind == .send else { throw HostError("open graphics slot", code: KERN_INVALID_RIGHT) }
      return port
    }
  }

  public let kind: String
  private let openSlot: @Sendable (UInt32) throws -> HostPort

  public init(kind: Kind, openSlot: @escaping @Sendable (UInt32) throws -> HostPort) {
    self.kind = kind.rawValue
    self.openSlot = openSlot
  }

  public func open(slot: UInt32) throws -> HostPort {
    let port = try openSlot(slot)
    guard port.kind == .send else { throw HostError("open graphics slot", code: KERN_INVALID_RIGHT) }
    return port
  }
}
