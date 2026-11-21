import Darwin

public enum HostedDiskError: Error, Equatable {
  case exists, notFound, locked, badGeometry, io(Int32)
}

/// A sparse disk image on the Mac used as one Tarwin block device (HS-011).
/// Blocks are 4096 bytes. One process holds the image at a time (flock);
/// flush is F_FULLFSYNC so acknowledged data survives power loss.
public final class HostedBlockDevice: @unchecked Sendable {
  public static let blockBytes = 4096
  public let path: String, blocks: UInt64, readOnly: Bool
  private let fd: Int32

  private init(fd: Int32, path: String, blocks: UInt64, readOnly: Bool) {
    self.fd = fd
    self.path = path
    self.blocks = blocks
    self.readOnly = readOnly
  }
  deinit { close(fd) }

  /// `~/Library/Application Support/Tessera/Disks`, created on demand.
  public static func disksDirectory(home: String? = nil) throws -> String {
    let base = home ?? getenv("HOME").map { String(cString: $0) } ?? "/tmp"
    var dir = base
    for part in ["Library", "Application Support", "Tessera", "Disks"] {
      dir += "/" + part
      if mkdir(dir, 0o700) != 0 && errno != EEXIST { throw HostedDiskError.io(errno) }
    }
    return dir
  }

  /// Creates a new, all-zero sparse image. Never reuses an existing file.
  public static func create(path: String, blocks: UInt64) throws -> HostedBlockDevice {
    guard blocks >= 4, blocks <= UInt64(Int64.max) / UInt64(blockBytes) else {
      throw HostedDiskError.badGeometry
    }
    let fd = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw errno == EEXIST ? HostedDiskError.exists : .io(errno) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      unlink(path)
      throw HostedDiskError.locked
    }
    guard ftruncate(fd, off_t(blocks) * off_t(blockBytes)) == 0, fullSync(fd) else {
      let e = errno
      close(fd)
      unlink(path)
      throw HostedDiskError.io(e)
    }
    syncDirectory(of: path)
    return HostedBlockDevice(fd: fd, path: path, blocks: blocks, readOnly: false)
  }

  /// Opens an existing image. Its size must be a whole number of blocks.
  public static func open(path: String, readOnly: Bool = false) throws -> HostedBlockDevice {
    let fd = Darwin.open(path, (readOnly ? O_RDONLY : O_RDWR) | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw errno == ENOENT ? HostedDiskError.notFound : .io(errno) }
    guard flock(fd, (readOnly ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
      close(fd)
      throw HostedDiskError.locked
    }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0,
      st.st_size % off_t(blockBytes) == 0, st.st_size / off_t(blockBytes) >= 4
    else {
      close(fd)
      throw HostedDiskError.badGeometry
    }
    return HostedBlockDevice(
      fd: fd, path: path, blocks: UInt64(st.st_size) / UInt64(blockBytes), readOnly: readOnly)
  }

  private func range(_ block: UInt64, _ bytes: Int) -> off_t? {
    guard bytes > 0, bytes % Self.blockBytes == 0, block < blocks,
      UInt64(bytes / Self.blockBytes) <= blocks - block
    else { return nil }
    return off_t(block) * off_t(Self.blockBytes)
  }

  /// Reads whole blocks. A short read or error fails the whole call.
  public func read(_ block: UInt64, into dst: UnsafeMutableRawBufferPointer) -> Bool {
    guard let base = dst.baseAddress, let off = range(block, dst.count) else { return false }
    var done = 0
    while done < dst.count {
      let n = pread(fd, base + done, dst.count - done, off + off_t(done))
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { return false }
      done += n
    }
    return true
  }

  public func write(_ block: UInt64, from src: UnsafeRawBufferPointer) -> Bool {
    guard !readOnly, let base = src.baseAddress, let off = range(block, src.count) else {
      return false
    }
    var done = 0
    while done < src.count {
      let n = pwrite(fd, base + done, src.count - done, off + off_t(done))
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { return false }
      done += n
    }
    return true
  }

  /// Stable-storage barrier: all earlier completed writes are durable.
  public func flush() -> Bool { !readOnly && Self.fullSync(fd) }

  /// Returns blocks to the host file system; they read back as zeros.
  public func discard(_ block: UInt64, count: UInt64) -> Bool {
    guard !readOnly, count > 0, count <= UInt64(Int.max / Self.blockBytes),
      let off = range(block, Int(count) * Self.blockBytes)
    else { return false }
    var arg = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off,
      fp_length: off_t(count) * off_t(Self.blockBytes))
    if fcntl(fd, F_PUNCHHOLE, &arg) == 0 { return true }
    return zeroFill(block, count: count)
  }

  public func zero(_ block: UInt64, count: UInt64) -> Bool { discard(block, count: count) }

  private func zeroFill(_ block: UInt64, count: UInt64) -> Bool {
    let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.blockBytes, alignment: 16)
    defer { chunk.deallocate() }
    chunk.initializeMemory(as: UInt8.self, repeating: 0)
    for b in block..<(block + count) where !write(b, from: .init(chunk)) { return false }
    return true
  }

  static func fullSync(_ fd: Int32) -> Bool {
    if fcntl(fd, F_FULLFSYNC) == 0 { return true }
    return fsync(fd) == 0
  }

  private static func syncDirectory(of path: String) {
    guard let slash = path.lastIndex(of: "/") else { return }
    let dir = slash == path.startIndex ? "/" : String(path[..<slash])
    let d = Darwin.open(dir, O_RDONLY | O_CLOEXEC)
    if d >= 0 {
      _ = fullSync(d)
      close(d)
    }
  }
}
