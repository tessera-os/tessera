import TarwinArchAarch64
import TarwinIPCChannels
import TarwinObject

/// Construct registers only. The caller exclusively owns the child task,
/// channel, root and all backing frames from setup through publication.
/// Use the private image set's exact process RX and its plan's entry, never
/// an address supplied by the child. No key, PCR or launch authority here.
public func initialArmChildFrame(
  _ bootstrap: ChildBootstrap, child: borrowing ProcessExecution, tree: borrowing JobTree,
  channel: borrowing ChannelPair, tables: borrowing ArmUserTranslation,
  entry: UInt64, imageRX: Range<UInt64>, stack: Range<UInt64>, tcb: UInt64
) -> ArmInitialState? {
  guard
    let name = channel.entryName(
      bootstrap, child: child, tree: tree, initialMap: tables.physicalRoot)
  else { return nil }
  return ArmInitialState(
    tables: tables, entry: entry, imageRX: imageRX,
    bootstrapChannel: name, stack: stack, tcb: tcb)
}
