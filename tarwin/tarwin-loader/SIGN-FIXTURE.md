# Disposable QEMU signing fixture

Build `swift build -c release --product sign-fixture` on the Mac. The tool uses an absolute `OPENSSL` path (default: Homebrew openssl@3, tested with 3.6.5). Use only for the development W0 debug standard-installation emulator. No production keys, system trust store, release policy, or guest entry are involved. Commands never overwrite an output.

```sh
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sign-fixture init "$work/QEMU-ONLY"
sign-fixture enroll "$work/QEMU-ONLY" "$work/public-enrollment"
sign-fixture sign-image "$work/QEMU-ONLY" aarch64 26.11.1 26.11.2 unsigned.elf "$work/kernel.elf"
sign-fixture verify-image "$work/QEMU-ONLY" aarch64 26.11.1 26.11.2 "$work/kernel.elf"
# Package the signed kernel.elf into BOOT.TIR, then sign that exact archive.
sign-fixture sign-set "$work/QEMU-ONLY" BOOT.TIR "$work/BOOT.SIG"
sign-fixture verify-set "$work/QEMU-ONLY" BOOT.TIR "$work/BOOT.SIG"
```

The signer creates a disposable two-day CA (its private key is discarded) and two one-day leaves. Verifiers need only the independently provisioned three public PEM certificates. Never copy the signing directory to the ESP. Native signing accepts only the relocation-free, baseline R/RX W0 subset: kernel/kernel, fixed build and expiry train, explicit TIR version, no entitlements, TLS, mutable segments, imports or GPU records. The signer moves PT_NOTE and its file-only SHT_NOTE together without moving the section table; the remaining original bytes participate in the final digest.

For QEMU only, the detached archive envelope has exactly the TSG1 shape and signs ASCII `Tarwin boot set v1`, one NUL and 32 raw BLAKE3 bytes of the **entire final archive**, not an image ID or a member digest. A valid signature does not imply valid member hashes, allowed options, security version, or an authorized native kernel. Verify both layers on the same pinned bytes before placement.

The public enrollment format is `TQE1`, u64le earliest allowed UTC Unix second, u64le last allowed second (intersection of both leaves and root), BLAKE3-256 of the exact canonical enrolled chain JSON, raw Ed25519 key (32), raw ML-DSA-65 key (1952). Pin the **entire** enrollment independently in the emulator-only trust boundary. An attacker-selected enrollment, clock or platform state is not a trust source. Regenerate to rotate; removing the trust record revokes the identity. The host checks X.509 signatures, times, code-signing purpose and the root self-signature at enrollment. No PKI parser or private key belongs in a W0 guest.
