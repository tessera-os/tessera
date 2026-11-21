import AppKit
import Foundation
import IOKit.ps
import HostedDeviceWire
import MacPowerWire

/// Observation and publication are serialized on the main run loop.
public final class MacPowerHost: @unchecked Sendable {
  private let channel: any HostedDeviceChannel
  private let center: NotificationCenter
  private let workspaceCenter: NotificationCenter
  private let sampleSources: () -> [PowerSourceSample]
  private let sampleEnvironment: () -> (UInt32, Bool)
  private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
  private var source: CFRunLoopSource?
  private var sequence: UInt64 = 0
  @MainActor public init(channel: any HostedDeviceChannel, center: NotificationCenter = .default,
    workspaceCenter: NotificationCenter? = nil, sources: (() -> [PowerSourceSample])? = nil,
    environment: (() -> (UInt32, Bool))? = nil, observe: Bool = true) {
    self.channel = channel; self.center = center
    self.workspaceCenter = workspaceCenter ?? NSWorkspace.shared.notificationCenter
    sampleSources = sources ?? Self.readSources
    sampleEnvironment = environment ?? {
      (Self.thermalRawValue(ProcessInfo.processInfo.thermalState), ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    if observe { start() }
  }
  deinit { cleanup() }
  private func cleanup() {
    for (center, token) in tokens { center.removeObserver(token) }; tokens.removeAll()
    if let source { CFRunLoopSourceInvalidate(source); self.source = nil }
  }
  @MainActor public func start() {
    guard tokens.isEmpty else { return }
    for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
      tokens.append((center,token))
    }
    for (name, event) in [(NSWorkspace.willSleepNotification,PowerSystemEvent.sleep), (NSWorkspace.didWakeNotification,.wake)] {
      let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.sendSystemEvent(event)
          if event == .wake { self?.refresh() }
        }
      }
      tokens.append((workspaceCenter,token))
    }
    if let source = IOPSNotificationCreateRunLoopSource({ context in
      guard let context else { return }
      let owner = Unmanaged<MacPowerHost>.fromOpaque(context).takeUnretainedValue()
      MainActor.assumeIsolated { owner.refresh() }
    }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
      self.source = source
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
    refresh()
  }
  @MainActor public func stop() { cleanup() }
  public static func thermalRawValue(_ value: ProcessInfo.ThermalState) -> UInt32 {
    switch value { case .nominal: 0; case .fair: 1; case .serious: 2; case .critical: 3; @unknown default: 3 }
  }
  public static func normalizedSources(_ sources: [PowerSourceSample]) -> [PowerSourceSample] {
    let present = sources.filter { $0.isPresent }
    return present.isEmpty ? [.mains] : Array(present.prefix(32))
  }
  public static func nanoseconds(minutes: Int) -> UInt64 {
    guard minutes > 0, UInt64(minutes) <= UInt64.max / 60_000_000_000 else { return 0 }
    return UInt64(minutes) * 60_000_000_000
  }
  public static func readSources() -> [PowerSourceSample] {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [.mains] }
    var samples: [PowerSourceSample] = []
    for (index, item) in list.enumerated() {
      guard let description = IOPSGetPowerSourceDescription(info,item)?.takeUnretainedValue() as? [String:Any] else { continue }
      let type = description[kIOPSTypeKey] as? String
      let kind: PowerSourceKind = type == kIOPSUPSType ? .ups : .battery
      let present = description[kIOPSIsPresentKey] as? Bool ?? true
      let online = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
      let charging = description[kIOPSIsChargingKey] as? Bool ?? false
      let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? -1
      let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 0
      let percent: UInt32 = current.isFinite && maximum.isFinite && current >= 0 && maximum > 0
        ? UInt32(max(0,min(100,(current / maximum * 100).rounded()))) : .max
      if let sample = PowerSourceSample(id: UInt32(index), kind: kind, percent: percent, isPresent: present,
        online: online, charging: charging, full: online && !charging && percent == 100,
        timeToEmpty: nanoseconds(minutes: (description[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue ?? 0),
        timeToFull: nanoseconds(minutes: (description[kIOPSTimeToFullChargeKey] as? NSNumber)?.intValue ?? 0)) {
        samples.append(sample)
      }
    }
    return normalizedSources(samples)
  }
  @MainActor public func refresh() {
    let samples = Self.normalizedSources(sampleSources())
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1028) { storage in
      let p = UnsafeMutableRawBufferPointer(rebasing: UnsafeMutableRawBufferPointer(storage)[..<(4 + 32*samples.count)])
      Wire.write(UInt64(samples.count), to: p, at: 0, width: 4)
      for (index,sample) in samples.enumerated() {
        sample.encode(into: UnsafeMutableRawBufferPointer(rebasing: p[(4+32*index)..<(36+32*index)]))
      }
      sequence &+= 1
      PowerWire.send(channel, kind: PowerKind.sources, sequence: sequence, payload: UnsafeRawBufferPointer(p))
    }
    let (thermal, lowPower) = sampleEnvironment()
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 8) { storage in
      let p = UnsafeMutableRawBufferPointer(storage)
      Wire.write(UInt64(thermal), to: p, at: 0, width: 4)
      Wire.write(lowPower ? 1 : 0, to: p, at: 4, width: 4)
      sequence &+= 1
      PowerWire.send(channel, kind: PowerKind.environment, sequence: sequence, payload: UnsafeRawBufferPointer(p))
    }
  }
  @MainActor public func sendSystemEvent(_ event: PowerSystemEvent) {
    sequence &+= 1
    PowerWire.send(channel, kind: event == .sleep ? PowerKind.sleep : PowerKind.wake,
      sequence: sequence, payload: .init(start: nil, count: 0))
  }
}
