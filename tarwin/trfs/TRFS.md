# TRFS 1 — Tarwin snapshot volume

This is a new native format, not an interpretation of btrfs, FAT or an earlier
TRFS format. It fixes the storage contract for Tarwin §§6.4–6.5, 13.3, 20.3–5,
24.3, 25.7 and 29. The first implementation favors a small, auditable recovery
algorithm over metadata throughput. Numeric fields are unsigned little-endian;
unassigned fields are zero. No native structs are serialized.

## Storage, keys and trust

The kernel addresses 4096-byte logical sectors in one partition. All offsets
below are bytes within a sector. Hash means SHA-256 of the exact plaintext
bytes; byte strings, including hashes, retain byte order. A reference is an
8-byte partition-relative sector index followed by the 32-byte hash. The empty
reference is forty zeros. Every nonempty record or data reference points strictly
backward (sector ≥2); no circular chains. Reject unexpected versions, out of
bounds or forward references and malformed records. A failed authenticated
read cannot supply even a prefix of a user page.

The volume is above the **trusted** storage transform. For encrypted volumes
the security service derives a distinct, nonexportable AES-256-XTS key pair per
volume and key epoch; the XTS data unit is one 4096-byte sector and its tweak
input is the 128-bit little-endian partition-relative sector index. Encrypt
anchors, metadata and file data. Bind geometry, key epoch and partition to the
mount from trusted configuration. Use the existing kernel ciphertext staging
path or controller inline encryption with hardware-wrapped keys. Never stage
plaintext in driver-owned DMA, disclose raw keys, or fall back to unencrypted I/O.
Read, write and flush completion must include terminal DMA retirement. XTS and
an unkeyed anchor hash do not authenticate a writable disk against an attacker.

For a system image, authenticate the nonempty selected root digest against the
signed boot set, measure it into PCR 11 before mount and expose a read-only
snapshot. Verify each traversed child before using it. Do not accept a different
root to recover from verification failure. Boot policy (including switching
A/B slots, rollback counters and measurement) belongs to tarboot. The root is
the hash of a complete metadata record, including its predecessor and data
references, not the hash of an anchor. An untrusted generation number cannot
authorize an image.

The kernel's system mount supplies the digest from that verified boot set and
a measurement provider. It authenticates the selected head before calling
the provider; it exposes no snapshot until both the PCR extension and log
record succeed. An uncertain extension consumes that mount attempt: do not
retry it or fall back to an ordinary mount on the same volume instance.

The opt-in system-root boot profile passes exactly 32 raw bytes from the
verified immutable boot-set object to `mountSystem(bootSetRoot:measure:)`.
There is no sector number, hex encoding, terminator or second hash. Wrong
length, zero, stale and mismatching roots cannot authorize measurement or
mount. Never reopen a root file by name at kernel mount; the independently
generated test fixture is not a source of boot authority.

## Publication

Sectors 0 and 1 alternate by generation parity. In an anchor the magic at 0
is bytes `54 52 46 53 00 00 01 00`; u64 generation at 8, first unused sector
at 16, volume size in sectors at 24, head reference at 32, zeros at 72…4063,
hash of bytes 0…4063 at 4064. A formatter accepts only two readable all-zero
anchors. Generation 1 (slot 1) starts with empty head, tail 2; directory 1 is
implicit. Never wrap generation or allocate past the partition.

1. Append data and metadata, never overwriting objects in a committed snapshot.
2. Flush all appended sectors to stable storage.
3. Write the complete other anchor, flush it, then acknowledge the operation.
   A failed or uncertain publication fences the writer until remount.

Mount reads **both** anchors. An I/O failure is not a zero or torn anchor.
Ignore blank anchors and checksum-invalid torn anchors; a checksum-valid
unsupported or malformed anchor fails the mount. Select the highest valid
generation, verify its head, then demand-verify older records and data. A
pre-publication crash can leak only unreachable sectors; a post-publication
crash cannot expose partial state if the device honors flush. No reliance on
4 KiB write atomicity. If neither anchor is valid do not autoformat.
The mount owner serializes reads, transactions and access to the scratch page.

## Records and namespace

A metadata record is one sector:

| Offset | Type | Meaning |
|---:|---|---|
|0|8 bytes|`54 52 46 4e 00 00 01 00`|
|8, 16, 24|u64 each|object, key, value|
|32, 72|40 bytes each|previous metadata, data blob|
|112, 113, 114|u8 each|tag, subtype, name length|
|115…127|zero|reserved|
|128…4095|bytes|name followed by zeros|

