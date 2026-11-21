# Tarwin native image v1 — proposed producer/consumer contract

The linker and loader use v1 for **unsigned interoperability**. Note 2 and the signature transcript still require signer and train agreement; this is not a signing policy or evidence of verified launch. Existing TVISA A.2 tables retain their encodings. No producer may emit a dummy signature, drop an unsupported relocation, or mark an unsigned artifact executable.

## Common encodings

Integers below are packed unsigned little-endian; there is no implicit alignment or trailing data. An RVA is a u64 virtual offset relative to the ET_DYN load bias (ELF p_vaddr space), never a file offset. A text field is u16 byte length then that many nonempty UTF-8 bytes with no NUL. A feature set is u16 count then that many feature-name texts, strictly ascending by raw UTF-8 bytes and unique, using the target's TVISA names. A version is three u8 values year/month/week per TIR §24.1. Reject unknown versions, invalid ranges and nonzero reserved bits. Check all arithmetic before converting file extents or allocating.

## PT_NOTE descriptors (owner eight bytes `Tessera\0`)

Use standard ELF note framing: 12-byte namesz/descsz/type, owner, descriptor, four-byte alignment; zero padding excluded from descsz. Exactly one each of 1–5 and 7; one 6 for a finalized image only. An unsigned **intermediate** may omit note 2; it is never eligible for launch.

For unsigned interchange omit note 2. Carry 3/4/5/7 as explicit image metadata; missing input fails linking. The PT_NOTE may reference non-loaded file bytes with p_vaddr=0. Place note 1 after the end of the last page-rounded PT_LOAD file range even before signing.

Each PT_LOAD starts on a target page boundary in the file and in memory; nonempty file ranges occur in segment order and never share a file page. ELF p_align congruence alone is insufficient. A zero-file-size BSS-only segment consumes no file pages.

