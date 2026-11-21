// The guest submits an immutable delivery binary unchanged (TVISA §23).
// These are transport preconditions, not a replacement for the TVISA verifier.
func little(_ bytes: [UInt8], _ offset: Int, _ width: Int) -> UInt64 {
  var value: UInt64 = 0
  for i in 0..<width { value |= UInt64(bytes[offset + i]) << UInt64(8 * i) }
  return value
}

public func moduleEnvelope(_ image: [UInt8], _ year: UInt8, _ month: UInt8, _ week: UInt8) -> Bool {
  if image.count < 64 || year == 0 || year > 99 || month == 0 || month > 12 || week > 5
    || image[0] != 0x54 || image[1] != 0x56 || image[2] != 0x49 || image[3] != 0x53
    || image[4] != year || image[5] != month || image[6] != week || image[7] != 0 || image[12] > 3
    || image[13] != 0 || image[14] != 0 || image[15] != 0
  {
    return false
  }
  let size = UInt64(image.count)
  let flags = little(image, 8, 4)
  let count = little(image, 16, 4)
  if (flags & 65) != 65 || flags > 255 || count == 0 || count > 21 || count > (size - 64) / 32
    || little(image, 56, 8) != size || little(image, 20, 4) == 0
  {
    return false
  }
  var cursor: UInt64 = 64 + count * 32
  var previous: UInt64 = 0
  var hasGpu = false
  var hasCode = false
  for i in 0..<Int(count) {
    let at = 64 + i * 32
    let kind = little(image, at, 4)
    let length = little(image, at + 16, 8)
    if kind <= previous || kind > 21 || little(image, at + 4, 4) != 0
      || little(image, at + 8, 8) != cursor || length > size - cursor
      || little(image, at + 24, 8) != length
    {
      return false
    }
    if kind == 9 && length > 0 { hasCode = true }
    if kind == 11 && length > 0 { hasGpu = true }
    previous = kind
    cursor += length
  }
  return cursor == size && hasGpu && hasCode
}

public struct DeviceCaps: Equatable {
  public let family: UInt16
  public let host: UInt64
  public let translated: UInt64
  public let guestLowered: UInt64
  public func supports(_ required: UInt64) -> Bool {
    let available = (host & translated) | guestLowered
    return family == 1 && (available & required) == required
  }

  public init(family: UInt16, host: UInt64, translated: UInt64, guestLowered: UInt64) {
    self.family = family
    self.host = host
    self.translated = translated
    self.guestLowered = guestLowered
  }
}

public struct ModuleTarget: Equatable {
  public let year: UInt8
  public let month: UInt8
  public let week: UInt8
  public let required: UInt64

  public init(year: UInt8, month: UInt8, week: UInt8, required: UInt64) {
    self.year = year
    self.month = month
    self.week = week
    self.required = required
  }
}

// The transport binds a client-owned context before calling; the delivery
// provider validates code provenance, canonical verification and BLAKE3 over
// the same frozen bytes. Neither stage performs guest-to-host translation.
public func submitModule(
  _ image: [UInt8], _ target: ModuleTarget, _ caps: DeviceCaps, _ verifyDelivery: ([UInt8]) -> Bool,
  _ submitUnchanged: ([UInt8]) -> Bool
) -> Bool {
  if !caps.supports(target.required)
    || !moduleEnvelope(image, target.year, target.month, target.week)
  {
    return false
  }
  return verifyDelivery(image) && submitUnchanged(image)
}
