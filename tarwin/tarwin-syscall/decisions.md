# Execution decisions proposed for the train log

| Id | Decision | Reason |
| --- | --- | --- |
| EX-001 | Number the named §23 LibTessera calls from 1 in ASCII lexical order, with 0 invalid. | Its category counts match its 135 names; its introductory count (134) does not. File.read/write in the preamble are aliases, not additional calls. |
| EX-002 | Append a disjoint train-private range from 0x10000, sorted by the same rule from `extensions.txt`. Use the generated kernel TarwinCall names in domain handlers, not local numbers. | Tarwin specifies calls outside §23. One catalogue drives both sides without shifting §23 ordinals or exposing extensions in the public library. Undefined numbers have no provider; a number alone never grants authority. |
| EX-003 | Use Tarwin §23.3's spellings for VM/vCPU; §27 uses Probe.attach with last-close detach, §28.3 uses PerformanceSession.create/start/stop/read. The latter names are implementation choices. | Probe loading/signing stays with the compile service; counter sessions require ownership or Debug for system scope. Handle.close supplies lifetime. No extension is callable until a provider and its access checks are installed. |

Run `python3 tools/call_index.py` from this package after changing either input;
`--check` verifies both generated files without writing. This is a host build
tool; neither Python nor a parser is linked into the kernel. Numbers are not
syscall stubs, a linked entry path, or evidence that a call is implemented.
