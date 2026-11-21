import TarwinArchAarch64
import TarwinLoader
import TarwinObject
import TarwinProcessKeys
import TarwinRandomCore
import TarwinW0Verify

#if hasFeature(Embedded) && arch(arm64) && os(none)
  @_extern(c, "tarwin_w1_sign_private_import")
  private func signIA(
    _ target: UInt64, _ modifier: UInt64, _ pair: UnsafePointer<UInt64>, _ host: UInt64
  ) -> UInt64
#endif

func signProcessImport(
  _ target: UInt64, _ modifier: UInt64, plan: W1AddressPlan, root: UInt64, host: UInt64,
  child: borrowing ProcessExecution, tree: borrowing JobTree, keys: borrowing ArmProcessKeys,
  current: () -> RandomEpoch?,
  _ sign: (UInt64, UInt64, UnsafePointer<UInt64>, UInt64) -> UInt64
) -> UInt64? {
  guard root != host, target == plan.targetAddress, modifier == plan.storageModifier else {
    return nil
  }
  return keys.withImportIA(child: child, root: root, tree: tree, current: current) { ia in
    guard ia.count == 2, let p = ia.baseAddress else { return nil }
    let result = sign(target, modifier, p, host)
    return result == 0 ? nil : result
  }
}

/// Pin the private frame pool first, create the non-runnable child with its
/// physical base as initialMap, then provision its non-exportable key bank.
/// Keep the tree, task and map locked and the archive, scratch and key bank
/// disjoint from the pool. On failure retire the unpublished child and keys.
/// Serialize live generation sampling and signing against VM restoration.
@unsafe public func preparePrivateW1Images(
  _ set: borrowing W1BootSet, plan: W1AddressPlan,
  archive: UnsafeRawBufferPointer, storage: UnsafeMutableRawBufferPointer,
  physical: UInt64, tableBytes: Int, nodes: UnsafeMutableBufferPointer<BlakeCv>,
  witnesses: UnsafeMutableRawBufferPointer, cleanToPoU: (UnsafeRawBufferPointer) -> Bool,
  child: borrowing ProcessExecution, tree: borrowing JobTree, keys: borrowing ArmProcessKeys,
  generation: W1KernelGeneration,
  host: borrowing ArmFinishedKernelRoot, clockPage: borrowing W1ClockPage,
  firstThread: consuming W1ThreadPlacement
) -> W1PrivateImages? {
  guard host.physical != physical, host.physical == clockPage.mapping.hostRoot else { return nil }
  return preparePrivateW1Images(
    set, plan: plan, archive: archive, storage: storage, physical: physical,
    tableBytes: tableBytes, nodes: nodes, witnesses: witnesses, cleanToPoU: cleanToPoU,
    child: child, tree: tree, layout: host.layout, clockPage: clockPage,
    signImport: { target, modifier in
      signProcessImport(
        target, modifier, plan: plan, root: physical, host: host.physical,
        child: child, tree: tree, keys: keys, current: { generation.current(in: host) }
      ) { address, slot, pair, ttbr1 in
        #if hasFeature(Embedded) && arch(arm64) && os(none)
          signIA(address, slot, pair, ttbr1)
        #else
          0
        #endif
      }
    }, firstThread: consume firstThread)
}
