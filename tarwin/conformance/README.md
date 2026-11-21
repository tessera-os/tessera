# Tarwin 26.11.1 acceptance

This is a host-side Swift lab controller and evidence checker. It does not emulate a kernel, benchmark a Mac as if it were a reference machine, or turn unit tests into acceptance evidence.

```sh
swift test --package-path conformance
swift run --package-path conformance tarwin-conformance refs.tsv /absolute/new-run /absolute/trusted-lab-adapter
swift run --package-path conformance tarwin-conformance refs.tsv /absolute/archived-run
```

Use the train owner's inventory of **all** reference devices. Each non-comment row has eight tab-separated fields: `physical arch serial tarwin-build linux-build battery nested confidential`. Architectures: aarch64, x64, rv64. Flags: yes/no from hardware discovery. Build identifiers name unique immutable builds; the Linux identifier must be the latest stable mainline configured per workload, not a distro version. The same serial must denote the same physical machine across reboots. Bind these identifiers to measured boot logs, approved reference inventory, compiler/options, workload versions and board configuration in the archived capture. The runner cannot authenticate a lab operator's claims.

In collection mode the output directory must not already exist. The runner starts the supplied executable once per reference **without a shell**, with argv: arch, serial, Tarwin build, Linux build, output root, plan path. The plan contains every required (key, system, trial) triple, tab-separated, including ten independent samples for each comparator. The lab adapter owns machine reservation, boot, timeouts, workload execution, isolation of captures from guests and pinning the same compiler/options (including SPEC), corpus, units, configuration, and device serial. It must derive result bindings from its target, not echo requests. A nonzero exit blocks the run even if output exists. Never supply a fixture or guest-controlled controller.

For each triple it writes `<root>/<serial>/<key>/<system>-<trial>.log` (original nonempty capture) and the sibling `.tsv` (one line, tabs):
```
26.11.1  physical  arch  serial  key  system  build  trial  value
```
For a suite case, value is pass/fail and trial is 1; pass means every assertion for that case executed on-target. Benchmark values must be positive, finite, unrounded and in consistent units: latency (microseconds, except probe nanoseconds), throughput/rate (operations, bytes, packets or builds per unit time), power (watts). For guest CPU-bound use equal work per time; for build benchmarks use builds per time, not elapsed time. For interactive/deadline use the measured percentile under load per trial. For power cycles the controller must capture at least 10,000 successful cycles per reference. Persist configuration and raw logs per comparator. Bare-metal CPU-bound comparison uses the nonvirtualized workload on the reference hardware (Linux build). Nested/confidential refusal gets tested even when the hardware lacks support.

The checker compares per-workload geometric means, not an average across devices or workloads. The metadata comparator is the better of separately measured ext4 and btrfs for **each** operation. Missing data, unsupported ISAs, a different serial/build, a failed case, or any missed gate blocks the train. Exit: 0 = catalogued gates passed, 1 = blocked, 2 = invocation/inventory error. A green report still requires review of captures and the coverage ledger; it is not a certificate of full spec conformance.
