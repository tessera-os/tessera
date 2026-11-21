# Executable page integrity

`verifyFilePage` takes two immutable `UnsafeBufferPointer<UInt8>` views: the pinned frame and its concatenated sibling records. The frame must have exactly the target page size, with zeros beyond EOF. A malformed, truncated or overlong witness is rejected.

The loader validates chunks of the byte stream covered by the signed BLAKE3-256 build ID. It does not trust a separate hash per page. Every leaf incorporates its absolute chunk index, every parent is formed in BLAKE3 order, and only the global root carries the ROOT flag.

`NativePageIndex` builds the optional CV cache from the same immutable native
ELF that passed authorization. It checks the computed tree root against note 1.
Supply caller-owned storage sized by `capacity(fileBytes:)`; at page-in, use
`witnesses` to emit a proof for a whole file page preceding the signing notes.
Always pass the emitted prefix to `verifyFilePage` with the index's canonical
size and root. A cache hit is not an integrity decision. After verification
expose only file bytes belonging to the authorized executable segment and
zero any remaining bytes of its last page. Capture a `NativeExecutableSegment`
for each file-backed RX PT_LOAD at load time. On fault, its `fileOffset` uses
the page RVA to select the storage page; its `prepare` checks the exact private
frame against that RVA and the authenticated root, then zeroes segment padding.
It neither installs a PTE nor accepts a page from another RVA.

The pager must capture the build ID and canonical byte-stream extent from authenticated metadata, read into private pinned storage, and supply exactly those bytes as little-endian blocks (zero-pad the final block). For each 1 KiB chunk of the requested page, consume its sibling chaining values from leaf to root and pass the proof to the page check. A cache of sibling values need not be trusted. The page check requires every chunk, in order, including a partial chunk at EOF. Zero-fill any part of the mapping beyond the file; do not reuse bytes from the page's prior owner.

Only after all proofs succeed may the pager publish those same immutable bytes. On failure discard the page and terminate with `CodeSignatureInvalid`; do not retry through an unsigned mapping. These routines neither authenticate signatures nor change a mapping. The signer and loader must agree on the canonical stream (including how the identifier's own note is handled); there is no alternate digest on failure.

The compression routine and known-answer vectors follow [BLAKE3 1.8.2](https://github.com/BLAKE3-team/BLAKE3/tree/1.8.2), used under CC0-1.0. Run the host tests with `swift test` in this package. Its altered-byte, incomplete/reordered proof and 4 KiB / 16 KiB checks are not a signature, pager, or live kernel conformance result.
