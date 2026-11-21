// Caller drives a stopped vCPU and always retries at its original guest PC.
struct TestDirtyLog {
  let page: UInt64
  let log: DirtyPages
  var word: UInt64 = 0
  init(_ extent: GuestExtent, _ page: UInt64) {
    self.page = page
    log = DirtyPages(first: extent.start / page, pages: 1)
  }
  mutating func collect(
    _ ram: inout GuestExtent, expected: UInt64,
    detach: (UInt64, UInt64) -> Bool, invalidate: (UInt64, UInt64) -> Bool,
    install: (UInt64, UInt64, UInt64, UInt64) -> Bool
  ) -> Bool {
    return log.collectWord(
      0, { _ in word },
      { first, count in
        first == log.first && count == 1
          && ram.trapWrites(true, detach: detach, invalidate: invalidate, install: install)
      }, { _, v in word = v }, { _, v in v == expected }) && word == 0
  }
  mutating func retry(
    _ ram: inout GuestExtent, ipa: UInt64,
    detach: (UInt64, UInt64) -> Bool, invalidate: (UInt64, UInt64) -> Bool,
    install: (UInt64, UInt64, UInt64, UInt64) -> Bool
  ) -> Bool {
    word == 0
      && log.retryWrite(
        ipa: ipa, pageSize: page, extent: &ram, load: { _ in word },
        store: { _, v in word = v }, detach: detach, invalidate: invalidate, install: install)
      && word == 1
  }
}
