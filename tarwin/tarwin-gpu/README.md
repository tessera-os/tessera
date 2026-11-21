# tarwin-gpu

GPU memory charging, timeline fence donation and doorbell grants. No Ember, display-server or hardware integration is implied.

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.

Fence waiters use preallocated, caller-owned storage. The profile check also compiles signal, cancellation and priority donation with `-no-allocations` for each target.
