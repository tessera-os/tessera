import TarwinArchAarch64
import TarwinLoader
import TarwinObject
import TarwinW0Verify

/// Only an unpublished address space. Keep the backing pinned and private;
/// PCR/log publication, thread creation, GCS and activation are separate.
public struct W1PrivateImages: ~Copyable {
  public private(set) var tables: ArmUserTranslation
  public let processCode, libraryCode: Range<UInt64>
  public let processEntry: UInt64
  public let initialThread: W1ThreadStorage?
  let owner: ProcessKey
  let header: UnsafePointer<ObjectHeader>
  let authorized: W1BootSet
  let archive: UnsafeRawBufferPointer
  func belongs(to child: borrowing ProcessExecution) -> Bool {
    owner == child.member && header == child.header && child.initialMap == tables.physicalRoot
  }
  /// Includes page tables. The caller must pin at least this prefix.
  public let usedBytes: Int
}

private func disjoint(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Bool {
  guard let x = a.baseAddress, let y = b.baseAddress else { return false }
  let u = UInt(bitPattern: x)
  let v = UInt(bitPattern: y)
  return u <= v ? UInt(a.count) <= v - u : UInt(b.count) <= u - v
}

/// Hold the committed reservations and original immutable archive. Supply one
/// exclusive contiguous run of normal RAM at `physical` and disjoint scratch.
/// No frame, table, scratch or archive may alias physically, including DMA.
/// On failure no root escapes; erase any staged image pages and descriptors.
@unsafe func preparePrivateW1Images(
  _ set: borrowing W1BootSet, plan: W1AddressPlan,
  archive: UnsafeRawBufferPointer, storage: UnsafeMutableRawBufferPointer,
  physical: UInt64, tableBytes: Int, nodes: UnsafeMutableBufferPointer<BlakeCv>,
  witnesses: UnsafeMutableRawBufferPointer, cleanToPoU: (UnsafeRawBufferPointer) -> Bool,
  child: borrowing ProcessExecution, tree: borrowing JobTree, layout: ArmPermissionLayout = .direct,
  clockPage: borrowing W1ClockPage,
  signImport: (UInt64, UInt64) -> UInt64?, firstThread: consuming W1ThreadPlacement? = nil
) -> W1PrivateImages? {
  let ram = UnsafeRawBufferPointer(storage)
  let cache = UnsafeRawBufferPointer(nodes)
  let proof = UnsafeRawBufferPointer(witnesses)
  guard child.initialMap == physical, child.phase == .created, child.threadCount == 0,
    tree.returnGate(child.member) == .run,
    tableBytes >= 16384, tableBytes < storage.count, (tableBytes | storage.count) & 16383 == 0,
    physical != 0, physical & 16383 == 0, physical < 1 << 48,
    UInt64(storage.count) <= (1 << 48) - physical,
    clockPage.mapping.permitsPrivateStorage(physical..<physical + UInt64(storage.count)),
    !plan.processReservation.overlaps(plan.libraryReservation),
    disjoint(ram, cache), disjoint(ram, proof), disjoint(cache, proof),
    disjoint(archive, cache), disjoint(archive, proof),
    exactMember(set.process.bytes, in: archive, at: set.process.range, excluding: storage),
    exactMember(set.library.bytes, in: archive, at: set.library.range, excluding: storage),
    var tables = ArmUserTranslation(
      backing: .init(rebasing: storage[..<tableBytes]), physical: physical, layout: layout)
  else { return nil }
  var finished = false
  defer { if !finished { storage.initializeMemory(as: UInt8.self, repeating: 0) } }
  guard clockPage.mapping.install(in: &tables, privatePool: physical..<physical + UInt64(storage.count))
  else { return nil }
  var pool = W1FramePool(
    memory: .init(rebasing: storage[tableBytes...]), physical: physical + UInt64(tableBytes))
  func stage(_ role: W1CodeRole, _ tables: inout ArmUserTranslation, _ pool: inout W1FramePool)
    -> Range<UInt64>?
  {
    pool.stageMember(role, set: set, plan: plan, nodes: nodes, witnesses: witnesses,
      tables: &tables, cleanToPoU: cleanToPoU)
  }
  guard let process = stage(.process, &tables, &pool),
    let library = stage(.library, &tables, &pool), let slot = pool.slotOffset,
    bindAuthorizedQEMUImport(
      set, plan: plan, tables: &tables,
      frame: .init(rebasing: pool.memory[slot..<slot + 16384]),
      physical: pool.physical + UInt64(slot),
      sign: signImport)
  else { return nil }
  var installed: W1ThreadStorage?
  if let thread = consume firstThread {
    guard let result = pool.stageThread(thread, tables: &tables) else { return nil }
    installed = result
  }
  finished = true
  return W1PrivateImages(
    tables: consume tables, processCode: process, libraryCode: library,
    processEntry: plan.processEntry, initialThread: installed, owner: child.member,
    header: child.header, authorized: set, archive: archive, usedBytes: tableBytes + pool.used)
}
