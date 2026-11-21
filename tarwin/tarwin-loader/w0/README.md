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

The default host suite checks an actual signed AArch64 archive from the
platform's Embedded Swift kernel, without executing it. The public fixture
is confined to the test target; the recorded UTC is an independent test
input from that run, never a clock to use in the guest. No private key is
in the corpus. Its TIRA SHA-256 is
`bac20805c738ac09c8010ffc937d44191609e3a1ff0cc4bedf223e736d5a18d7`.

To also exercise a newly signed fixture on the host, set
`W0_TEST_ARCHIVE`, `W0_TEST_SIGNATURE`, `W0_TEST_ENROLLMENT` and
`W0_TEST_UTC` (an independently supplied Unix time) for the test command.
Set `W0_TEST_MACHINE` and `W0_TEST_ENTRY_HEX` from the expected build
manifest for other targets (defaults: `aarch64` and `4000`).
