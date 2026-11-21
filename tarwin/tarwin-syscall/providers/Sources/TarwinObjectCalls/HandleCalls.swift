import TarwinABI
import TarwinObject
import TarwinSyscall

public protocol HandleRetirement {
  /// Enqueue final destruction; do not free storage until its epoch drains.
  mutating func retire(_ header: UnsafePointer<ObjectHeader>)
  /// Arrange cancellation for this removed name, even when duplicates exist.
  mutating func invalidate(_ name: UInt64)
}

public protocol HandleCallContext {
  associatedtype Retirement: HandleRetirement
  var userRange: Range<UInt64> { get }
  /// Must resolve user faults and enforce user permissions. No table lock is held.
  mutating func readWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool
  mutating func writeWords(to: UInt64, from: UnsafeBufferPointer<UInt64>) -> Bool
  mutating func withWriter<R>(_ body: (inout HandleTable, inout Retirement) -> R) -> R
  /// Hold the current process table's read epoch across body.
  mutating func withRead<R>(_ body: (HandleReadView, inout Retirement) -> R) -> R
}

public struct HandleCalls<C: HandleCallContext>: CallProvider {
  public var context: C
  public init(context: C) { self.context = context }
  public func argumentCount(for n: UInt64) -> UInt32? {
    switch n {
    case TarwinCall.handleClose: return 1
    case TarwinCall.handleCloseMany, TarwinCall.handleDuplicate, TarwinCall.handleReplace,
      TarwinCall.handleInfo:
      return 2
    default: return nil
    }
  }
  public mutating func copyUserWords(
    from address: UInt64, into dest: UnsafeMutableBufferPointer<UInt64>
  ) -> Bool {
    return context.readWords(from: address, into: dest)
  }
  private static func error(_ code: UInt32) -> CallResult {
    CallResult(status: syscallStatus(code, 1))
  }

  private mutating func close(_ name: UInt64) -> Bool {
    context.withWriter { table, lifecycle in
      guard table.close(name, retire: { lifecycle.retire($0) }) else { return false }
      lifecycle.invalidate(name)
      return true
    }
  }

  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard let count = argumentCount(for: number) else { return Self.error(10) }
    guard words.count == Int(count) else { return Self.error(1) }
    let name = words[0]
    switch number {
    case TarwinCall.handleClose:
      return close(name) ? CallResult() : Self.error(2)
    case TarwinCall.handleCloseMany:
      let count = words[1]
      let r = context.userRange
      if count == 0 { return CallResult() }
      guard count <= UInt64(UInt32.max),
        syscallTailInRange(name, count * 8, r.lowerBound, r.upperBound)
      else { return Self.error(1) }
      var chunk: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (
        0, 0, 0, 0, 0, 0, 0, 0
      )
      return withUnsafeMutableBytes(of: &chunk) { raw in
        let storage = raw.bindMemory(to: UInt64.self)
        var done: UInt64 = 0
        var valid = true
        while done < count {
          let n = min(storage.count, Int(count - done))
          let batch = UnsafeMutableBufferPointer(rebasing: storage[..<n])
          guard context.readWords(from: name + done * 8, into: batch) else { return Self.error(1) }
          for value in batch { if !close(value) { valid = false } }
          done += UInt64(n)
        }
        return valid ? CallResult() : Self.error(2)
      }
    case TarwinCall.handleDuplicate, TarwinCall.handleReplace:
      return context.withWriter { table, lifecycle in
        let duplicate = number == TarwinCall.handleDuplicate
        switch table.derive(name, rights: words[1], duplicate: duplicate) {
        case .invalidHandle: return Self.error(2)
        case .accessDenied: return Self.error(4)
        case .limit: return Self.error(33)
        case .installed(let result):
          if !duplicate { lifecycle.invalidate(name) }
          return CallResult(first: result)
        }
      }
    default:
      let address = words[1]
      let r = context.userRange
      guard syscallTailInRange(address, 32, r.lowerBound, r.upperBound) else {
        return Self.error(1)
      }
      let info = context.withRead { view, lifecycle -> (UInt64, UInt64, UInt64, UInt64)? in
        guard case .found(let g) = view.pinWithinEpoch(name, kind: 0, need: 0) else { return nil }
        let result = (UInt64(g.header.pointee.kind), g.rights, g.header.pointee.koid, UInt64(0))
        g.drop { lifecycle.retire($0) }
        return result
      }
      guard var info else { return Self.error(2) }
      return withUnsafeBytes(of: &info) { bytes in
        context.writeWords(to: address, from: bytes.bindMemory(to: UInt64.self))
          ? CallResult() : Self.error(1)
      }
    }
  }
}
