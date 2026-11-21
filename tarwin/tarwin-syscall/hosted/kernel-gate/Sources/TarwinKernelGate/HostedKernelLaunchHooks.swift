import TarwinHostedImage
import TarwindKernel

/// Create one adapter per Tarwind instance so enrollment stays in its process namespace.
public final class HostedKernelLaunchHooks: Sendable {
  public let hooks: TarwindLaunchHooks
  private let registry: VerifiedTrapRegistry<TarwindProcessID>

  public init() {
    let registry = VerifiedTrapRegistry<TarwindProcessID>()
    self.registry = registry
    hooks = TarwindLaunchHooks(
      rewrite: { image, code, rva, imageBase, veneersAt in
        try HostedTrapRewrite.rewrite(code, rva, imageBase, veneersAt, verifiedTrapRVAs: image.trapRVAs)
      },
      authorizeTrap: { process, fault in
        guard fault.kind == .breakpoint,
          let trap = registry.match(
            process: process, kernelThreadID: fault.thread.threadID, pc: fault.pc, registers: fault.x)
        else { return nil }
        return TrapAuthorization(threadID: trap.threadID, originalPC: trap.originalPC,
          resumePC: trap.resumePC, number: trap.number, arguments: (0..<8).map { trap.arguments[$0] })
      },
      enroll: { process, sites, threads in
        _ = registry.enroll(process, siteMap: sites, threads: threads)
      })
  }

  public func removeProcess(_ process: TarwindProcessID) {
    registry.removeProcess(process)
  }
}
