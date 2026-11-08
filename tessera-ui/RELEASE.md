# 26.11.1

**Project:** Tessera UI  
**Release week:** 2026-11-02 – 2026-11-08

## Highlights

- Added `openDocumentInNotes` to queue a selected File capability through the
  existing workspace request flow. Failed sends close handles that remained
  with the caller. This does not grant other applications document-picker
  authority.
- Added source-checked wire regression tests for opcode 12, the fixed Notes
  executable payload, and independent read/edit modes. Ordinary launch
  encoding remains unchanged.
- Document-open requests now expose a distinct confirmed/failed result, rather
  than interpreting a closed PID 1 reply channel as successful. Only one
  document launch may await acknowledgement at a time, preventing histories
  from being assigned to the wrong request. Other workspace requests retain
  their existing UI behavior.

## Validation

- Tessera-target Kira source validation printed `Check: Ok`.
- No guest boot or running-app document activation was verified.
