import TarwinTime
import Testing

@Test func simultaneousRunsMigrationAndExitKeepExactProcessTime() {
  var lanes = [CPUTimeLane](repeating: CPUTimeLane(), count: 2)
  lanes.withUnsafeMutableBufferPointer {
    guard var p = ProcessCPUTime(id: 99, frequency: 3, lanes: $0),
      var a = ThreadCPUTime(id: 10, process: 99), var b = ThreadCPUTime(id: 11, process: 99),
      var other = ThreadCPUTime(id: 10, process: 100),
      let runA = p.begin(&a, on: 1, counter: 100), let runB = p.begin(&b, on: 0, counter: 2)
    else { Issue.record(); return }
    #expect(p.begin(&a, on: 0, counter: 2) == nil)
    #expect(p.begin(&other, on: 1, counter: 101) == nil)
    #expect(p.processNanoseconds(sample: { $0 == 1 ? 101 : 4 }) == 1_000_000_000)
    #expect(p.processNanoseconds(sample: { $0 == 1 ? nil : 4 }) == nil)
    #expect(p.threadNanoseconds(a, sample: { _ in 99 }) == nil)
    #expect(p.threadNanoseconds(b, sample: { _ in 4 }) == 666_666_666)
    #expect(p.end(runA, thread: &a, counter: 99) == false)
    #expect(p.end(runA, thread: &b, counter: 102) == false)
    #expect(p.end(runB, thread: &b, counter: 4) == true)
    #expect(p.end(runA, thread: &a, counter: 101) == true)
    #expect(p.processNanoseconds(sample: { _ in Issue.record(); return nil }) == 1_000_000_000)
    #expect(p.begin(&a, on: 0, counter: 3) == nil)
    guard let migrated = p.begin(&a, on: 0, counter: 5) else { Issue.record(); return }
    #expect(p.end(runA, thread: &a, counter: 102) == false)
    #expect(p.end(migrated, thread: &a, counter: 7) == true)
    guard let resumed = p.begin(&a, on: 0, counter: 9) else { Issue.record(); return }
    #expect(p.end(migrated, thread: &a, counter: 10) == false)
    #expect(p.end(resumed, thread: &a, counter: 9) == true)
    #expect(p.threadNanoseconds(a, sample: { _ in nil }) == 1_000_000_000)
    #expect(p.processNanoseconds(sample: { _ in nil }) == 1_666_666_666)
  }
}

@Test func refusesUnrepresentableCPUTimeWithoutWrapping() {
  var lanes = [CPUTimeLane](repeating: CPUTimeLane(), count: 2)
  lanes.withUnsafeMutableBufferPointer {
    guard var p = ProcessCPUTime(id: 1, frequency: 1_000_000_000, lanes: $0),
      var a = ThreadCPUTime(id: 1, process: 1), var b = ThreadCPUTime(id: 2, process: 1),
      let run = p.begin(&a, on: 0, counter: 0), p.end(run, thread: &a, counter: .max),
      let next = p.begin(&a, on: 1, counter: 1) else { Issue.record(); return }
    #expect(p.threadNanoseconds(a, sample: { _ in 2 }) == nil)
    #expect(p.processNanoseconds(sample: { _ in 2 }) == nil)
    #expect(p.end(next, thread: &a, counter: 2) == false)
    #expect(p.begin(&b, on: 1, counter: 2) == nil)
  }
}
