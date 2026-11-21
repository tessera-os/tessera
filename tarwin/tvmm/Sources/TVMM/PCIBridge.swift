// One ECAM bus with up to 32 single-function endpoints. BAR addresses are
// decoded only within the machine's reserved guest MMIO hole, never host memory.
public final class VirtioPCIBridge {
  public let aperture: GuestAperture
  private var slots: [Int: VirtioPCIFunction] = [:]

  public init?(aperture: GuestAperture) {
    let limit: UInt64 = 1 << 32
    guard aperture.base > 0, aperture.base < limit, aperture.length >= 4096,
      aperture.length <= limit - aperture.base
    else { return nil }
    self.aperture = aperture
  }
  public func install(_ function: VirtioPCIFunction, slot: Int) -> Bool {
    guard (0..<32).contains(slot), slots[slot] == nil,
      !slots.values.contains(where: { $0 === function })
    else { return false }
    slots[slot] = function
    return true
  }
  private func ecam(_ at: UInt64, _ width: Int) -> Bool {
    [1, 2, 4].contains(width) && at < 1 << 20 && at % UInt64(width) == 0
  }
  public func configRead(offset: UInt64, width: Int) -> UInt64? {
    guard ecam(offset, width) else { return nil }
    guard offset & 0x7000 == 0, let device = slots[Int(offset >> 15)]
    else { return UInt64.max >> (64 - width * 8) }
    return device.configRead(Int(offset & 4095), width)
  }
  public func configWrite(offset: UInt64, width: Int, value: UInt64) -> Bool {
    guard ecam(offset, width), value >> (width * 8) == 0 else { return false }
    guard offset & 0x7000 == 0, let device = slots[Int(offset >> 15)] else { return true }
    return device.configWrite(Int(offset & 4095), width, value)
  }

  private func target(_ address: UInt64, _ width: Int) -> (VirtioPCIFunction, Int)? {
    guard [1, 2, 4, 8].contains(width), address % UInt64(width) == 0,
      containsSpan(aperture, address, UInt64(width))
    else { return nil }
    var match: (VirtioPCIFunction, Int)?
    for device in slots.values where device.decodes {
      let base = UInt64(device.base)
      let size = UInt64(device.barSize)
      guard containsSpan(aperture, base, size), address >= base, address - base < size else {
        continue
      }
      guard match == nil else { return nil }  // two live BARs decode this cycle
      match = (device, Int(address - base))
    }
    return match
  }
  public func read(address: UInt64, width: Int) -> UInt64? {
    guard let (device, offset) = target(address, width) else { return nil }
    return device.read(offset, width)
  }
  public func write(address: UInt64, width: Int, value: UInt64) -> Bool {
    guard let (device, offset) = target(address, width), width == 8 || value >> (width * 8) == 0
    else { return false }
    return device.write(offset, width, value)
  }
}
