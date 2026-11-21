# tarwin-net

IPv4/IPv6 UDP validation and output, registered receive constraints and fair-queue pacing. This is not a full TCP stack or NIC driver.

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.

The interface transmit queue retains registered memory pins across driver restarts. It publishes only paced FIFO heads, lets foreground traffic bypass background traffic on congested links, and rejects completions from the previous driver epoch. Pending packets survive restart; already-published packets complete as lost only after the old DMA domain drains. The driver must retire its device mappings before releasing packet pins.
