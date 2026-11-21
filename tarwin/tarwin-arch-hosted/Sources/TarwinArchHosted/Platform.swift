import Dispatch
import Foundation

/// Dispatch-delivered host pressure levels, not Tarwin allocation authority.
public enum HostPressureLevel: Sendable { case normal, warning, critical }

/// Owns a resumed memory-pressure source for the duration of this object.
public final class HostMemoryPressure: @unchecked Sendable {
  private let source: any DispatchSourceMemoryPressure
  /// Starts pressure notifications on a private serial queue.
  public init(callback: @escaping @Sendable (HostPressureLevel) -> Void) {
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
      queue: DispatchQueue(label: "tarwin.host.pressure"))
    self.source = source
    source.setEventHandler { [weak self] in
      guard let flags = self?.source.data else { return }
      callback(flags.contains(.critical) ? .critical : flags.contains(.warning) ? .warning : .normal)
    }
    source.resume()
  }
  deinit { source.cancel() }
}

/// A driver-supplied resource broker returning an owned send right per open.
public protocol HostDeviceProvider: Sendable {
  var kind: String { get }
  func open(slot: UInt32) throws -> HostPort
}

/// A synchronized registry; replacement is explicit and providers run outside its lock.
public final class HostDeviceRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var providers: [String: any HostDeviceProvider] = [:]
  /// Creates an empty device namespace without opening host resources.
  public init() {}
  /// Installs or replaces a provider for its exact kind string.
  public func register(_ provider: any HostDeviceProvider) {
    let kind = provider.kind
    lock.lock()
    defer { lock.unlock() }
    providers[kind] = provider
  }
  /// Returns the current provider, or nil for an unregistered kind.
  public func lookup(kind: String) -> (any HostDeviceProvider)? {
    lock.lock()
    defer { lock.unlock() }
    return providers[kind]
  }
}

/// The hosted layer-zero services supplied to the Tarwin composition.
public struct HostPlatform: Sendable {
  public let clock: HostClock
  public let eventQueue: HostEventQueue
  public let cpu: HostCPU
  public let memoryPressure: HostMemoryPressure
  public let devices: HostDeviceRegistry
  /// Creates an independent service bundle and starts pressure observation.
  public static func current(onMemoryPressure: @escaping @Sendable (HostPressureLevel) -> Void = { _ in }) throws -> HostPlatform {
    HostPlatform(clock: HostClock(), eventQueue: try HostEventQueue(), cpu: HostCPU(),
      memoryPressure: HostMemoryPressure(callback: onMemoryPressure), devices: HostDeviceRegistry())
  }
}
