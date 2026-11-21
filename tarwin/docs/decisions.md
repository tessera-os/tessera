# Tarwin implementation decisions — 26.11.1

TW-001 through TW-022 in [Appendix B](../../tessera/roadmap/Tarwin.md) remain normative. These choices resolve implementation details; none is a conformance waiver.

| Id | Decision | Reason |
| --- | --- | --- |
| SW-001 | Non-allocating Embedded Swift in IRQ, guest-exit, probe-hit and panic paths; Embedded Swift for the kernel; regular Swift for tvmm, compiler analysis, exporter, controller and tests. | No Foundation or hosted runtime in a kernel target. Host build and freestanding code generation are distinct checks. |
| BO-001 | Use TBIB revision 1; check producer train against the approved 52-train history. Validate the entire sorted, disjoint map and reserved fields before consuming it. | A valid prefix does not make the rest of the handoff trustworthy. See [boot decisions](../tarwin-boot/decisions.md). |
| BO-002 | Persist slot choice and attempt decrement before boot. Use recovery on exhausted attempts or malformed protected state; never advance the security floor from an unconfirmed candidate. | Preserve rollback and recovery semantics across power loss. |
| EX-001 | Number the 135 named public §23 calls from 1 in ASCII lexical order; zero is invalid. | The introductory count disagrees with the named list. Preamble aliases are not extra calls. |
| EX-002 | Generate train extensions separately from 0x10000; domain code references generated names. | Keep public ordinals stable within this train and avoid conflicting local allocations. |
| EX-003 | Use §23.3 VM/vCPU spelling, Probe.attach with last-close detach, and PerformanceSession.create/start/stop/read. | [One shared source](../tarwin-syscall/decisions.md) for the private ABI. A number does not install a handler. |
| EX-004 | Keep public Presence at 16; give Fence the private type 32. Do not expose it as a public handle type. | Distinguish nontransferable Presence and exportable fences; [object decision](../tarwin-object/decisions.md). |
| EX-005 | DeviceKit calls occupy a separate 0x10100 bank in the shared call index. | Preserve existing train call numbers. See [execution decisions](../tarwin-syscall/decisions.md). |
| HV-001 | Reserve/pin before installing mappings. Do not recycle guest memory, a slot, or its translation domain until all invalidations complete. | Stale translations must never reach new owners. Partial device assignment stays quarantined. |
| HV-002 | Require confidential-guest attestation; require independent support for the combination of nested and confidential. | Having each mode separately does not prove the combination is isolated. |
| VM-001 | Negotiate only implemented features on split queues. Snapshot descriptor metadata, pin guest-object spans, bound private I/O buffers and publish used entries after completion. | Unsupported packed/indirect descriptors cannot be interpreted as host addresses. |
| VM-002 | Bind a migration to an epoch; freeze CPUs/input/DMA before final capture and fence the source before durable ownership changes. | A lost commit acknowledgement must not create two live machines. |
| VM-003 | Bind Android surface routing and service grants to one sandboxed job, authenticated app, epoch and host-owned handles. | Android permissions are not host authority. |
| PR-001 | Analyze a structured postorder control-flow graph, charging the larger branch and full proven loop count. Reject unknown nodes, effects or bounds. | No profile escape through unexamined paths. A signed object also needs an immutable pin and matching hook/maps. |
| OB-001 | Publish a panic record with version, bounded length, CRC32 and last-written commit byte. Clear it only after archival succeeds. | Warm reset may interrupt either write or collection. CRC detects damage; it does not authenticate provenance. |
| OB-002 | Build debug transport inspection separately, with neither dependency nor entry point in release trace code. | A boot option must not enable a release-image debugger. |
| AC-001 | Block on any missing physical reference or independent workload result; compare ten-run geometric means per workload, build and serial. | Averages across machines or a portable unit test can hide a release regression. |
