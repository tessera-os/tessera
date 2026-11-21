import TarwinABI
import TarwinHV
import TarwinObject
import TarwinSyscall

public enum RegisterBufferAccess { case readFromCaller, writeToCaller }

public protocol RegisterCallContext {
  associatedtype Pin
  var userRange: Range<UInt64> { get }
  /// Invoke lookup inside the current caller's table read epoch. Only the retained result escapes.
  mutating func inCallerEpoch(_ lookup: (HandleReadView) -> PinResult) -> PinResult
  mutating func retire(_ object: UnsafePointer<ObjectHeader>)
  /// The retained header identifies one vCPU and keeps its backing alive across these operations.
  func integerCount(of cpu: UnsafePointer<ObjectHeader>) -> Int?
  /// Hold the same lock as run's begin/finish transitions for the entire body.
  mutating func withStateLocked(
    _ cpu: UnsafePointer<ObjectHeader>, _ body: (VirtualCpuState, GuestIntegerRegisters) -> HvError
  ) -> HvError
  /// Fault in, check permissions and pin the entire range in the caller's address space, or return nil.
  /// Failure must release any partial reservation. A successful pin makes both copies nonfaulting.
  mutating func pinWords(at address: UInt64, count: Int, access: RegisterBufferAccess) -> Pin?
  /// Copy all pinned words, without byte conversion, faults or further validation.
  mutating func read(_ pin: Pin, into words: UnsafeMutableBufferPointer<UInt64>)
  mutating func write(_ pin: Pin, from words: UnsafeBufferPointer<UInt64>)
  mutating func unpin(_ pin: Pin)
}

/// Private train ABI: (vCPU handle, set selector, user address, word count). Set 0 is integer-only.
public struct IntegerRegisterCalls<C: RegisterCallContext>: CallProvider {
  public var context: C
  public init(_ context: C) { self.context = context }

  public func argumentCount(for number: UInt64) -> UInt32? {
    number == TarwinCall.virtualCpuGetRegisters || number == TarwinCall.virtualCpuSetRegisters
      ? 4 : nil
  }

  public mutating func copyUserWords(
    from address: UInt64, into words: UnsafeMutableBufferPointer<UInt64>
  ) -> Bool {
    false  // All four arguments fit in the register window on each ISA.
  }

  private func error(_ code: UInt32) -> CallResult { CallResult(status: syscallStatus(code, 1)) }

  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard argumentCount(for: number) != nil else { return error(10) }
    guard words.count == 4 else { return error(1) }
    let get = number == TarwinCall.virtualCpuGetRegisters
    let right: UInt64 = get ? 1 << 2 : 1 << 9  // Read / Manage
    switch context.inCallerEpoch({
      $0.pinWithinEpoch(words[0], kind: TarwinKind.virtualCpu, need: right)
    }) {
    case .invalidHandle: return error(2)
    case .wrongType: return error(3)
    case .accessDenied: return error(4)
    case .found(let grant):
      let result = transfer(grant.header, number, get, words)
      grant.drop { context.retire($0) }
      return result
    }
  }

  private mutating func transfer(
    _ cpu: UnsafePointer<ObjectHeader>, _ number: UInt64, _ get: Bool,
    _ args: UnsafeBufferPointer<UInt64>
  ) -> CallResult {
    guard args[1] == 0 else { return error(10) }
    guard let n = context.integerCount(of: cpu), n == 16 || n == 32 else { return error(23) }
    let address = args[2]
    let range = context.userRange
    guard args[3] == UInt64(n), address != 0,
      syscallTailInRange(address, UInt64(n) * 8, range.lowerBound, range.upperBound),
      let pin = context.pinWords(
        at: address, count: n, access: get ? .writeToCaller : .readFromCaller)
    else { return error(1) }
    defer { context.unpin(pin) }
    return withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 32) { scratch in
      let bank = UnsafeMutableBufferPointer(rebasing: scratch[..<n])
      if !get {
        context.read(pin, into: bank)
        for i in bank.indices { bank[i] = UInt64(littleEndian: bank[i]) }
      }
      let status = context.withStateLocked(cpu) { state, registers in
        registers.transfer(number, cpu: state, words: bank)
      }
      switch status {
      case .ok:
        if get {
          for i in bank.indices { bank[i] = bank[i].littleEndian }
          context.write(pin, from: UnsafeBufferPointer(bank))
        }
        return CallResult()
      case .busy: return error(22)
      case .invalid: return error(1)
      default: return error(23)
      }
    }
  }
}
