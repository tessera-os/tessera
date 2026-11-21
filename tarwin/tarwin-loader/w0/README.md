# Stage-0 QEMU verification

Experimental, verification-only Swift for disposable emulator kernels. This
is not an audited production crypto library. No keys are generated and no
private key material is compiled into this module.

Edwards arithmetic follows [public-domain TweetNaCl](https://tweetnacl.cr.yp.to/)
and RFC 8032. The verifier rejects noncanonical points/scalars, negative zero,
the identity key and keys outside the prime-order subgroup. SHA-512 uses
FIPS 180-4. The public-data scalar multiplication is variable-time.

ML-DSA-65 follows FIPS 204 with SHAKE from FIPS 202. The eight polynomials
(8 KiB) live in caller-provided scratch. The small test fixture is public
verification data only (key, context, message, signature) from
[NIST ACVP-Server, ML-DSA sigVer FIPS204, group 3 case 43](https://github.com/usnistgov/ACVP-Server/tree/master/gen-val/json-files/ML-DSA-sigVer-FIPS204).

Run `swift test -c release` here. Passing these host vectors does not
authenticate an archive or constitute a guest boot.

The EFI harness imports `TarwinW0Verify` after `KCore`, `TarwinBoot`,
`Tarboot` and `TarwinLoader`. Pass independently established trusted UTC,
security floor, slot, debug-emulator authorization, train/TIR, address limit
and real CPU baseline support in `W0Policy`. Missing inputs must not be
substituted from the signed file. Compile/link this package only in a
disposable debug harness. Supply an independently provisioned TQE1 pin, the
detached TSG1, the exact TIRA snapshot and private disjoint scratch (54 BlakeCv,
2048 Int32, 1024 message bytes) to `authorizeQEMUStage0`. Keep the returned
ELF slice pinned, DMA-inaccessible and immutable through placement; never
reopen the ESP. The call neither maps pages nor transfers control.

The W0 archive must have exactly two disjoint uncompressed members,
`boot.json` and `kernel`. Their individual BLAKE3 digests, the canonical
debug configuration, rollback floor, both layers' hybrid signatures and
the kernel's identity, role, train, CPU and relocation-free R/RX subset
all have to pass. Release mode and non-enrolled machines must not call this
entry point. This is not a production trust-store or PKI implementation.

The default host suite checks actual tagged AArch64 and x64 archives from
the platform's Embedded Swift kernel, without executing them. The previous
signed but untagged AArch64 entry must fail. The public corpus is confined to
the test target; the captured UTC is an independent test input from that
run, never a clock to use in the guest. No private key is in the corpus.

## W1 restricted user-set verification

`authorizeQEMUStage1(archive:signature:enrollment:systemEnrollment:policy:initEntryTag:contract:hashes:polynomials:message:)`
is the AArch64 debug-QEMU entry point. Use the W0 modules, scratch sizes,
real CPU checks, UTC, slot and TPM floor above. The boot pin covers the
archive and kernel; the system pin covers each user image. The two TQE1
public pins, process runtime entry tag, and `EarlyRIDLContract` (ABI UUID,
exact RIDL symbol, canonical interface SHA-256 and function type tag) must
be installed independently. Do not copy any from the archive or assume a
platform-dependent symbol RVA or a fixed load address.

The accepted TIRA has four disjoint, uncompressed, hash-verified members:
`boot.json`, `kernel`, `tessera.init` and `LibTessera`. Each native image has
its own verified TSG1. The userspace subset has one file-backed RX load per
image, no grants, TLS, runtime lookups or dispatch slots; init has one eager
function import inside RELRO, and the framework has no entry or imports.
The result borrows the same immutable member bytes, gives the exact RX
intervals **as RVAs**, and resolves an import slot to a tagged export RVA.
`initSHA256` covers the entire signed init ELF, not its archive directory
entry, BLAKE3 build ID or rounded code range.

Before entry, the kernel must still verify and install pages from those
bytes, establish private mapping provenance, authenticate the function
pointer for the process and seal RELRO, extend PCR 10 with `initSHA256` and
publish the protected event log. Verification does none of those things.

`InteropW1` is **host test data, not a boot set for execution**. Its two
fresh public pins, UUID, ABI hash, entry tag, export and stub bodies are
test-only. The writer supplied both ELF files, and the platform's
`stage1BootSet` assembler packed the signed members. The two other sidecars
cover correctly rehashed, repacked archives with one invalid native
signature (init Ed25519 or library ML-DSA-65), so a valid detached
signature alone cannot pass. No production or live-harness key was used.

To also exercise a newly signed fixture on the host, set
`W0_TEST_ARCHIVE`, `W0_TEST_SIGNATURE`, `W0_TEST_ENROLLMENT` and
`W0_TEST_UTC` (an independently supplied Unix time) for the test command.
Set `W0_TEST_MACHINE` and `W0_TEST_ENTRY_HEX` from the expected build
manifest for other targets (defaults: `aarch64` and `4010`).
