# tarwin-net

IPv4/IPv6 UDP validation and output, registered receive constraints and fair-queue pacing. This is not a full TCP stack or NIC driver.

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.

The interface transmit queue retains registered memory pins across driver restarts. It publishes only paced FIFO heads, lets foreground traffic bypass background traffic on congested links, and rejects completions from the previous driver epoch. Pending packets survive restart; already-published packets complete as lost only after the old DMA domain drains. The driver must retire its device mappings before releasing packet pins.

Each NIC hardware queue gets a fresh A.4 ring pair (64-byte records) per driver epoch. The producer publishes only a bounded frame IOVA and length, never a process's memory handle or kernel pin token. TX completions must match the publication's epoch, queue, ID and byte count; release waits for the mapping to retire. RX carries exclusive writable grants. Completion lengths cannot exceed the posted capacity, and the stack cannot consume bytes until DMA retirement/cache synchronization succeeds. Restart disables both directions; writable buffers are reclaimed only after the old domain drains. Pending TX retains its pins; a published TX frame is never replayed by the interface.

The Mac-hosted BlockQTest connects this interface/driver path to two QEMU NICs and delivers a checksummed IPv4 UDP datagram to a preposted endpoint receive on an isolated virtual link. Host callbacks supply pin/grant lookup; the test is neither a physical NIC run nor a guest network stack boot.
