// Block addressing and the XTS data-unit number come from the volume
// implementation, not from the VM fault address. This is not a disk format.
public struct EncryptedUnit: Equatable {
  public let block: UInt64
  public let tweak: UInt64
  public let keyObject: UInt64

  public init(block: UInt64, tweak: UInt64, keyObject: UInt64) {
    self.block = block
    self.tweak = tweak
    self.keyObject = keyObject
  }
}

// Synchronous single-unit boundary. The pager owns both pins until return;
// driverRead/driverWrite can only receive the ciphertext staging buffer.
// The crypto provider is kernel CPU AES-256-XTS (no user callback).
public func encryptedPageIn(
  _ unit: EncryptedUnit, _ cachePage: UInt64, _ staging: UInt64,
  _ readCipher: (UInt64, UInt64) -> Bool, _ decrypt: (UInt64, UInt64, UInt64, UInt64) -> Bool,
  _ clear: (UInt64) -> Void
) -> Bool {
  if cachePage == staging { return false }
  if !readCipher(unit.block, staging) {
    clear(cachePage)
    clear(staging)
    return false
  }
  let ok = decrypt(unit.keyObject, unit.tweak, staging, cachePage)
  clear(staging)
  if !ok { clear(cachePage) }
  return ok
}

public func encryptedWriteback(
  _ unit: EncryptedUnit, _ cachePage: UInt64, _ staging: UInt64,
  _ encrypt: (UInt64, UInt64, UInt64, UInt64) -> Bool, _ writeCipher: (UInt64, UInt64) -> Bool,
  _ clear: (UInt64) -> Void
) -> Bool {
  if cachePage == staging { return false }
  let encrypted = encrypt(unit.keyObject, unit.tweak, cachePage, staging)
  let ok = encrypted && writeCipher(unit.block, staging)
  clear(staging)
  return ok
}
