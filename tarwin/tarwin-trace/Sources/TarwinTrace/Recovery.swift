// Boot-time logger. Keep RAM committed across failed archival attempts; the
// archive key must be idempotent (a reboot may occur between archive and clear).
public func collectPanic(
  _ capacity: UInt64, _ get: (UInt64) -> UInt8,
  _ archive: (UInt64) -> Bool, _ put: (UInt64, UInt8) -> Void,
  _ persist: () -> Void
) -> Bool {
  let size = panicSize(capacity, get)
  if size == 0 || !archive(size) { return false }
  put(0, 0)
  persist()
  return true
}
