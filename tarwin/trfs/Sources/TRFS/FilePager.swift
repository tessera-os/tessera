import TarwinMM

/// A file object is bound to one stable snapshot/version and extent map before
/// entering the pager. The volume owns allocation and encryption; load/store
/// may use encryptedPageIn/encryptedWriteback, never plaintext driver DMA.
public protocol TrfsPageStore {
  mutating func mayFault(object: UInt64, write: Bool) -> Bool
  mutating func acquireFrame(bytes: UInt64) -> UInt64?
  mutating func load(object: UInt64, offset: UInt64, valid: UInt64, into frame: UInt64) -> Bool
  mutating func clear(frame: UInt64, from: UInt64, to: UInt64)
  mutating func store(object: UInt64, offset: UInt64, valid: UInt64, from frame: UInt64) -> Bool
  mutating func releaseFrame(_ frame: UInt64, bytes: UInt64)
}

public struct CachedFilePage {
  fileprivate var object: UInt64 = 0, offset: UInt64 = 0, frame: UInt64 = 0
  fileprivate var valid: UInt64 = 0, size: UInt64 = 0
  fileprivate var references: Int = 0, writer = false, dirty = false
  public init() {}
}
public struct FileLeaseRecord {
  fileprivate var token: UInt64 = 0, page: Int = 0, writable = false
  public init() {}
}

/// All copies of the VM's FilePager view share one serialized state. The
/// caller owns the initialized slabs and store until shutdown() succeeds.
public struct TrfsPagerState<Store: TrfsPageStore>: ~Copyable {
  fileprivate var store: Store
  fileprivate let pages: UnsafeMutableBufferPointer<CachedFilePage>
  fileprivate let leases: UnsafeMutableBufferPointer<FileLeaseRecord>
  fileprivate var issued: UInt64 = 0
  public init(
    store: Store, pages: UnsafeMutableBufferPointer<CachedFilePage>,
    leases: UnsafeMutableBufferPointer<FileLeaseRecord>
  ) {
    self.store = store
    self.pages = pages
    self.leases = leases
  }
}

public struct TrfsFilePager<Store: TrfsPageStore>: FilePager {
  private let state: UnsafeMutablePointer<TrfsPagerState<Store>>
  public init(state: UnsafeMutablePointer<TrfsPagerState<Store>>) { self.state = state }

  public mutating func pinFilePage(
    _ object: UInt64, offset: UInt64, validBytes: UInt64,
    pageSize: UInt64, write: Bool
  ) -> FilePageLease {
    let none = FilePageLease(token: 0, physical: 0)
    guard object != 0, pageSize == 4096 || pageSize == 16384, offset % pageSize == 0,
      validBytes > 0, validBytes <= pageSize,
      offset <= UInt64.max - (validBytes - 1), state.pointee.issued != .max,
      state.pointee.store.mayFault(object: object, write: write)
    else { return none }
    let pages = state.pointee.pages
    let leases = state.pointee.leases
    guard let lease = leases.indices.first(where: { leases[$0].token == 0 }) else { return none }
    let index: Int
    if let existing = pages.indices.first(where: {
      pages[$0].object == object && pages[$0].offset == offset
    }) {
      guard pages[existing].size == pageSize, pages[existing].valid == validBytes,
        !pages[existing].writer, !write || pages[existing].references == 0
      else { return none }
      index = existing
    } else {
      guard
        let available = pages.indices.first(where: { pages[$0].object == 0 })
          ?? pages.indices.first(where: { pages[$0].references == 0 && !pages[$0].dirty })
      else { return none }
      index = available
      discardClean(index)
      guard let frame = state.pointee.store.acquireFrame(bytes: pageSize) else { return none }
      guard frame % pageSize == 0, frame <= .max - (pageSize - 1),
        state.pointee.store.load(object: object, offset: offset, valid: validBytes, into: frame)
      else {
        // Allocator owns frame validity; releaseFrame must scrub even after failed I/O.
        state.pointee.store.releaseFrame(frame, bytes: pageSize)
        return none
      }
      state.pointee.store.clear(frame: frame, from: validBytes, to: pageSize)
      pages[index].object = object
      pages[index].offset = offset
      pages[index].frame = frame
      pages[index].size = pageSize
      pages[index].valid = validBytes
    }
    state.pointee.issued += 1
    let token = state.pointee.issued
    leases[lease].token = token
    leases[lease].page = index
    leases[lease].writable = write
    pages[index].references += 1
    pages[index].writer = write
    return FilePageLease(token: token, physical: pages[index].frame)
  }

  public mutating func unpinFilePage(_ token: UInt64, dirty: Bool) {
    let pages = state.pointee.pages
    let leases = state.pointee.leases
    guard token != 0, let i = leases.indices.first(where: { leases[$0].token == token }) else {
      return
    }
    let index = leases[i].page
    if leases[i].writable {
      pages[index].writer = false
      pages[index].dirty = pages[index].dirty || dirty
      // A writable PTE covers the entire last page, including bytes past EOF.
      state.pointee.store.clear(
        frame: pages[index].frame, from: pages[index].valid, to: pages[index].size)
    }
    pages[index].references -= 1
    leases[i] = FileLeaseRecord()
  }

  public mutating func flush(object: UInt64) -> Bool {
    let pages = state.pointee.pages
    for i in pages.indices where pages[i].object == object {
      if pages[i].writer { return false }
      if pages[i].dirty {
        let p = pages[i]
        guard
          state.pointee.store.store(object: object, offset: p.offset, valid: p.valid, from: p.frame)
        else { return false }
        pages[i].dirty = false
      }
    }
    return true
  }

  private func discardClean(_ i: Int) {
    let pages = state.pointee.pages
    if pages[i].object != 0 {
      state.pointee.store.releaseFrame(pages[i].frame, bytes: pages[i].size)
      pages[i] = CachedFilePage()
    }
  }

  /// VM must unmap and synchronize CPU TLBs before dropping its final lease.
  /// A failed writeback or an outstanding lease keeps the slab alive.
  public mutating func shutdown() -> Bool {
    let pages = state.pointee.pages
    if pages.contains(where: { $0.references != 0 }) { return false }
    for i in pages.indices where pages[i].object != 0 {
      guard flush(object: pages[i].object) else { return false }
      discardClean(i)
    }
    return true
  }
}
