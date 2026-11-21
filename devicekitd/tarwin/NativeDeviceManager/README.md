# NativeDeviceManager

Tarwin user-space driver selection and supervision (DeviceKit §§6, 8, 19).
Run `swift test` in this directory on macOS.

`rankDrivers` takes a trusted snapshot of one node, normalized match dictionaries, and authenticated device policy. It filters on admission, the twelve-month API window and overrides before ranking by bus identity, property count, score, vendor origin and API recency. Ties use the installed executable ID, so catalog iteration order does not change the result. A malformed duplicate executable ID invalidates the selection.

Give the ranked result to one serialized `DriverProbes` per node and fresh generation. Only that probe's response can advance it. Once declined, failed, or out of restarts, the job must stop and its grants drain before another candidate gets a turn. Removal while draining never launches the next candidate. If none accepts, the node returns to discovery with one notice. The manager retains ordinary driver lifecycle state in `DriverSupervisor`.

`updateBlockers` identifies each required built-in binding outside a proposed train's window. Its caller supplies the complete installed binding list; this library does not enumerate hardware, authenticate packages, launch jobs, or apply an OS update. The package tests exercise policy and retirement ordering, not a booted device manager.
