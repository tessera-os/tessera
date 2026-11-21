# trfs

Scoped lookup, encrypted-page staging and A.5 filesystem service records. No on-disk format, crash recovery or encryption implementation is substituted for the missing canonical TRFS specification.

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.
