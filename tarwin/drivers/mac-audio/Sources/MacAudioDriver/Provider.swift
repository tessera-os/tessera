import HostedDeviceWire
import TarwinArchHosted

public final class MacAudioDeviceProvider: HostDeviceProvider {
  public let kind = "audio"
  private let endpoint: HostedDriverEndpoint
  public init(driver: MacAudioDriver) throws {
    endpoint = try HostedDriverEndpoint { driver.receive($0) }
  }
  public func open(slot: UInt32) throws -> HostPort { try endpoint.open(slot: slot) }
}
