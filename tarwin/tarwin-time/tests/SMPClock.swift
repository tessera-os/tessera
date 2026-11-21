import Synchronization
import TarwinTime

@_extern(c, "smp_probe_ticks") private func ticks() -> UInt64
@_extern(c, "smp_probe_mailbox") private func mailbox() -> UnsafeMutableRawPointer
@_extern(c, "smp_probe_secondary_entry") private func secondaryEntry() -> UInt64
@_extern(c, "smp_probe_fail") private func halt()
private func stopGuest() -> Never { halt(); while true {} }

#if arch(arm64)
@_extern(c, "tarwin_clock_hz") private func localFrequency() -> UInt64
private let pageSize = 16384
#else
private let pageSize = 4096
#endif

private enum Word: Int {
  case request, reply, hart, tick, monotonic, boot, utc, ready, frequency
}

private struct Exchange {
  var words: UnsafeMutablePointer<Atomic<UInt64>>
  func get(_ w: Word) -> UInt64 { words[w.rawValue].load(ordering: .acquiring) }
  func set(_ w: Word, _ value: UInt64) { words[w.rawValue].store(value, ordering: .releasing) }
}

// Interrupts off, separate stack. Firmware passed the boot cluster's mailbox
// as opaque, not an address selected by the secondary or by a process.
@_cdecl("smp_probe_secondary")
public func secondary(_ hart: UInt64, _ base: UnsafeMutableRawPointer) {
  guard base == mailbox() else { stopGuest() }
  let x = Exchange(words: base.assumingMemoryBound(to: Atomic<UInt64>.self))
  x.set(.hart, hart)
  #if arch(arm64)
  x.set(.frequency, localFrequency())
  #endif
  x.set(.ready, 1)
  for i in 1...3 {
    while x.get(.request) != UInt64(i) {}
    if i == 3 {
      let page = UnsafeRawBufferPointer(start: base + pageSize, count: pageSize)
      guard let reader = TimePageReader(page: page), let time = reader.read(counter: ticks),
        let utc = time.utc else { stopGuest() }
      x.set(.monotonic, time.monotonic)
      x.set(.boot, time.boot)
      x.set(.utc, utc)
    } else {
      x.set(.tick, ticks())
    }
    x.set(.reply, UInt64(i))
  }
}

func checkTwoCPUs(
  boot: UInt64, peer: UInt64, rate: BootCounterRate, stopped: (UInt64) -> Bool,
  start: (UInt64, UInt64, UInt64, UInt64) -> Bool
) -> Bool {
  let base = mailbox()
  let count = Word.frequency.rawValue + 1
  let words = base.bindMemory(to: Atomic<UInt64>.self, capacity: count)
  for i in 0..<count { (words + i).initialize(to: Atomic(0)) }
  let x = Exchange(words: words)
  let entry = secondaryEntry(), opaque = UInt64(UInt(bitPattern: base))
  guard start(peer, boot, entry, opaque) else { return false }
  // On timeout halt the entire diagnostic guest, never retire storage while
  // the other hart might still be reading it.
  func awaitWord(_ w: Word, _ value: UInt64) {
    let t = ticks()
    while x.get(w) != value {
      let now = ticks()
      if now < t || now - t > rate.frequency { stopGuest() }
    }
  }
  awaitWord(.ready, 1)
  #if arch(arm64)
  guard x.get(.frequency) == rate.frequency else { return false }
  #endif
  guard x.get(.hart) == peer, !stopped(peer), !start(peer, boot, entry, opaque) else { return false }
  func sample(_ i: UInt64) -> CounterRendezvous? {
    let before = ticks()
    x.set(.request, i)
    awaitWord(.reply, i)
    let remote = x.get(.tick), after = ticks()
    return CounterRendezvous(before: before, peer: remote, after: after, maximumSpan: rate.frequency / 100)
  }
  guard let first = sample(1) else { return false }
  while true {
    let t = ticks()
    guard t >= first.after else { return false }
    if t - first.after >= rate.frequency / 100 { break }
  }
  guard let next = sample(2), next.follows(first, minimumTicks: rate.frequency / 100),
    let clock = SystemClocks(frequency: rate.frequency, counter: first.before, utc: 9_000),
    let writer = TimePageWriter(freshPage: .init(start: base + pageSize, count: pageSize)),
    writer.publish(clock), let earliest = clock.read(counter: ticks()) else { return false }
  x.set(.request, 3)
  awaitWord(.reply, 3)
  let mono = x.get(.monotonic)
  guard let latest = clock.read(counter: ticks()), earliest.monotonic <= mono, mono <= latest.monotonic,
    x.get(.boot) == mono, x.get(.utc) == mono + 9_000 else { return false }
  let ending = ticks()
  while !stopped(peer) {
    let t = ticks()
    guard t >= ending, t - ending <= rate.frequency else { return false }
  }
  words.deinitialize(count: count)
  return true
}
