# Execution decisions proposed for the train log

| Id | Decision | Reason |
| --- | --- | --- |
| EX-001 | Number the named §23 LibTessera calls from 1 in ASCII lexical order, with 0 invalid. | Its category counts match its 135 names; its introductory count (134) does not. File.read/write in the preamble are aliases, not additional calls. |
| EX-002 | Append a disjoint train-private range from 0x10000, sorted by the same rule from `extensions.txt`. Use the generated kernel TarwinCall names in domain handlers, not local numbers. | Tarwin specifies calls outside §23. One catalogue drives both sides without shifting §23 ordinals or exposing extensions in the public library. Undefined numbers have no provider; a number alone never grants authority. |
| EX-003 | Use Tarwin §23.3's spellings for VM/vCPU; §27 uses Probe.attach with last-close detach, §28.3 uses PerformanceSession.create/start/stop/read. The latter names are implementation choices. | Probe loading/signing stays with the compile service; counter sessions require ownership or Debug for system scope. Handle.close supplies lifetime. No extension is callable until a provider and its access checks are installed. |
| EX-005 | Add the §18–19/22 DeviceKit calls in a private bank at 0x10100. An `@base` line in the same extension index starts a new bank; lexical order applies within each. | Preserves both §23 numbers and previously generated execution/VM numbers in this train. DeviceSlot and MMIO/DMA operations require validated slot/domain authority; Fence.wait and Fence.signal require Wait and Signal respectively on private Fence type 32. No Linux token is a handle. |

Run `swift run call-index` from this package after changing either input;
`--check` verifies both generated files without writing. This is a host build
tool; neither Foundation nor a parser is linked into the kernel. Numbers are not
syscall stubs, a linked entry path, or evidence that a call is implemented.
