import HostedDeviceWire
import TarwinArchHosted

public final class MacHIDDeviceProvider: HostDeviceProvider {
  public let kind = "hid"
  private let endpoint: HostedDriverEndpoint
  public init(driver: MacHIDDriver) throws {
    endpoint = try HostedDriverEndpoint { driver.receive($0) }
  }
  public func open(slot: UInt32) throws -> HostPort { try endpoint.open(slot: slot) }
}
