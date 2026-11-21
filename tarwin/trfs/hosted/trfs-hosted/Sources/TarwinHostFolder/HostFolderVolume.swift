import Darwin
import Synchronization
import TarwinFsWire
import TarwinReadOnlyFS

/// A Mac folder the user granted through the picker, served to Tarwin as an
/// A.5 volume. Every path is walked from the granted directory one component
/// at a time with O_NOFOLLOW, so `..`, `/` and symbolic links never leave it.
/// Node numbers are volume-local and never reused for a different path.
///
/// Request shapes beyond the read-only set: `create` takes the name as input
/// and the kind in `offset` (1 file, 2 directory) and returns the new node;
/// `remove` takes the name; `rename` takes `old 0x00 new` from directory
/// `node` to directory `other`; `setAttributes` sets the file size to
/// `offset`; `statFileSystem` returns total and free bytes.
public final class HostFolderVolume: @unchecked Sendable {
  public static let root: UInt64 = 1
  public let readOnly: Bool
  private let rootFD: Int32
  private struct Table {
    var paths: [UInt64: [[UInt8]]] = [1: []]
    var ids: [[[UInt8]]: UInt64] = [[]: 1]
    var next: UInt64 = 2
  }
  private let table = Mutex(Table())

  public convenience init?(path: String, readOnly: Bool = false) {
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    self.init(directoryFD: fd, readOnly: readOnly)
  }
  /// Serves the directory open at `fd`, as Tessera.app hands it to tarwind
  /// over XPC. Takes ownership of `fd`, also when it fails (not a directory).
  public init?(directoryFD fd: Int32, readOnly: Bool = false) {
    var st = stat()
    guard fd >= 0, fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
      fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
    else {
      if fd >= 0 { close(fd) }
      return nil
    }
    rootFD = fd
    self.readOnly = readOnly
  }
  deinit { close(rootFD) }

  // MARK: node table

  func path(_ node: UInt64) -> [[UInt8]]? { table.withLock { $0.paths[node] } }
  func id(for path: [[UInt8]]) -> UInt64 {
    table.withLock { t in
      if let id = t.ids[path] { return id }
      let id = t.next
      t.next += 1
      t.paths[id] = path
      t.ids[path] = id
      return id
    }
  }
  private func forget(_ prefix: [[UInt8]]) {
    table.withLock { t in
      for (id, p) in t.paths where p.starts(with: prefix) && id != Self.root {
        t.paths[id] = nil
        t.ids[p] = nil
      }
    }
  }
  private func move(_ from: [[UInt8]], _ to: [[UInt8]]) {
    forget(to)
    table.withLock { t in
      for (id, p) in t.paths where p.starts(with: from) {
        let moved = to + p.dropFirst(from.count)
        t.ids[p] = nil
        t.paths[id] = moved
        t.ids[moved] = id
      }
    }
  }

  // MARK: confined access

