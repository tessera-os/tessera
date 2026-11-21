import HostedDeviceWire
import TarwinArchHosted

public final class MacPowerDeviceProvider: HostDeviceProvider {
  public let kind = "power"
  private let endpoint: HostedDriverEndpoint
  public init(driver: MacPowerDriver) throws {
    endpoint = try HostedDriverEndpoint { driver.receive($0) }
  }
  public func open(slot: UInt32) throws -> HostPort { try endpoint.open(slot: slot) }
}
