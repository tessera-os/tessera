# Tarwin kernel-profile preflight

Run from the Tessera checkout on macOS with the sibling Swift and KLF packages
present. The hosted tool calls the KLF Swift language plugin, not Apple swiftc.

```sh
p=tessera-packages/tessera/build/tarwin-profile
out=$(mktemp -d)
swift test --package-path "$p" --scratch-path "$out/build"
swift run --package-path "$p" --scratch-path "$out/build" tarwin-profile-check \
  KCore "$out/KCore.tirb" tessera-packages/tarwin/kcore/Sources/KCore/*.swift
```

Only a new output file is accepted. A compilation error, wrong profile/target,
invalid body, or noncanonical binary fails the command. The input and decoded
module must both pass TIRVerify. The extra Tarwin checks require Swift,
native CPU nounwind functions, and TIR §20.3's feature-free base bodies in
assembly variant sets. Nothing changes the compiler's profile. This is a
single-module preflight, not a kernel image builder or proof of the entire
§8.1 and §8.3 contract (context, no-allocation, stack-depth and native machine
hardening checks still need compiler/backend support).

**Current reproducible failure:** KCore reports unsupported declarations
(`SWIFT-DRV-0004`) and missing UInt64/operator support. A positive control for
the frontend, `func one() -> Int { 1 }`, reaches module emission but produces
`app/tessera`, not `kernel/tessera`. Neither produces a kernel artifact.