| Type | Proposed descriptor bytes |
| --- | --- |
| 1 | 32 raw BLAKE3 bytes. No prefix. |
| 2 | ASCII `TSG1`, u32 chainBytes, chainBytes bytes of RFC 8785 JSON for the two cert chains (the `chain` object, not the package signature, of TIR §29.4), raw 64-byte Ed25519 signature then raw 3309-byte ML-DSA-65 signature. No embedded private keys. |
| 3 | RFC 8785 UTF-8 JSON array of distinct granted entitlement names sorted by raw bytes; `[]` grants none. A signed image's grants must not exceed what its policy authorizes. |
| 4 | Build train, TIR version, expiry train, in that order: 9 bytes. |
| 5 | Target name text, feature set, u8 svec mode (0 agnostic, 1 fixed), u8 vscale (0 if agnostic; otherwise the target's valid nonzero vscale per TVISA §15.2). |
| 6 | TVISA hash then finalizer build identifier: 32 raw bytes each. Take target, features and svec from 5, not a duplicate. |
| 7 | u8 profile (app/system/driver/kernel = 0/1/2/3), u8 image kind (executable/framework/plug-in/driver/kernel = 0/1/2/3/4); combinations per TVISA §6.6. |

### Digest and signing boundary (requires signer agreement)

The authorized signer finalizes the ELF layout, including the actual chain and final descriptor sizes, before hashing. For ID calculation, hash the whole file in file order, substituting 32 zeros for note 1's descriptor and omitting **only** the two raw signature byte ranges in note 2. Thus the chain, header offsets, lengths, padding and every other byte are covered. No GNU/TIR secondary ID is patched on the Tarwin path. The hash before the signer adds the envelope is not the signed artifact's ID.

Place notes 1 and 2 after the end of **all** PT_LOAD file ranges rounded up to the target page size, in non-loaded file pages. Then canonical offsets and bytes of all executable pages are identical to the file's; proof tree length is final file length minus 3373 bytes. No change to an executable page can hide in an omitted or substituted range. BSS/padding needs separate segment handling; do not map adjacent file contents as executable padding.

The hybrid transcript is ASCII `Tarwin native image v1`, one NUL, raw build ID, then for each note in order **4, 5, 3**: u32 descriptor byte length and exact descriptor bytes. Sign those bytes (not a package/delivery digest). Both proofs must verify with the authorized identity; local trust anchors, revocation, purpose, expiry and installation policy still apply. Release signing belongs to the pipeline, development signing to the developer identity, finalization to the device signing service. A different hardware envelope needs an agreed version, not a single-signature fallback.

## .tirload directory

Unique ELF SHT_PROGBITS section found by section name; flags zero or SHF_ALLOC (read-only). Not in writable/executable segments, PT_NOTE, section names or ELF headers. Ordinary ELF64 section numbering; no new PT_NOTE or vendor program header. File extent alone is not permission to apply a record.

Header: ASCII `TLD1`, u16 version=1, u16 tableCount=8, u32 totalBytes, u32 reserved=0. Next eight entries, each `u32 start, u32 byteLength, u32 recordCount, u32 reserved=0`. Starts are section-relative, first start=144; payloads are tightly consecutive in the specified order; last end=totalBytes=sh_size. Empty tables have zero count and zero length (except the GPU scalar). All table counts must consume their ranges exactly; reject overlaps, gaps, arithmetic overflow or trailing bytes.

| Table, in order | One record |
| --- | --- |
| Relative | u64 ELF RELR word; count is encoded word count, not decoded slot count. Even words are RVAs, odd words are bitmaps of the next 63 slots. |
| Authenticated relative | u64 slot RVA, u32 nonzero TVISA type tag. The original slot word is the target RVA, not a signed pointer. |
| Imports | u64 slot RVA, u8 symbol kind (0 function / 1 data), u8 module kind (0 RIDL / 1 package framework), 16 raw ABI UUID bytes in TVISA byte order, u32 type tag (nonzero function / zero data), module text, symbol text. No platform weak imports. Enforce TVISA UUID rules and RIDL link checks. |
| Runtime entries | u64 slot RVA, u16 runtime identifier per TVISA §26 RUNTIME. Resolve only known entries and validate the target's runtime ABI/tag. |
| Dispatch | u64 slot RVA, u32 nonzero type tag, u16 nonzero candidate count; per candidate u64 entry RVA and feature set, in preference order. Each target must be a valid local function entry of that type, not an arbitrary executable address. |
| TLS offsets | u64 slot RVA, u64 symbol offset within this image's PT_TLS block. Installed value is the process's signed TP-relative offset per TVISA §19.2. |
| GPU count | Exactly one u32, including zero; must match .tirgpu's entry count (absence means zero). |
| Feature bytes | u64 byte RVA and feature-name text, in .tirfeat byte order. Exactly one record per byte; function of CPU features, not an unchecked value. |

Validate every destination, cross-table overlap, target, section count and binding against the **same immutable image** before any write. RELR/auth/TLS update authorized relocatable data only, never code; import/runtime/dispatch/feature slots obey TVISA A.2 location, type, size and order and become RELRO. The kernel profile allows relative relocations only. No ET_DYN load, boot or signature can pass on the strength of structural validation alone.

Carry UUIDs, module kinds and function tags from the source metadata through the linker; do not infer them from names. Main-executable local-exec TLS constants resolve at link time per TVISA §19.2 and need no record. Shared/framework TLS requiring load-time resolution uses a RELRO slot, never a text patch. An empty feature table is valid only when no feature bytes remain to be filled.

## Producer/consumer check

From the loader package run `swift run inspect-unsigned aarch64 path/to/output.elf` (also `x64`, `rv64`; add `--finalized` if note 6 is present and `--no-entry` for a library). This checks an actual producer artifact without a signing key: notes, TLD1 record structure, and BLAKE3 over the whole file with the ID field zeroed. It never executes the file and is not an alternate launch path.
