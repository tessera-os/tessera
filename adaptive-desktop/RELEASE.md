# 26.11.1

**Project:** Adaptive Desktop  
**Release week:** 2026-11-02 – 2026-11-08

## Highlights

Corrected an Adaptive Desktop package dependency path in the monorepo.

## Fixed

- Pointed the `ArgumentParser` dependency at `../../kira-packages/argument-parser` instead of the nonexistent sibling `../argument-parser`.

## Validation

- The new dependency path is present in the manifest; an Adaptive Desktop application build has not been run for this preparation.
