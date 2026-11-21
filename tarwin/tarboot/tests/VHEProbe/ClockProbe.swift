import TarwinTime
#if !CLOCK_READER
  import TarwinArchAarch64
#endif

@_extern(c, "tarwin_clock_ticks")
private func ticks() -> UInt64

#if CLOCK_READER
  // Linked separately into a single user RX page: no privileged text or
  // writable kernel state is reachable from this code.
  @_cdecl("tarwin_test_clock_read")
  public func readPage(_ phase: UInt32) -> UInt32 {
    let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(bitPattern: UInt(TimePageReader.address47)), count: 16384)
    guard let reader = TimePageReader(page: bytes),
      let first = reader.read(counter: ticks), let last = reader.read(counter: ticks),
      last.monotonic > 0, first.monotonic <= last.monotonic,
      last.boot == last.monotonic + 43_200_000_000_000
    else { return 0 }
    if phase == 2 { return last.utc == last.boot + 2_000_000_000 ? 2 : 0 }
    guard phase == 1 else { return 0 }
    // Compare against an independent ideal linear insertion, allowing one
    // nanosecond for the kernel's integral credit grid. The virtual fixture
    // explicitly advances the Boot clock by half a day; no real sleep.
    let ideal = last.boot + 1_000_000_000 - last.boot / 86_400
    return last.utc == ideal || last.utc == ideal + 1 ? 1 : 0
  }
#else
  @_extern(c, "tarwin_clock_hz")
  private func hz() -> UInt64

  private struct Execution: ~Copyable {
    var process: ProcessCPUTime
    var thread: ThreadCPUTime
    var run: CPUTimeRun?
    var lastNS: UInt64 = 0
    var lastStop: UInt64 = 0
  }

  // Disjoint areas in the diagnostic's private 16 KiB host context.
  private func execution(_ context: UInt64) -> UnsafeMutablePointer<Execution> {
    UnsafeMutablePointer(bitPattern: UInt(context + 12288))!
  }

  @_cdecl("tarwin_test_cpu_begin")
  public func beginCPUTime(_ context: UInt64, _ iteration: UInt64) -> UInt32 {
    let p = execution(context)
    if iteration == 0 {
      let lane = UnsafeMutablePointer<CPUTimeLane>(bitPattern: UInt(context + 14336))!
      lane.initialize(to: CPUTimeLane())
      guard let clock = ProcessCPUTime(id: 91, frequency: hz(), lanes: .init(start: lane, count: 1)),
        let thread = ThreadCPUTime(id: 23, process: 91) else { return 0 }
      p.initialize(to: Execution(process: consume clock, thread: consume thread))
    }
    let now = ticks()
    guard p.pointee.run == nil, now > p.pointee.lastStop,
      p.pointee.process.threadNanoseconds(p.pointee.thread, sample: { _ in nil }) == p.pointee.lastNS,
      p.pointee.process.processNanoseconds(sample: { _ in nil }) == p.pointee.lastNS
    else { return 0 }
    p.pointee.run = p.pointee.process.begin(&p.pointee.thread, on: 0, counter: now)
    return p.pointee.run == nil ? 0 : 1
  }

  @_cdecl("tarwin_test_cpu_end")
  public func endCPUTime(_ context: UInt64) -> UInt32 {
    let now = ticks(), p = execution(context)
    guard let run = p.pointee.run,
      let live = p.pointee.process.threadNanoseconds(p.pointee.thread, sample: { _ in now }),
      live > p.pointee.lastNS, p.pointee.process.processNanoseconds(sample: { _ in now }) == live,
      p.pointee.process.end(run, thread: &p.pointee.thread, counter: now),
      p.pointee.process.processNanoseconds(sample: { _ in nil }) == live else { return 0 }
    p.pointee.lastNS = live
    p.pointee.lastStop = now
    p.pointee.run = nil
    return 1
  }

  @_cdecl("tarwin_publish_shared_clock")
  public func publishClock(_ context: UInt64) -> UInt32 {
    let storage = UnsafeMutablePointer<W1ClockReservation>(bitPattern: UInt(context + 4096))!
    let roots = UnsafePointer<ProbeRoots>(bitPattern: UInt(context + 128))!
    let start = ticks()
    guard let clock = SystemClocks(frequency: hz(), counter: start, utc: 1_000_000_000),
      var page = storage.move().start(in: roots.pointee.host, clock: clock),
      page.update(.leap(.insertion, startingAtBoot: 0), counter: start),
      page.update(.suspend, counter: start),
      page.update(.resume(sleptNS: 43_200_000_000_000), counter: ticks()) else { return 0 }
    UnsafeMutablePointer<W1ClockPage>(bitPattern: UInt(context + 8192))!.initialize(to: consume page)
    return 1
  }

  @_cdecl("tarwin_test_update_clock")
  public func updateClock(_ context: UInt64) -> UInt32 {
    let page = UnsafeMutablePointer<W1ClockPage>(bitPattern: UInt(context + 8192))!
    let t = ticks()
    guard let now = page.pointee.snapshot?.read(counter: t), now.boot <= .max - 2_000_000_000
    else { return 0 }
    // Test-only administrative step, not an SVC exposed to the child.
    return page.pointee.update(.stepUTC(now.boot + 2_000_000_000), counter: t) ? 1 : 0
  }
#endif