  static func validName(_ n: [UInt8]) -> Bool {
    !n.isEmpty && n.count <= 255 && !n.contains(0) && !n.contains(47) && n != [46] && n != [46, 46]
  }
  private static func cstr<R>(_ n: [UInt8], _ body: (UnsafePointer<CChar>) -> R) -> R {
    (n + [0]).withUnsafeBufferPointer { $0.withMemoryRebound(to: CChar.self) { body($0.baseAddress!) } }
  }
  /// Opens directory `dirs` under the root; the caller closes the result.
  private func openDir(_ dirs: ArraySlice<[UInt8]>) -> Int32 {
    var fd = dup(rootFD)
    for c in dirs {
      guard fd >= 0 else { return -1 }
      let n = Self.cstr(c) { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
      let e = errno
      close(fd)
      errno = e
      fd = n
    }
    return fd
  }
  /// Runs `body` with the parent directory and last name of `path`.
  private func atParent<R>(_ path: [[UInt8]], _ body: (Int32, [UInt8]) -> R) -> R? {
    guard let last = path.last else { return nil }
    let d = openDir(path.dropLast())
    guard d >= 0 else { return nil }
    defer { close(d) }
    return body(d, last)
  }
  private func lstat(_ path: [[UInt8]]) -> stat? {
    if path.isEmpty {
      var st = stat()
      return fstat(rootFD, &st) == 0 ? st : nil
    }
    return atParent(path) { d, n -> stat? in
      var st = stat()
      return Self.cstr(n) { fstatat(d, $0, &st, AT_SYMLINK_NOFOLLOW) } == 0 ? st : nil
    } ?? nil
  }
  private func openFile(_ path: [[UInt8]], _ flags: Int32) -> Int32 {
    atParent(path) { d, n in Self.cstr(n) { openat(d, $0, flags | O_NOFOLLOW | O_CLOEXEC) } } ?? -1
  }
  private static func kind(_ st: stat) -> (dir: Bool, file: Bool) {
    (st.st_mode & S_IFMT == S_IFDIR, st.st_mode & S_IFMT == S_IFREG)
  }
  static func status(_ e: Int32) -> FsStatus {
    switch e {
    case ENOENT: return .notFound
    case EACCES, EPERM, ELOOP: return .denied
    case ENOSPC, EDQUOT: return .noSpace
    case EEXIST: return .exists
    case ENOTDIR: return .notDirectory
    case ENOTEMPTY: return .notEmpty
    case EROFS: return .readOnly
    case EISDIR, EINVAL: return .invalid
    case EBUSY: return .busy
    default: return .io
    }
  }

  // MARK: requests

  private func le(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }

  private func entry(_ id: UInt64, _ path: [[UInt8]], _ st: stat) -> [UInt8]? {
    FsEntry(id: id, size: UInt64(max(0, st.st_size)), directory: Self.kind(st).dir,
      name: path.last ?? [])?.bytes()
  }

  /// Names in `dir`, sorted, without `.`, `..` and symbolic links.
  private func names(_ dir: [[UInt8]]) -> [[UInt8]]? {
    let fd = openDir(dir[...])
    guard fd >= 0, let d = fdopendir(fd) else {
      if fd >= 0 { close(fd) }
      return nil
    }
    defer { closedir(d) }
    var out: [[UInt8]] = []
    while let e = readdir(d) {
      let n = withUnsafeBytes(of: e.pointee.d_name) { Array($0.prefix(Int(e.pointee.d_namlen))) }
      guard Self.validName(n), e.pointee.d_type != DT_LNK else { continue }
      out.append(n)
    }
    return out.sorted { $0.lexicographicallyPrecedes($1) }
  }

  public func handle<S: ReadOnlyShares & ~Copyable>(_ r: FsRecord, shares: inout S) -> (
    FsStatus, UInt32
  ) {
    guard let path = path(r.node) else { return (.notFound, 0) }
    func name() -> [UInt8]? {
      guard r.inputBytes > 0, r.inputBytes <= 511,
        let n = shares.load(request: r.id, share: r.input, length: r.inputBytes),
        n.count == Int(r.inputBytes)
      else { return nil }
      return n
    }
    func reply(_ bytes: [UInt8]) -> (FsStatus, UInt32) {
      guard bytes.count <= r.outputBytes else { return (.noSpace, 0) }
      if !bytes.isEmpty
        && !shares.store(request: r.id, share: r.output, capacity: r.outputBytes, bytes: bytes)
      {
        return (.denied, 0)
      }
      return (.ok, UInt32(bytes.count))
    }
    let mutating: Set<FsOp> = [.write, .setAttributes, .create, .remove, .rename]
    if readOnly && mutating.contains(r.op) { return (.readOnly, 0) }

    switch r.op {
    case .lookup:
      guard r.offset == 0, r.outputBytes >= 8 else { return (.invalid, 0) }
      guard let n = name() else { return (.denied, 0) }
      guard Self.validName(n) else { return (.invalid, 0) }
      guard let st = lstat(path), Self.kind(st).dir else { return (.notDirectory, 0) }
      guard let child = lstat(path + [n]) else { return (Self.status(errno), 0) }
      let k = Self.kind(child)
      guard k.dir || k.file else { return (.denied, 0) }
      return reply(le(id(for: path + [n])))

    case .getAttributes:
      guard r.input == 0, r.offset == 0, r.outputBytes > 0 else { return (.invalid, 0) }
      guard let st = lstat(path) else { return (Self.status(errno), 0) }
      return entry(r.node, path, st).map(reply) ?? (.invalid, 0)

    case .readDirectory:
      guard r.input == 0, r.outputBytes > 0 else { return (.invalid, 0) }
      guard let all = names(path) else { return (Self.status(errno), 0) }
      guard r.offset < UInt64(all.count) else { return (.ok, 0) }
      let p = path + [all[Int(r.offset)]]
      guard let st = lstat(p) else { return (Self.status(errno), 0) }
      return entry(id(for: p), p, st).map(reply) ?? (.invalid, 0)

    case .read:
      guard r.input == 0, r.outputBytes <= 1 << 20, r.offset <= UInt64(Int64.max) else {
        return (.invalid, 0)
      }
      let fd = openFile(path, O_RDONLY)
      guard fd >= 0 else { return (Self.status(errno), 0) }
      defer { close(fd) }
      var buf = [UInt8](repeating: 0, count: Int(r.outputBytes))
      var done = 0
      while done < buf.count {
        let n = buf.withUnsafeMutableBytes {
          pread(fd, $0.baseAddress! + done, $0.count - done, off_t(r.offset) + off_t(done))
        }
        if n < 0 && errno == EINTR { continue }
        if n < 0 { return (Self.status(errno), 0) }
        if n == 0 { break }
        done += n
      }
      return reply(Array(buf.prefix(done)))

    case .write:
      guard r.output == 0, r.offset <= UInt64(Int64.max) else { return (.invalid, 0) }
      guard r.inputBytes <= 1 << 20,
        let data = r.inputBytes == 0
          ? [] : shares.load(request: r.id, share: r.input, length: r.inputBytes),
        data.count == Int(r.inputBytes)
      else { return (.denied, 0) }
      let fd = openFile(path, O_WRONLY)
      guard fd >= 0 else { return (Self.status(errno), 0) }
      defer { close(fd) }
      var done = 0
      while done < data.count {
        let n = data.withUnsafeBytes {
          pwrite(fd, $0.baseAddress! + done, $0.count - done, off_t(r.offset) + off_t(done))
        }
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { return (Self.status(errno), 0) }
        done += n
      }
      return (.ok, 0)

    case .setAttributes:
      guard r.input == 0, r.output == 0, r.offset <= UInt64(Int64.max) else { return (.invalid, 0) }
      let fd = openFile(path, O_WRONLY)
      guard fd >= 0 else { return (Self.status(errno), 0) }
      defer { close(fd) }
      return ftruncate(fd, off_t(r.offset)) == 0 ? (.ok, 0) : (Self.status(errno), 0)

    case .create:
      guard r.offset == 1 || r.offset == 2, r.outputBytes >= 8 else { return (.invalid, 0) }
      guard let n = name() else { return (.denied, 0) }
      guard Self.validName(n) else { return (.invalid, 0) }
      let d = openDir(path[...])
      guard d >= 0 else { return (Self.status(errno), 0) }
      defer { close(d) }
      let ok = Self.cstr(n) { c -> Bool in
        if r.offset == 2 { return mkdirat(d, c, 0o755) == 0 }
        let f = openat(d, c, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if f >= 0 { close(f) }
        return f >= 0
      }
      guard ok else { return (Self.status(errno), 0) }
      return reply(le(id(for: path + [n])))

    case .remove:
      guard r.output == 0, r.offset == 0 else { return (.invalid, 0) }
      guard let n = name() else { return (.denied, 0) }
      guard Self.validName(n), let st = lstat(path + [n]) else { return (.notFound, 0) }
      let d = openDir(path[...])
      guard d >= 0 else { return (Self.status(errno), 0) }
      defer { close(d) }
      let rc = Self.cstr(n) { unlinkat(d, $0, Self.kind(st).dir ? AT_REMOVEDIR : 0) }
      guard rc == 0 else { return (Self.status(errno), 0) }
      forget(path + [n])
      return (.ok, 0)

    case .rename:
      guard r.output == 0, r.offset == 0, let to = self.path(r.other) else {
        return (.invalid, 0)
      }
      guard let both = name(), let sep = both.firstIndex(of: 0) else { return (.invalid, 0) }
      let old = Array(both[..<sep]), new = Array(both[(sep + 1)...])
      guard Self.validName(old), Self.validName(new) else { return (.invalid, 0) }
      let from = path + [old], dest = to + [new]
      guard !dest.starts(with: from) || dest == from else { return (.invalid, 0) }
      let a = openDir(path[...]), b = openDir(to[...])
      defer {
        if a >= 0 { close(a) }
        if b >= 0 { close(b) }
      }
      guard a >= 0, b >= 0 else { return (.notFound, 0) }
      let rc = Self.cstr(old) { o in Self.cstr(new) { renameat(a, o, b, $0) } }
      guard rc == 0 else { return (Self.status(errno), 0) }
      move(from, dest)
      return (.ok, 0)

    case .flush, .sync:
      guard r.input == 0, r.output == 0, r.offset == 0 else { return (.invalid, 0) }
      if readOnly { return (.ok, 0) }
      let fd = r.op == .sync || path.isEmpty ? dup(rootFD) : openFile(path, O_RDONLY)
      guard fd >= 0 else { return (Self.status(errno), 0) }
      defer { close(fd) }
      return fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 ? (.ok, 0) : (.io, 0)

    case .statFileSystem:
      guard r.input == 0, r.offset == 0, r.outputBytes >= 16 else { return (.invalid, 0) }
      var s = statfs()
      guard fstatfs(rootFD, &s) == 0 else { return (.io, 0) }
      let bs = UInt64(s.f_bsize)
      return reply(le(s.f_blocks * bs) + le(s.f_bavail * bs))

    default:
      return (.unsupported, 0)
    }
  }
}
