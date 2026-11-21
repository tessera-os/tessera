import Darwin
import TarwinArchHosted

extension HostedAddressSpace {
  public func resumeAfterFileFault(_ exception: HostException) throws -> HostExceptionDisposition? {
    guard exception.kind == .badAccess,
      exception.code == UInt64(KERN_INVALID_ADDRESS),
      exception.pc != exception.faultAddress
    else { return nil }
    guard try fault(address: exception.faultAddress, access: .read) == .mapped else { return nil }
    return .resume(exception.state)
  }
}
