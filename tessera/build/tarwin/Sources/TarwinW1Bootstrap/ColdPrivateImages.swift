#if TARWIN_NON_RESTORABLE_DEBUG && hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
import TarwinArchAarch64
import TarwinBoot
import TarwinKernelRandom
import TarwinLoader
import TarwinRandomCore
import TarwinW0Verify

/// Owns the unpublished private root, image reservations and first-thread
/// storage. Not runnable: import binding, clock, channel and host context
/// must be installed before the table writer can be consumed.
public struct W1ColdPrivateImages: ~Copyable {
  let verified: W1ColdVerifiedSet
  let layout: W1ColdLogLayout
  var tables: ArmUserTranslation
  let plan: W1AddressPlan
  let pool: W1FramePool
  let thread: W1ThreadStorage

  public borrowing func measureInit<P: TpmPort>(port: inout P) -> UnsafeRawBufferPointer? {
    verified.measureFirstInit(layout: layout, port: &port)
  }
}

extension W1ColdVerifiedSet {
  /// One CPU, the checked cold map, no allocator and no device DMA. The
  /// frame pool, table arena and verification scratch are physical partitions
  /// of one conventional RAM run, not aliases of the archive or event log.
  @unsafe public func stageImages(map: UnsafeRawBufferPointer, launch: inout FixedDebugRandomLaunch,
    cleanToPoU: (UnsafeRawBufferPointer) -> Bool) -> W1ColdPrivateImages? {
    let page = 16384
    func round(_ bytes: Int) -> Int { (bytes + page - 1) & ~(page - 1) }
    let p = set.process.bytes.count, l = set.library.bytes.count
    guard p <= 8 << 20, l <= 8 << 20,
      let count = NativePageIndex.capacity(fileBytes: max(p, l)) else { return nil }
    let cache = round(count * MemoryLayout<BlakeCv>.stride)
    let proof = round(16 * 54 * 32)
    let tablesSize = 32 * page
    let frames = round(p) + round(l) + 16 * page
    let bytes = cache + proof + tablesSize + frames
    guard let layout = W1ColdLogLayout(boot: boot, map: map, privateBytes: UInt64(bytes)),
      let memory = UnsafeMutableRawPointer(bitPattern: UInt(layout.privatePages.lowerBound))
    else { return nil }
    let ram = UnsafeMutableRawBufferPointer(start: memory, count: bytes)
    guard exactMember(set.process.bytes, in: archive, at: set.process.range, excluding: ram),
      exactMember(set.library.bytes, in: archive, at: set.library.range, excluding: ram) else { return nil }
    var keep = false
    defer { if !keep { ram.initializeMemory(as: UInt8.self, repeating: 0) } }
    let nodes = UnsafeMutableRawBufferPointer(rebasing: ram[..<cache]).bindMemory(to: BlakeCv.self)
    let witnesses = UnsafeMutableRawBufferPointer(rebasing: ram[cache..<cache + proof])
    let base = cache + proof
    let root = layout.privatePages.lowerBound + UInt64(base)
    let generation = launch.generation
    guard let plan = set.addressPlan(occupied: .init(start: nil, count: 0),
      nextRandom: { launch.random.word(generation: generation) }),
      let placement = W1ThreadPlacement(stackBytes: 4 * UInt64(page),
        random: &launch.random, generation: { generation }),
      var tables = ArmUserTranslation(backing: .init(rebasing: ram[base..<base + tablesSize]),
        physical: root, layout: .guarded) else { return nil }
    var pool = W1FramePool(memory: .init(rebasing: ram[(base + tablesSize)...]),
      physical: root + UInt64(tablesSize))
    guard pool.stageMember(.process, set: set, plan: plan, nodes: nodes,
      witnesses: witnesses, tables: &tables, cleanToPoU: cleanToPoU) != nil,
      pool.stageMember(.library, set: set, plan: plan, nodes: nodes,
        witnesses: witnesses, tables: &tables, cleanToPoU: cleanToPoU) != nil,
      pool.slotOffset != nil, let thread = pool.stageThread(placement, tables: &tables)
    else { return nil }
    keep = true
    return W1ColdPrivateImages(verified: self, layout: layout, tables: consume tables,
      plan: plan, pool: pool, thread: thread)
  }
}
#endif
