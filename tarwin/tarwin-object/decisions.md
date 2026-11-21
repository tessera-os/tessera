# Object type decisions proposed for the train log

| Id | Decision | Reason |
| --- | --- | --- |
| EX-004 | Keep public Presence = 16; assign Fence = 32 in the **Tarwin-private** object index. Leave 17 and 18 unallocated. | Tarwin §22.2's parenthetical “LibTessera type 16” conflicts with the LibTessera §3.2 type table and §17 wire boundary. Overloading 16 would confuse capabilities: Presence can never be transferred or duplicated, but fences are exportable. 32 is the next unused number after Tarwin §9.2. DeviceKit retains its opaque 16-byte tokens; never cast one into a kernel handle or add a Fence type to public LibTessera. |
