# tarwin-power

Power dependency ordering and rollback, wake locks, wake filters, thermal bands and energy accounting. No physical suspend/resume endurance result.

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.
