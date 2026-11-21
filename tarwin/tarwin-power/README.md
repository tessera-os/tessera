# tarwin-power

Power dependency ordering and rollback, wake locks, wake filters, thermal bands and energy accounting. No physical suspend/resume endurance result.

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.

ClusterGovernor programs a board-supplied frequency ceiling before admitting dispatches. Share one serialized governor per cluster. Its fixed-window CPU-ns reservations are pooled across CPUs and classes, survive changes of thermal band, and stop at the window boundary. The worst firmware/sensor zone wins, including the handheld skin sensor on a dock. Missing or stale samples select the critical ceiling; a failed actuator denies new dispatch slices. The platform must enforce the ceiling on already running CPUs, preempt at the admitted slice boundary, and supply certified OPPs and budget parameters.

The single-writer PowerPageWriter publishes the existing LibTessera §18.1 64-byte PowerInfo record and the 64-bit refresh sequence at offset 64 of a fresh, pinned 4096-byte page. Give clients read-only mappings only after the first sample. Publication precedes notification; readers retry at most eight times and never accept an interrupted refresh. Native scheduler dispatch, sensor/actuator hardware, read-only mapping grants and physical 10,000-cycle endurance are not demonstrated by the package tests.
