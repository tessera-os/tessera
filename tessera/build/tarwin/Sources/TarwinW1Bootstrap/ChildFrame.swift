import TarwinArchAarch64
import TarwinArmBootstrap
import TarwinIPCChannels
import TarwinObject

extension W1PrivateImages {
  /// Transfer only the grants selected by trusted launch policy. Check the
  /// bound root and return gate before moving any staging handle. Keep the
  /// same locks through initialFrame; on failure tear down the unpublished task.
  public func preloadStartup(
    child: inout ProcessExecution, tree: borrowing JobTree, channel: inout ChannelPair,
    app: UInt64, flags: UInt32, tags: UnsafeBufferPointer<UInt32>,
    names: UnsafeBufferPointer<UInt64>,
    staging: inout HandleTable, scratch: UnsafeMutableRawBufferPointer,
    invalidate: (UInt64) -> Void, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> ChildBootstrap? {
    guard initialThread != nil, belongs(to: child),
      tree.returnGate(child.member) == .run
    else { return nil }
    return channel.preloadStartup(
      child: &child, tree: tree, app: app, flags: flags,
      tags: tags, names: names, staging: &staging, scratch: scratch,
      invalidate: invalidate, retire: retire)
  }

  /// Registers only. The caller cannot substitute the verified entry, root,
  /// RX interval or initialized TLS/stack from a different image set.
  /// Hold exclusive child/channel ownership; no measurement, keys or ERET.
  public func initialFrame(
    _ bootstrap: ChildBootstrap, child: borrowing ProcessExecution,
    tree: borrowing JobTree, channel: borrowing ChannelPair
  ) -> ArmInitialState? {
    guard let thread = initialThread, belongs(to: child) else { return nil }
    return initialArmChildFrame(
      bootstrap, child: child, tree: tree, channel: channel, tables: tables,
      entry: processEntry, imageRX: processCode, stack: thread.stack, tcb: thread.tcb)
  }

  /// Fill a fresh aligned kernel-only frame (no user or DMA aliases).
  /// Hold the child, channel and map locks. This does not start the thread,
  /// install its keys/GCS, publish a root or transfer control.
  @unsafe public func stageGuardedFirstFrame(
    _ bootstrap: ChildBootstrap, child: borrowing ProcessExecution,
    tree: borrowing JobTree, channel: borrowing ChannelPair,
    into frame: UnsafeMutableRawBufferPointer
  ) -> ArmInitialControlStack? {
    guard frame.count == ArmTrapLayout.size, let p = frame.baseAddress,
      UInt(bitPattern: p) & 15 == 0, let thread = initialThread,
      let regs = initialFrame(bootstrap, child: child, tree: tree, channel: channel),
      let gcs = ArmInitialControlStack(
        tables: tables, shadow: thread.shadow, physical: thread.shadowPhysical,
        stackBytes: thread.stack.upperBound - thread.stack.lowerBound)
    else { return nil }
    // No trap occurred. ESR, FP status, vectors and every GPR but x0
    // start at zero. No kernel pointers, PAC material or TBIB in the bank.
    frame.initializeMemory(as: UInt8.self, repeating: 0)
    p.storeBytes(of: regs.gpr[0], as: UInt64.self)
    p.storeBytes(of: regs.sp, toByteOffset: ArmTrapLayout.sp, as: UInt64.self)
    p.storeBytes(of: regs.elr, toByteOffset: ArmTrapLayout.elr, as: UInt64.self)
    p.storeBytes(of: regs.tpidr, toByteOffset: ArmTrapLayout.tpidr, as: UInt64.self)
    return gcs
  }
}
