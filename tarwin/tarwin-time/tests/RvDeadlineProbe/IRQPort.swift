#if AIA_RTC
  import TarwinDevice
  import TarwinIPC
  import TarwinIoCompletion

  // Single-hart kernel diagnostic. Interrupts are masked during port operations;
  // only the wait veneer enables them. There is no userspace port or driver here.
  private struct DiagnosticPorts: ~Copyable, IoPorts {
    var port: CompletionPort, refs = 0, notifications = 0
    mutating func retainPort(_ id: UInt64) -> Bool {
      guard id == 19 else { return false }
      refs += 1
      return true
    }
    mutating func releasePort(_ id: UInt64) { precondition(id == 19 && refs > 0); refs -= 1 }
    mutating func withLockedPort(_ id: UInt64, _ visit: (inout CompletionPort) -> Void) {
      precondition(id == 19)
      visit(&port)
    }
    mutating func wakePort(_ id: UInt64, count: Int) { precondition(id == 19); notifications += count }
  }

  func checkIRQPort(
    vector: UInt32, mask: () -> Void, unmask: () -> Void, masked: () -> Bool,
    raise: () -> Void, lower: () -> Void, pendingWhileMasked: () -> Bool,
    wait: () -> Bool, now: () -> UInt64?
  ) -> Bool {
    var slot = PortSlot()
    return withUnsafeMutablePointer(to: &slot) {
      guard let port = CompletionPort(storage: .init(start: $0, count: 1)) else { return false }
      var ports = DiagnosticPorts(port: consume port)
      var irq = PortInterrupt(object: 33, epoch: 2, vector: vector)
      guard masked(), irq.arm(epoch: 2, port: 19, key: 100, ports: &ports, unmask: unmask),
        !masked(), ports.refs == 1 else { return false }
      raise()
      guard wait(), let first = now(), irq.interrupt(at: first, ports: &ports, acknowledgeAndMask: mask),
        masked(), ports.refs == 0 else { return false }
      lower()
      raise()
      guard pendingWhileMasked(),
        !irq.arm(epoch: 2, port: 19, key: 101, ports: &ports, unmask: unmask), masked(),
        ports.refs == 0, let packet = ports.port.take(), packet.kind == 11,
        packet.key == 100, packet.result0 == UInt64(vector), packet.error == 0,
        packet.timestamp == first, !irq.arm(epoch: 1, port: 19, key: 101, ports: &ports, unmask: unmask),
        pendingWhileMasked(), irq.arm(epoch: 2, port: 19, key: 101, ports: &ports, unmask: unmask),
        wait(), let second = now(), second >= first,
        irq.interrupt(at: second, ports: &ports, acknowledgeAndMask: mask), masked(),
        let next = ports.port.take(), next.kind == 11, next.key == 101, next.result0 == UInt64(vector),
        next.error == 0, next.timestamp == second, ports.port.take() == nil,
        ports.refs == 0, ports.notifications == 2 else { return false }
      lower()
      return true
    }
  }
#endif
