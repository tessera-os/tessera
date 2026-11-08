# 26.11.1

**Project:** AppRegistry  
**Release week:** 2026-11-02 – 2026-11-08

## Highlights

- Added publisher-bound, user-selected custom-link defaults. Web and reserved
  system schemes are not eligible; domain ownership is a separate decision.
- Added strict, bounded persistence with tests for damaged metadata, duplicate
  defaults and linked preference paths.
- Added signed `links` manifest declarations, version-3 persisted registry
  records with version-1/2 migration, accepted-only chooser candidates and
  persistent link activation/revalidation against exact image digests.
- Added Ed25519 signed-v2-image fixtures and regression coverage for scheme
  withdrawal, staged updates, rollback and stale activation tickets.
- Added signed `types` manifest declarations (Ed25519 statement v3) and
  application registry v4 persistence, retaining v1/v2/v3 readers without
  inventing document claims on migration. Open With refuses undeclared or
  withdrawn types, and persists image/version-bound document tickets.
- Added signed v3 fixture, type-tampering tests and stored-document resolution
  checks for selection, removal, upgrade and withdrawal.
- This is a model for the later trusted launcher; no activation or entitlement
  is granted by these preference records.

## Validation

- `kira check tessera-packages/app-registry/tests/registry_kik --test`: `Check: Ok`.
- `kira check --target aarch64-unknown-linux-gnu tessera-packages/app-registry`: `Check: Ok`.
- `kira check tessera-packages/app-catalog/tests/catalog_kik --test`: `Check: Ok`.
- Host test execution is blocked by the installed toolchain: `ld64.lld` cannot
  parse the macOS 27 SDK's `libSystem.tbd`; the system linker reports an
  unresolved `_Any` from generated `kir.Optional`. The `_Any` failure also
  reproduces on an unchanged copy of the registry without the new files.
  The runtime backend builds bytecode but fails test enumeration.
- No OS boot or publication performed.
