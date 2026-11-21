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
}