The newest matching record in the selected head chain wins. Walking the chain
uses a fixed scratch page and no recursion. Object 0 is invalid. File and
directory IDs are the allocation index of their creation inode and not
capabilities. Directory 1 is the root; clients cannot supply arbitrary IDs.

| Tag | Record |
|---:|---|
|1|Directory entry keyed by (parent object, name); value = child inode ID or 0 (unlink); key, subtype and blob zero. Names are 1…255 bytes; disallow slash, bytes <32, `.` and `..`. Compare exact bytes.|
|2|Inode keyed by object; subtype 1 = regular file, 2 = directory, 3 = symbolic link. Value = byte length (0 for directories); key and name zero. Only links have a required blob reference: one authenticated target sector.|
|3|File page keyed by (file object, logical page index); required blob reference to exactly 4096 bytes; subtype, value and name zero.|
|4|Truncate barrier: object = file, key = first removed whole page (ceiling of new length / 4096); value, blob, subtype and name zero. While walking backwards for this file, an older mapping at or above this key is a hole, not data.|

Growing publishes only the new length. Shrinking needs Write authority and
excludes VM mappings of the removed byte range until commit. If the last
surviving page is partial and allocated, authenticate it, zero its suffix,
and store a new copy. Publish that mapping, the barrier and the new length in
one transaction. This does not scan sparse address space or change old roots.
Readers that do not understand tag 4 must reject it rather than skip it.

Unwritten file pages read as zeros. Bytes beyond EOF in the last page are
zero and never disclosed. No unwritten inline tails. Whole-page writes or an
EOF fragment atomically publish blob, mapping and length. Creation publishes
inode and directory entry together. Moving a file or link publishes source
whiteout and destination entry together: no-replace requires an absent
destination, replace accepts an absent destination or another file/link.
Exchange requires two existing file/link names and swaps their inode IDs
under one anchor. Neither operation moves or truncates the underlying data.
The namespace layer enforces source Delete and destination Create, plus
Delete on displaced entries. Unlink removes a name, not an already-open inode.
Namespace service resolution starts at an authorized
Node, never at a process-global root. The caller checks rights, mount identity
and object generation before lookup, write or enumeration. Never treat an I/O
or integrity failure as absence to authorize a create.

A symbolic link holds 1…4096 bytes of relative path followed by zero padding
in its target sector. Components have 1…255 bytes, no control bytes below 32,
and may be `.` or `..`. Reject absolute paths, empty components and invalid
padding. Publish target, inode and name in one anchor transaction. Renaming
and unlinking act on the link, never its target. Read links from the same
immutable snapshot throughout lookup; start each expansion in the containing
directory, never walk above the original Node, bound the expanded path to
4096 bytes and follow at most 40 links. Corruption is not a missing target.

## Snapshots, clone and pager

A snapshot is an immutable head reference scoped to the volume. Holding it
pins every referenced older block. Forking the writable head from a retained
snapshot publishes its head in a **new** anchor, keeping the current high-water
mark. Old readers continue to see their original contents. Slot-specific boot
sets retain their root digests; disk images and updates can branch by reference.
V1 does not recycle committed sectors; at capacity return an error, not a
destructive overwrite. Reclamation, indexed lookups and compaction are future
compatible optimizations only if all retained roots remain readable.

VM mapping uses the kernel's existing shared file pager, keyed by snapshot
file object and byte offset. A 4 or 16 KiB mapping is filled from one or four
authenticated sectors before publish; a partially read frame is scrubbed, never
installed. A measured snapshot refuses writes. Writeback on a mutable object
must commit before clearing dirty state. Mutable mappings bind to a mount
incarnation and anchor generation, not merely a digest: republishing an old
snapshot or reopening after a failed flush does not revive an old writer.
Other filesystems use the A.5 server ring, not this disk format.

## Acceptance boundary

Tests must include malformed geometry and refs, a pinned system hash, page
corruption, sparse EOF, isolation of old roots after a branch and power loss
on either side of both flushes. Recovery is a storage-protocol result, not a
claim about real media, a booted kernel, controller keyslots,
concurrent multiwriter operation or §34 performance. The q35 storage test
extends the verified head into a software TPM's SHA-256 PCR 11, checks the
event and independently replays its digest. Its two modes take either a raw
fixture pin or the verified head of a signed host-test boot set. Neither
executes the signed kernel or establishes production key provisioning.
