import LibTesseraTarwin
import Synchronization
import TarwinABI
import TarwinIPC

private func failure(_ code: UInt64) -> CallResult { CallResult(status: code | 1 << 32) }

/// Attach once to a new, kernel-authorized port mapping. All duplicated Wait
/// handles and threads share this reader's cursor; do not attach per name.
public struct NativePortRing: ~Copyable {
  public let koid: UInt64
  private var reader: RingEndpoint

  public init?(koid: UInt64, fresh words: UnsafeBufferPointer<Atomic<UInt32>>) {
    guard koid != 0, let reader = RingEndpoint(fresh: words, completion: true, producer: false),
      reader.isPortCompletionReader
    else { return nil }
    self.koid = koid
    self.reader = reader
  }

  fileprivate mutating func poll(into out: UnsafeMutableBufferPointer<UInt64>, signal: () -> Void)
    -> CallResult?
  {
    var count = 0
    var notify = false
    var record = RingRecord()
    defer { if notify { signal() } }
    while count < out.count / 8 {
      switch reader.pop(into: &record) {
      case .transferred(let wake):
        for i in 0..<8 {
          out[count * 8 + i] = UInt64(record.words[2 * i]) | UInt64(record.words[2 * i + 1]) << 32
        }
        count += 1
        notify = notify || wake
      case .wait: return count == 0 ? nil : CallResult(first: UInt64(count))
      case .exhausted: return count == 0 ? failure(33) : CallResult(first: UInt64(count))
      case .invalidPeer, .wrongSide:
        return count == 0 ? failure(23) : CallResult(first: UInt64(count))
      }
    }
    return CallResult(first: UInt64(count))
  }
}

public protocol NativePortRingDirectory {
  /// Resolve the exact name with Wait rights. Pass the authorized port KOID,
  /// its pinned reader and latched producer Event signal. Serialize cursor
  /// access across threads; the signal callback must not re-enter the directory.
  /// Release the lock and borrow before sleeping. Return nil only when the
  /// body found an empty ring; directory errors must not trigger a sleep.
  mutating func withReader(
    named: UInt64,
    _ body: (
      UInt64, inout NativePortRing, () -> Void
    ) -> CallResult?
  ) -> CallResult?
}

extension NativePorts {
  /// Ring-backed Port.wait. Output is private writable storage, disjoint from
  /// the pinned mapping, in eight-word Completion records. The slow path uses
  /// the same absolute deadline across spurious wakes and competing readers.
  public static func wait<D: NativePortRingDirectory, G: NativeGate>(
    _ name: UInt64, into output: UnsafeMutableBufferPointer<UInt64>, deadline: UInt64,
    directory: inout D, gate: inout G
  ) -> CallResult {
    guard !output.isEmpty, output.count % 8 == 0, output.count / 8 <= Int(UInt32.max)
    else { return failure(1) }
    while true {
      let poll = directory.withReader(named: name) { id, reader, signal in
        guard reader.koid == id else { return failure(2) }
        return reader.poll(into: output, signal: signal)
      }
      if let poll { return poll }
      guard deadline != 0 else { return failure(25) }
      // Private Port.enter(port, absoluteDeadline): pump submissions and
      // recheck completion availability under the kernel's waiter lock.
      let enter = gate.enter(number: TarwinCall.portEnter, registers: CallRegisters(name, deadline))
      if enter.status != 0 { return enter }
    }
  }
}
