import TarwinSyscall

// Keep the original set on the host stack. Between stage and restore the
// guest adds two of the replaced registers; the monitor checks every slot.
struct IntegerCheck {
  let regs: GuestIntegerRegisters
  let stack: Int, ram: UInt64, zero: Bool
  private var saved = InlineArray<32, UInt64>(repeating: 0)

  init(_ regs: GuestIntegerRegisters, stack: Int, ram: UInt64, zero: Bool = false) {
    self.regs = regs
    self.stack = stack
    self.ram = ram
    self.zero = zero
  }

  private func value(_ i: Int) -> UInt64 {
    if i == stack { return ram + 512 }
    if i == 0 && zero { return 0 }
    return 0x1234_9876_0000_0000 | UInt64(i + 1)
  }

  mutating func stage(_ cpu: VirtualCpuState) -> Bool {
    withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 32) { scratch in
      let words = UnsafeMutableBufferPointer(rebasing: scratch[..<regs.count])
      guard regs.transfer(TarwinCall.virtualCpuGetRegisters, cpu: cpu, words: words) == .ok
      else { return false }
      for i in words.indices {
        saved[i] = words[i]
        words[i] = value(i)
      }
      return regs.transfer(TarwinCall.virtualCpuSetRegisters, cpu: cpu, words: words) == .ok
    }
  }

  func restore(_ cpu: VirtualCpuState, sum: Int, lhs: Int, rhs: Int) -> Bool {
    withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 32) { scratch in
      let words = UnsafeMutableBufferPointer(rebasing: scratch[..<regs.count])
      guard regs.transfer(TarwinCall.virtualCpuGetRegisters, cpu: cpu, words: words) == .ok
      else { return false }
      for i in words.indices {
        guard words[i] == (i == sum ? value(lhs) &+ value(rhs) : value(i)) else { return false }
        words[i] = saved[i]
      }
      return regs.transfer(TarwinCall.virtualCpuSetRegisters, cpu: cpu, words: words) == .ok
    }
  }
}
