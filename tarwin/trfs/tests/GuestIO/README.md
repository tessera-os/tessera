# Debug guest storage check

`exerciseGuestStorage` mounts the repository's plaintext fixture by its pinned
metadata hash, looks up `system-version`, authenticates its page, and checks
every byte. The pin is compiled into the guest. It is not read from the disk.
This is a read-only test pin, not a signature, TPM measurement or external
TRFS reference.

Supply 16 KiB of page-aligned private memory, exclusive for the call. The
synchronous exchange receives only the first 8 KiB. It must not retain that
grant, use guest pointers as host addresses or access other guest memory.
All offsets below are relative to the grant and integers are little endian.

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 128 | TarwinBlockWire request (guest to backend) |
| 128 | 128 | TarwinBlockWire completion (backend to guest) |
| 256 | 16 | One vector: offset 4096 (u64), length 4096 (u32), zero (u32) |
| 4096 | 4096 | Read payload (backend to guest) |

The fixture contains 256 pages. Each request reads eight 512-byte sectors
from an aligned LBA, on queue 0 and epoch 1; IDs increase from 1. The backend
must validate the request and vector and bound the read before copying, then
return exactly one terminal completion. Transport failure, wrong or failed
completion, corrupt metadata or data, or an unexpected file fails the check.
The TRFS scratch and destination lie outside the grant.

On macOS run `SWIFTC=/path/to/embedded/swiftc bash ./check.sh`. It uses the system
Swift compiler for host tests (override with `HOST_SWIFTC`) and the Embedded
compiler for three allocation-disabled code builds. It does not itself boot
QEMU. The virtualization debug-guest profile supplies the mailbox backend;
a successful run with an in-memory image is not a controller/DMA test or
signed kernel launch.
