import Darwin
import Foundation

/// A folder the user picked in Tessera.app, kept as a security-scoped
/// bookmark. Access lasts until `end()`; tarwind serves the folder only
/// while the grant is open.
public final class HostFolderGrant: @unchecked Sendable {
  public let url: URL
  private var open: Bool
  public private(set) var stale: Bool

  public init(bookmark: Data) throws {
    var stale = false
    url = try URL(
      resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    self.stale = stale
    open = url.startAccessingSecurityScopedResource()
  }
  /// For a picked URL: the bookmark to store so the grant survives relaunch.
  public static func bookmark(for url: URL, readOnly: Bool) throws -> Data {
    try url.bookmarkData(
      options: readOnly ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        : [.withSecurityScope],
      includingResourceValuesForKeys: nil, relativeTo: nil)
  }
  /// The granted folder opened as a directory, to send to tarwind over XPC.
  /// The caller owns the descriptor; keep the grant open until unshare.
  public func directoryFD() -> Int32? {
    let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    return fd >= 0 ? fd : nil
  }
  public func volume(readOnly: Bool) -> HostFolderVolume? {
    HostFolderVolume(path: url.path, readOnly: readOnly)
  }
  public func end() {
    if open { url.stopAccessingSecurityScopedResource() }
    open = false
  }
  deinit { end() }
}
