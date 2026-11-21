import Synchronization

public struct VerifiedGuestTrap: Sendable {
  public let threadID: UInt64
  public let originalPC: UInt64
  public let resumePC: UInt64
  public let number: UInt64
  public let arguments: InlineArray<8, UInt64>
}

public final class VerifiedTrapRegistry<Process: Hashable & Sendable>: Sendable {
  private struct Enrollment: Sendable {
    var sites: [UInt64: UInt64] = [:]
    var threads: [UInt64: UInt64] = [:]
  }

  private let enrollments = Mutex<[Process: Enrollment]>([:])

  public init() {}

  /// Enroll committed loader sites and kernel-derived THREAD_IDENTIFIER_INFO IDs.
  public func enroll(
    _ process: Process, siteMap sites: [UInt64: UInt64], threads: [UInt64: UInt64]
  ) -> Bool {
    guard sites.allSatisfy({ pc, original in
      pc != 0 && original != 0 && (pc | original) & 3 == 0 && pc < UInt64.max - 3
    }), threads.allSatisfy({ $0.key != 0 && $0.value != 0 }) else { return false }
    return enrollments.withLock { enrollments in
      var entry = enrollments[process] ?? Enrollment()
      guard sites.allSatisfy({ pc, site in entry.sites[pc].map { $0 == site } ?? true }),
        threads.allSatisfy({ kernelID, taskID in entry.threads[kernelID].map { $0 == taskID } ?? true })
      else { return false }
      entry.sites.merge(sites) { current, _ in current }
      entry.threads.merge(threads) { current, _ in current }
      guard Set(entry.threads.values).count == entry.threads.count else { return false }
      enrollments[process] = entry
      return true
    }
  }

  /// Call only for breakpoints delivered by the process's Mach exception service.
  public func match(
    process: Process, kernelThreadID: UInt64, pc: UInt64, registers: [UInt64]
  ) -> VerifiedGuestTrap? {
    guard registers.count == 29 else { return nil }
    return enrollments.withLock { enrollment -> VerifiedGuestTrap? in
      guard let entry = enrollment[process], let original = entry.sites[pc],
        let thread = entry.threads[kernelThreadID] else { return nil }
      var arguments = InlineArray<8, UInt64>(repeating: 0)
      for index in 0..<8 { arguments[index] = registers[index] }
      return VerifiedGuestTrap(threadID: thread, originalPC: original, resumePC: pc + 4,
        number: registers[16], arguments: arguments)
    }
  }

  public func removeProcess(_ process: Process) {
    enrollments.withLock { _ = $0.removeValue(forKey: process) }
  }
}
