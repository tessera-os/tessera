# TDK Specification 1.0

Date: 2026-11-04. TDK protocol version: 1.0. Service API version: 26.11. Status: normative draft 1.0. Audience: every agent and engineer who implements Tessera Dev Kit, its host tools, device service, transports, service adapters, SDKs, or MCP server.

Contents

1. Status, scope and rules for implementers
2. Terminology
3. Goals and non-goals
4. Architecture and ownership
5. Identities, discovery and device selection
6. Pairing and trust
7. Authorization, presence and audit
8. Transports
9. Connection and session lifecycle
10. Wire protocol
11. Requests, operations and consistency
12. Capabilities, schemas and service APIs
13. Time, scheduling and barriers
14. Full drive mode
15. Input devices and events
16. Gestures, recording and replay
17. Dynamic platforms and topology
18. Settings
19. Applications and processes
20. Files and transfers
21. Shells and execution
22. Observation, screenshots and media streams
23. Logs, tracing, profiling and debugging
24. Network, peripherals and simulation
25. Power, updates, recovery and boot
26. Host daemon and SDK
27. Command-line interface
28. MCP server
29. Automation and multi-device orchestration
30. Resource limits and performance
31. Failures and diagnostics
32. Security requirements
33. Versioning and compatibility
34. Conformance
35. Delivery gates
36. Appendix A: wire layouts and common schemas
37. Appendix B: method catalogue
38. Appendix C: decision log

---

## 1. Status, scope and rules for implementers

This document is the normative specification of Tessera Dev Kit (TDK). TDK is Tessera's device development, inspection, debugging and automation system. It comprises the `tdk` command-line tool, a host broker, a device service, typed integrations with system services, host SDKs, and a host MCP server. A conforming implementation satisfies every MUST applicable to its declared profile.

TDK is a specification here, not an implementation. Names assigned to TDK components, service adapters and protocols in this document are required contracts for their future implementations; their appearance does not assert that those interfaces already exist.

### 1.1 Normative language

- MUST, MUST NOT, SHOULD, SHOULD NOT and MAY carry their RFC 2119 meanings.
- Sections or paragraphs titled "Rationale" or "Example" are informative. Everything else is normative.
- Where prose and a table disagree, the table wins. Wire layouts in Appendix A take precedence over other descriptions of the wire. A future RIDL declaration MUST implement this document and MUST NOT silently change its semantics.
- An implementation MUST NOT claim a feature merely because it accepts its request. It MUST implement the specified authorization, completion, failure and recovery behavior.

### 1.2 Relationship to other documents

| Document | Relationship |
| --- | --- |
| `DeviceKit.md` | Owns hardware registry, driver lifecycle and device families. In particular, section 13.2 defines HID input delivered to MosaicDisplay; section 18.4 restricts each family to its designated clients |
| `Tarwin.md` | Owns kernel objects, isolation, clocks, device mechanisms, tracing, debug-image restrictions, boot sets, updates and recovery |
| `LibTessera-System-Interface-Specification-v0.1.pdf` | Defines the system interface used here: service discovery, handles, Ports and completions, Nodes and files, processes, grants, presence, streams and diagnostics |

These documents retain authority over their domains. TDK MUST NOT change the meaning of a LibTessera handle, create remote `Presence` handles, bypass a family's owning service, add a kernel debugger to a release image, or treat a display path as filesystem authority. TDK defines the additional remote-control contracts, including the settingsd and platform adapters, rather than inventing new LibTessera system calls.

### 1.3 Profiles

| Profile | Required behavior |
| --- | --- |
| Full device | All core contracts in this document, every input class, all four dynamic-platform contracts, settings, applications, files, execution, observation, diagnostics and supported transports; physical hardware operations remain capability-dependent |
| Headless device | Full device control plane; display, seat and media facilities report their actual availability; no fabricated display or presence |
| Recovery | Authenticated identity and sessions, capabilities, operation status, bounded diagnostics, verified update/repair and policy-authorized reboot; other methods return `UnavailableInMode` |
| Host | CLI, broker, SDK contract, USB and Wi-Fi discovery, all required transport profiles, multi-device operation and MCP over stdio and Streamable HTTP |
| Simulator | Full device protocol and deterministic virtual time/testing extensions; simulated identities and attestation are explicitly distinguished |

Full-device support for an input class means the OS can create and route that synthetic class when an eligible seat exists; a physical controller or pen need not be attached. Missing required software functionality is not equivalent to missing hardware. Unsupported hardware, image restrictions and policy denial MUST be reported separately.

### 1.4 Rules for implementers

1. Publish machine-readable schemas, compatibility metadata and conformance results with each release.
2. Keep authority in the owning service. TDK adapters MUST NOT become alternate settings stores, launchers, input dispatchers or filesystem policy engines.
3. Record an unresolved implementation choice in the decision-log format of Appendix C. A decision MUST NOT weaken a MUST or redefine an observable result.
4. Do not report a control operation as successful on transport receipt alone.
5. All examples are illustrative. The common schemas, method catalogue and domain rules define behavior.

---

## 2. Terminology

| Term | Meaning |
| --- | --- |
| Host | Computer running TDK tools and connecting to one or more Tessera devices |
| Broker | Per-user host service `tdk-hostd`, which owns device connections and multiplexes authorized clients |
| Device service | `tdkd`, the Tessera service that terminates authenticated TDK connections and dispatches authorized operations |
| Principal | Cryptographic identity of a host, a host client, or a delegated network caller |
| Pairing | Explicit enrollment of a host identity into a device's trust store |
| Grant | Policy authorization for a principal, resource scope, operation set and lifetime; distinct from possession of a paired key |
| Connection | One authenticated transport connection |
| Session | Logical authorized interaction with a device, possibly surviving transport reconnection |
| Epoch | Generation identifier invalidating stale state after restart, replacement or transition |
| Operation | Identified unit of work whose status can be queried independently of the originating request |
| Drive lease | Exclusive or explicitly shared authority to inject input into a seat for a bounded time |
| Seat | Input-routing domain associating users, focus, displays and input devices |
| Topology | Versioned description of seats, displays, surfaces, transforms, segments and routing |
| Dynamic platform | Runtime interaction platform: `AdaptiveMobile`, `AdaptiveDesktop`, `Console` or `Media` |
| Resource reference | Opaque, scoped remote name resolved by the device; never a serialized kernel handle |
| Snapshot | Coherent observation with revisions and capture metadata; not a promise that unrelated services were globally atomic |
| Full drive | Input, observation and lifecycle control across the granted device UI and service scopes |

---

## 3. Goals and non-goals

### 3.1 Goals

1. An adb-shaped CLI with discoverable, typed operations and precise machine-readable results.
2. Equivalent wired and Wi-Fi control, including authenticated discovery, pairing, multiple devices and transport replacement.
3. Complete synthetic input: touch, multi-touch, pen, touchpad, keyboard, text, mouse, controller buttons and analog controls, navigation, media and accessibility actions.
4. Deterministic compound gestures, feedback-driven automation, screenshots, live media and observations carrying enough provenance to avoid stale actions.
5. Live dynamic-platform switching and topology changes without disconnecting the logical session or stranding input state.
6. Direct settingsd operations, application management, capability-scoped files, native execution, logs, traces and device debugging.
7. The same authorization and execution semantics through CLI, SDK and MCP.
8. Explicit failure semantics under packet loss, sleep, service restart, hot-plug, reboot, revocation, storage exhaustion and concurrent users.
9. A low-overhead data path with bounded memory and priorities that keep control responsive during large transfers.

### 3.2 Non-goals

- Android wire compatibility, POSIX emulation, or a second implementation of system services.
- Turning pairing into root access or software input into physical user presence.
- Exposing raw DMA, arbitrary kernel calls, device-private keys, biometric templates or protected display buffers.
- Promising physical-event determinism, global multi-device atomicity or exactly-once execution after arbitrary hardware failure.

---

## 4. Architecture and ownership

```text
tdk CLI / host SDK / MCP stdio / MCP Streamable HTTP
                       |
            per-client authenticated local API
                       |
                   tdk-hostd
                       |
          TLS TCP / QUIC / TLS USB byte stream
                       |
                     tdkd
                       |
          scoped, typed system-service adapters
                       |
 MosaicDisplay + input / settingsd / platform coordinator
 Launcher + installer / Namespace / logger + trace + crash
 network + power + update + recovery / DeviceKit manager
                       |
            LibTessera and Tarwin mechanisms
```

### 4.1 Components

| Component | Responsibility |
| --- | --- |
| `tdk` | Parse commands, resolve explicit selectors, render results, manage interactive terminals and streaming output |
| `tdk-hostd` | Keys, trust records, discovery, connection pools, session routing, client isolation, transfer scheduling and local artifact ownership |
| `tdk-mcp` | MCP protocol, caller authentication, tool schemas, resources and translation to the same broker API |
| `tdkd` | Device authentication, grants, operation journal, admission control, remote resources, transport-independent dispatch and audit correlation |
| System adapters | Validate and execute a domain's TDK operations inside that domain's authority |
| Trusted local UI | Pairing, grant approval, live-control indicator, emergency stop and local revocation |

Device components and policy adapters SHOULD be written in Kira. Protocol definitions are RIDL contracts with generated bindings; cryptographic and codec implementations MAY use supported system libraries. No implementation language may alter the wire ABI.

### 4.2 Service binding

`tdkd` registers `tessera.tdk` with the System service. The following names are assigned by this specification to privileged adapter channels, resolved using `System.connectService`:

| Adapter channel | Owner |
| --- | --- |
| `tessera.tdk.input`, `tessera.tdk.display` | MosaicDisplay and its input service |
| `tessera.tdk.settings` | settingsd |
| `tessera.tdk.platform` | System dynamic-platform coordinator |
| `tessera.tdk.apps` | Launcher and application installation service |
| `tessera.tdk.files` | Namespace service |
| `tessera.tdk.diagnostics` | Logging, trace and crash services through a scoped diagnostics adapter |
| `tessera.tdk.network`, `tessera.tdk.power`, `tessera.tdk.update` | Respective owning services |
| `tessera.tdk.devices` | DeviceKit manager, for registry and authorized lifecycle/testing operations |

An adapter MAY be hosted in a separate constrained process, but MUST receive only explicitly delegated resources and MUST preserve the owner's checks. Each request carries an authenticated principal chain, effective grant, operation ID, deadline and audit context. These are service-issued claims, not unchecked host-supplied identifiers. The adapter independently checks expiry, revocation generation and resource scope.

### 4.3 Data path

The device uses LibTessera Ports and completions for asynchronous work. Local high-rate data uses bounded shared-memory rings and fences where supported. TDK MUST NOT serialize process-local handle values or expose ring mappings to a remote host. Encoding, capture and transfer workers run outside the authorization dispatcher. Encoder failure cannot block input cleanup or revocation.

The input service, not `tdkd`, owns the final drive-lease watchdog and held-input state. A `tdkd` crash therefore cannot leave a key, touch contact, mouse button or analog trigger active.

---

## 5. Identities, discovery and device selection

### 5.1 Identity

Each enrollment identity has a device signing key, preferably protected by platform secure storage. `deviceId` is the lowercase hexadecimal SHA-256 digest of its DER SubjectPublicKeyInfo. A host uses the same construction for `hostId`. Friendly names, IP addresses, USB serial strings and model names are labels, never authenticators.

Every boot generates `bootId`; every `tdkd` instance generates `daemonEpoch`. Both are random 128-bit values. Seats, displays, surfaces, processes and service resources also have generation-qualified references. Resetting enrollment or cloning a simulator MUST generate a new identity. Two authenticated instances presenting the same device identity with incompatible concurrent instance state MUST be quarantined as `IdentityConflict`; the broker MUST NOT silently merge them.

### 5.2 Discovery

Hosts discover USB interfaces and DNS-SD services `_tdk._tcp` and `_tdk._udp`. The UDP service advertises QUIC. Advertisements contain only protocol major, an ephemeral discovery ID, pairing availability, transport mode and optional user-approved friendly name. They MUST NOT expose stable hardware identifiers, account names, granted applications or screenshots.

Discovery IDs rotate on service restart and at least every 15 minutes. Existing authenticated connections are unaffected. A discovery result is untrusted until authentication completes. Hosts MUST NOT fetch arbitrary URLs, execute commands or install software from discovery metadata.

Explicit IPv4, IPv6 including link-local scope, DNS names and USB interface identifiers are supported. mDNS failure MUST NOT prevent explicit connection. DNS names are resolved within the requested network/interface scope; the resolved endpoint and authenticated identity are recorded separately. Default discovery remains on directly attached interfaces; routed or relay discovery requires configured scope.

### 5.3 Selection

Device records distinguish `discovered`, `pairing`, `unauthorized`, `connected`, `locked`, `sleeping`, `recovering`, `offline` and `identity-conflict`. Multiple transports of one authenticated identity appear as one device with multiple paths.

A command MUST select exactly one identity unless it explicitly requests a set. With no selector, exactly one eligible device may be selected; zero is `NoDevice`, more than one is `AmbiguousDevice`. The selected identity is pinned for the entire operation. Disconnect MUST NOT redirect a pending command to another device.

Selectors support exact device ID, an unambiguous user-assigned alias, transport type, and explicit group membership. Prefix matches require uniqueness. Fleet operations expand selectors to a fixed identity list before admission and return a result per identity.

---

## 6. Pairing and trust

### 6.1 Enrollment

Pairing and granting are distinct. A device MUST be locally placed into pairing mode through trusted UI or an explicitly provisioned management policy. Pairing mode expires after 120 seconds by default. Merely attaching USB or joining the same Wi-Fi network does not enable it.

The mandatory pairing method uses a QR code or equivalent copyable enrollment URI carrying:

- Pairing schema version, endpoint hints and one-time enrollment ID.
- Device public-key fingerprint.
- A cryptographically random 256-bit one-time secret.
- Expiry and the requested pairing mode.

The URI MUST NOT be logged, placed in shell history by TDK, advertised through DNS-SD, or treated as a reusable credential. A terminal enrollment input accepts it through a hidden prompt or protected input descriptor; a command-line argument containing the secret is not required.

### 6.2 Handshake

An enrollment connection authenticates the device with the QR fingerprint but has no paired client identity yet. It is a restricted TLS endpoint state, not an authenticated control session. It accepts only `hello`, `pair.begin`, `pair.finish` and `pair.status`, subject to pairing-mode limits. All other requests return `NotPaired`. `pair.begin` returns the device nonce, enrollment expiry and allowed request shape; it does not expose the enrollment secret or create authority. `pair.finish` carries the proofs below and waits for the local approval result through a bounded operation/status exchange. A pending approval never occupies an unbounded dispatcher thread.

1. The host establishes TLS 1.3 and pins the server public key from the enrollment URI before sending enrollment information.
2. The host generates or loads its protected identity key and sends its public key, label, nonce, requested scopes, and a proof of possession.
3. Enrollment proof is HMAC-SHA-256 using the one-time secret over the deterministic encoding of `{enrollmentId, deviceKeyHash, hostKeyHash, hostNonce, deviceNonce, requestedScopes, tlsExporter}`. `tlsExporter` is 32 bytes derived with TLS exporter label `EXPORTER-TDK-PAIR-1` and empty context. The host also signs this encoding with its identity key.
4. The device verifies the proof, expiry and attempt limits, then shows the host identity and requested authority in trusted local UI. The user may approve only a subset.
5. The device atomically consumes the enrollment secret, persists the host key and approved grant, and returns the enrollment result. Approval and enrollment state share a durable transaction.
6. The host stores the pinned device identity only after successful enrollment. A lost reply is resolved using the same enrollment ID and host proof; it MUST NOT create a second grant.

The same protocol applies over USB. Implementations MAY add a standardized PAKE-based human-code pairing profile, but MUST publish its exact algorithm and transcript as a versioned extension. Short codes MUST NOT be used as TLS passwords, ordinary hashes or bearer tokens. TDK 1.0 does not require short-code pairing.

### 6.3 Reconnection, rotation and revocation

Paired connections use mutual TLS with registered public keys. Certificate trust is anchored in enrollment records; self-issued certificates are acceptable only under those pins. Implementations MUST support P-256 signatures and SHA-256; other algorithms are negotiated through explicit profiles. TLS libraries MUST verify key possession and all applicable certificate constraints.

Key rotation requires a statement signed by the old and new keys, a monotonically increasing enrollment generation, and authorization from device policy. Lost keys require fresh enrollment. A changed fingerprint MUST NOT be accepted merely because an address or friendly name matches.

Revoking a host immediately closes its active sessions, cancels queued work, releases drive state and invalidates resumable resources. It also invalidates TLS resumption tickets bound to that enrollment. Factory reset erases all enrollment and delegation records. Recovery enrollment is separate unless policy explicitly allows an existing host there.

### 6.4 Attestation

Pairing authentication is mandatory; hardware attestation is policy-dependent. When requested, attestation binds a fresh host nonce, identity key, boot identity, image security state and supported measurements. Unknown or unverifiable claims are returned as such. A simulator MUST NOT claim hardware-backed attestation. A host requiring a verified release image MUST refuse a debug or unverified image even if previously paired.

---

## 7. Authorization, presence and audit

### 7.1 Grant model

Effective authority is the intersection of device policy, paired-host grant, host-client delegation, requested session scope, current user/session state, image capabilities and resource-specific permissions. No layer may widen an upstream grant.

Each grant records an ID, principal chain, allowed methods, resource predicates, permitted users/seats/apps/file roots, expiry, lock-state policy, network exposure policy and revocation generation. Named presets are convenience expansions, not magic privileges. The device returns the expanded effective scope.

| Scope family | Examples of separately grantable authority |
| --- | --- |
| `observe` | Device information, UI tree, display capture, audio capture, logs, traces |
| `drive` | Seats, input classes, semantic actions, clipboard, platform transitions |
| `settings` | Enumerate, read, write selected keys, secret replacement |
| `apps` | Enumerate, install, launch, stop, uninstall, clear data, debug |
| `files` | Named roots with independent Read/List/Create/Update/Delete/Traverse rights |
| `exec` | Executable identities, argument constraints, startup resources and job limits |
| `network` | Endpoint forwarding, packet capture, network simulation |
| `device` | Power, updates, recovery, device simulation and driver diagnostics |
| `admin` | Grant management and specific destructive actions; never an implicit wildcard |

### 7.2 Full drive and trusted presence

Full drive means broad control within an explicit grant. It MUST NOT mint or transfer `Presence`, produce an `InteractionToken`, approve pairing, satisfy biometric authentication, dismiss a trusted authorization decision as its owner, or access protected content. LibTessera's hardware-originated interaction requirement remains unchanged.

Permission prompts and other trusted surfaces are identified as protected in observations. Synthetic input aimed at their authority-increasing controls returns `ProtectedSurface`. A developer may test those flows using explicitly simulated authorization in an isolated test realm; simulation MUST be visible and cannot grant production authority.

### 7.3 Consent and headless provisioning

The local user can see the controlling principal, revoke it, and trigger emergency stop without cooperation from the host. Unattended labs MAY provision narrow durable grants through signed owner policy. Such policy identifies the device enrollment, workload, allowed methods and expiry; it is not manufactured by a CLI `--yes` flag.

Approval challenges bind the exact operation digest, affected resources, principal, expiry and policy generation. They are single-use. Changing arguments or resources invalidates approval. Once granted within that scope, ordinary repetitive automation MUST NOT prompt for each event.

### 7.4 Audit

Audit records include principal chain, device/boot/session/operation identifiers, method, scoped target, admission decision, execution stage, outcome and timestamps. Input recording, text, file contents, credentials and screenshot pixels are excluded from default audit. Sensitive arguments are represented by type, length and a keyed digest where correlation is needed.

Audit streams are access-controlled and tamper-evident. High-rate input uses an audited sequence manifest and completion summary rather than synchronous storage per sample. Destructive or authority-changing operations MUST reserve durable audit capacity before side effects; exhaustion returns `AuditUnavailable`. Local emergency stop and revocation MUST remain available even when storage is full.

---

## 8. Transports

### 8.1 Required transport profiles

| Profile | Contract |
| --- | --- |
| `tcp-tls` | TLS 1.3 over TCP; required on host and full/headless device; ALPN `tdk/1` |
| `quic` | QUIC v1 with TLS 1.3; required on host and full device when UDP networking exists; ALPN `tdk/1` |
| `usb-bulk-tls` | TLS 1.3 over an ordered bidirectional USB bulk byte stream; required where USB device mode exists |
| `usb-network` | USB network interface carrying the same TCP/QUIC profiles; optional additional path |
| `relay` | Optional opaque byte relay carrying end-to-end device TLS; relay authorization does not replace pairing |

The TCP fallback MUST work when UDP is blocked. Downgrading transport MUST NOT downgrade authentication, encryption or authorization. No plaintext TDK mode exists. TLS 0-RTT application data is disabled for all TDK methods.

### 8.2 USB

A device publishes a dedicated vendor-specific interface with two bulk endpoints and a versioned TDK interface descriptor. Product releases publish their actual allocated USB identifiers; this specification does not assign an unowned VID/PID. Host matching uses the published descriptor and interface class information, never arbitrary serial strings alone.

The stream preserves bytes and order; USB transfer boundaries are not message boundaries. Detach, endpoint reset, alternate-setting change or role swap terminates the transport epoch and discards incomplete TLS records. Reattachment performs a fresh authenticated connection. USB device mode, charging and USB-C power/data roles remain owned by their normal services.

### 8.3 Network

The device listener uses an OS-assigned or administrator-configured port, published through discovery. It SHOULD listen only on explicitly enabled interfaces. Wi-Fi control supports IPv4 and IPv6, roaming, multiple interfaces and explicit endpoint connection. Opening a listener MUST NOT create router port mappings or expose the device to the public Internet automatically.

QUIC connection migration may preserve a transport when network addresses change, but identity, grant and session checks continue. A new TCP connection uses session resumption. Transport preference is USB, then local QUIC, then local TCP, unless the user chooses otherwise or measured health requires a different path. A transport switch MUST NOT replay mutating work.

### 8.4 Stream mapping

TCP and USB multiplex all TDK channels inside one TLS stream. QUIC uses one bidirectional stream for channel zero and one bidirectional stream per nonzero TDK channel. The first frame on a QUIC stream binds its channel ID; all subsequent frames on that stream MUST use that ID. The receiving endpoint rejects unannounced channels. TDK 1.0 media is reliable; unreliable media requires a separately negotiated extension with explicit loss and recovery semantics.

Independent QUIC streams avoid transport head-of-line blocking. TCP and USB cannot guarantee that property and MUST report their transport limitations. Small bounded frames and prioritized writes limit serialization delay.

---

## 9. Connection and session lifecycle

### 9.1 States

```text
discovered -> transport-connected -> authenticated -> negotiated
                                               -> session-active
session-active -> suspended -> resumed
session-active -> closing -> closed
any state -> failed
```

`Hello` is the first application request after TLS. It carries supported protocol minors, schema revisions, transport features, client limits and a fresh nonce. `Welcome` selects one compatible version and returns identity, boot and daemon epochs, device mode, clock samples, limits and a capability digest. Negotiation completes within 10 seconds. No domain operation is accepted before it completes.

The authenticated host then opens a session with a requested effective scope and a client delegation. A successful response returns session ID, expiry, resume policy, effective scope and policy generation. One host may open multiple isolated client sessions. A session cannot change principal or user scope in place.

`hello`, enrollment methods and `session.open/resume` are connection-scoped bootstrap methods. They use the common request envelope with `sessionId` absent; domain methods require it. Bootstrap methods have their own explicit admission rules and cannot call domain adapters. `hello` is invoked once per connection; attempts to renegotiate in place are protocol errors. `session.open` binds the delegation to a signed host assertion over `{clientPrincipal, parentGrant, requestedScope, expiry, deviceId, connectionNonce}`. The device validates the assertion under the paired host key and never accepts a claimed client principal as a substitute for the host's signature. The host remains accountable for all of its delegates.

For paired connections, the enrollment pin and current enrollment generation are the authority for the peer key. Certificate expiry and other applicable constraints are validated against trusted policy time. If required time validation is unavailable, the device returns a time-policy error rather than accepting an expired credential by guessing the date. The local enrollment/recovery flow can repair clock policy without granting an unauthenticated control session.

### 9.2 Liveness and expiry

Connections send authenticated heartbeat probes at most 2 seconds apart while active. Three unanswered probes mark the path unavailable. Drive leases use the shorter watchdog in section 14 and do not wait for connection failure detection.

Grant, resume and lease expiry use device `Boottime`, which advances during suspend. Input schedule timestamps use device `Monotonic`, which stops during suspend. A suspend invalidates active input schedules and clock synchronization even when their monotonic deadlines have not elapsed. Persisted grants across reboot are re-evaluated using trusted policy time; clock uncertainty MUST NOT extend their authority.

### 9.3 Resumption

Session resumption requires the same authenticated host and client principal, an unexpired opaque resume secret, matching device/boot/daemon epochs and current grants. Resume secrets are bound to the enrollment generation and are never sufficient without identity authentication. The default reconnect window is 30 seconds; no drive state survives the transport interruption.

Resumption restores eligible subscriptions, transfer checkpoints and operation queries. It does not reissue input, text, shell stdin or arbitrary mutations. A resumed drive session requires an explicit new lease and topology validation. Reboot or `tdkd` restart invalidates sessions and resource references; durable operation IDs can still be queried after fresh authorization.

### 9.4 Shutdown

Session close stops accepting work, cancels queued operations, releases input, closes session-owned media and forwarding, and terminates non-detached jobs. Detachment requires a separately authorized durable job with explicit lifetime and quota. Each remaining operation is reported as completed, cancelled, continuing under durable authority, or indeterminate.

---

## 10. Wire protocol

### 10.1 Framing and encoding

The 48-byte frame header is specified in Appendix A. Multi-byte header integers are unsigned little-endian. Control payloads use deterministic CBOR: definite lengths, unique text map keys, valid UTF-8, bounded nesting, no tags unless the schema explicitly defines one, and no non-finite floating-point values. Canonical signing encodings use the same deterministic rules. Raw DATA payloads are not CBOR unless their channel schema says so.

CBOR uses its own standard byte encoding; the little-endian rule applies to the fixed frame header and explicitly defined binary sample records, not to CBOR's internal encoding. Decoders MUST reject duplicate keys, malformed text, arithmetic overflow, noncanonical signed messages and lengths exceeding negotiated limits before allocation.

### 10.2 Channels and frames

Channel zero carries requests, responses, cancellation, heartbeat and channel management. Host-created nonzero channels are odd; device-created channels are even. IDs increase and are never reused within a connection. A channel is opened through `stream.open` or returned by a domain method before DATA or EVENT is sent on it.

| Frame type | Value | Meaning |
| --- | --- | --- |
| REQUEST | 1 | One control request on channel zero |
| RESPONSE | 2 | Exactly one response to a request, including an operation reference when work continues |
| EVENT | 3 | Typed subscription record on an announced event channel |
| DATA | 4 | Bytes belonging to an announced bulk, terminal or media channel |
| CREDIT | 5 | Additional byte credit for the peer's send direction on this channel |
| CLOSE | 6 | End of this channel's sending direction, with final status |
| CANCEL | 7 | Cancellation request for a correlated control request; not proof of rollback |
| PING | 8 | Channel-zero nonce and timestamp probe |
| PONG | 9 | Matching channel-zero probe response |

Frame sequence numbers are independent per direction per channel, begin at one, and increase by one for every frame. They do not wrap. Correlation IDs are nonzero for REQUEST, RESPONSE and CANCEL, and zero otherwise. Request IDs are unique within a connection. Unknown frame types or nonzero reserved bits terminate the connection with `ProtocolViolation`.

### 10.3 Flow control

DATA and EVENT consume channel byte credit equal to their payload length. Initial credit is returned when a channel opens; additional CREDIT payloads contain a positive `u64` increment. Credit is additive, bounded by negotiated windows, and checked for overflow. Credit MUST NOT be returned until the receiver has released the corresponding buffer capacity.

CREDIT, CLOSE, PING, PONG and cancellation use a separately bounded control reserve; they do not consume data credit. Requests and responses are bounded by an outstanding-request limit and a maximum control payload. Flooding control frames is a protocol error. A sender may never rely on unbounded control buffering.

Priority order is revocation/stop, lease maintenance, input, interactive control/terminal, observations, media, and bulk transfer. Weighted scheduling MUST give nonzero progress to admitted lower classes when the connection is healthy. A large transfer MUST NOT exhaust the buffers reserved for stop or input.

### 10.4 Loss and backpressure

Reliable event streams stop producers or retain a bounded replay log according to their schema. Lossy observation streams may drop old samples but MUST emit a gap record before the next retained sample. Input edges, operation terminal states and authorization changes are never silently dropped. If they cannot be delivered within bounds, the affected stream or session fails explicitly.

Compression is negotiated per data channel. Control messages and secret-bearing streams are not compressed with attacker-controlled content. Encoded and decoded sizes are both bounded. A decompression error closes the channel and cannot allocate beyond the declared decoded limit.

---

## 11. Requests, operations and consistency

### 11.1 Common request contract

Every domain request identifies `sessionId`, `method`, `params`, `timeoutNs`, and optional preconditions. Mutating requests additionally require a random 128-bit `operationId`. `timeoutNs` is a relative device-admission timeout, capped by grant and method limits; scheduled execution carries a separate device-clock timestamp. Host CLI deadlines include transport time independently.

Preconditions may include boot ID, service epoch, topology revision, settings revision, focused surface, app instance, file version or observation ID. A failed precondition has no domain side effects. A precondition is checked by the owning service at the point of mutation, not solely by the broker.

Large arguments, including timelines and transfer manifests, are uploaded as immutable, digest-verified, session-scoped argument resources before the request references them. Resource upload does not execute the contents. Validation and authorization use the resource's immutable digest as part of the operation digest. An implementation MUST NOT exceed the control-frame bound to accept a large timeline or parse an unbounded inline object.

### 11.2 Operation states

```text
accepted -> running -> succeeded
                    -> failed
                    -> cancelled
                    -> indeterminate
accepted -> cancelled
```

An operation may report progress and explicit stages, but has exactly one terminal state. `accepted` means validation, resource reservation and required journaling completed; it does not mean the action happened. Responses distinguish `received`, `accepted`, `applied`, `presented` and `durable` where those milestones exist.

### 11.3 Deduplication and retry

The deduplication key is `{enrollmentGeneration, principal, operationId}`. The journal stores the canonical method/argument digest. Reuse with different arguments returns `OperationConflict`; reuse with the same arguments returns the existing operation. The retention guarantee is advertised and MUST be at least 24 hours for durable operations. Active operations cannot be evicted. Each result returns `retainUntil`; after expiry the host MUST NOT assume a reused ID remains deduplicated.

| Operation class | Retry contract |
| --- | --- |
| Read-only | May retry after revalidating session and resource epochs |
| Transactional mutation | Owner atomically binds operation ID to commit and can answer its outcome |
| Transient input or stdin | Sequence/operation deduplication within its active epoch; never replay after reconnect |
| Irreversible external effect | Query owner outcome; return `Indeterminate` if commit cannot be established |

An adapter without an atomic journal-to-effect binding MUST NOT claim exactly-once execution. Crash between an external effect and its receipt produces an indeterminate outcome, not a fabricated failure. Clients surface uncertainty and do not retry automatically.

### 11.4 Cancellation and deadlines

Cancellation is cooperative. Before a commit point it prevents the operation; after commit it returns the committed result or an explicit `TooLate`. A timed-out caller does not imply that the device rolled back. Clients receive an operation ID early enough to query the outcome. Input cancellation additionally releases all state held by the cancelled sequence, even if earlier input was already delivered.

### 11.5 Transactions

Atomicity is confined to a declared owner transaction: settings batch, application activation, file publication, topology commit or input-frame admission. TDK does not offer a universal transaction across these services. Automation plans declare dependencies and compensating actions; compensation is a new audited operation and may itself fail.

---

## 12. Capabilities, schemas and service APIs

`capabilities.get` returns profiles, supported methods and versions, input classes, platform transitions, codecs, limits, image restrictions and current availability. Entries distinguish `supported`, `unavailable`, `denied`, and `requires-approval`, without leaking hidden resources. Capability presence does not replace authorization at execution time.

`schema.get` returns immutable, digest-addressed schemas for methods, records, settings, input descriptors and extension event types. Core schemas ship with the host so discovery is not necessary for ordinary commands. Schema fetches are bounded and MUST NOT execute supplied code, follow arbitrary external references or install plugins.

Methods use stable dotted names. A request with an unknown field is rejected unless the schema explicitly permits an extension map. Unknown response fields may be ignored; unknown enum values must be preserved and shown as unknown. Clients MUST NOT silently reinterpret an unknown platform or input class.

All native adapter interfaces use explicit-width RIDL types. Kira `Number`, native pointers, process-local handles and platform-sized integers never cross the network ABI. JSON mappings encode all `u64`, `i64`, timestamps and byte lengths as decimal strings; binary values use unpadded base64url; IDs use their specified hexadecimal form. This avoids JavaScript precision loss in MCP and SDKs.

---

## 13. Time, scheduling and barriers

### 13.1 Clock domains

Each timed record names `bootId`, `clockEpoch`, clock kind and nanosecond timestamp. Device execution and presentation use `Monotonic`. Grant/lease expiry uses `Boottime`. Realtime is metadata only and cannot order input or extend authorization. Suspend/resume, reboot and simulator clock reset advance `clockEpoch`.

`clock.sample` uses four timestamps: host send `h1`, device receive `d2`, device send `d3`, host receive `h4`. The host estimates offset as `((d2-h1)+(d3-h4))/2` and transport delay as `(h4-h1)-(d3-d2)`. The returned uncertainty includes timestamp precision, observed path variation and drift since synchronization. An estimate MUST NOT be presented as a proven hardware synchronization bound.

### 13.2 Scheduling

Sequences carry device-clock start time, relative event offsets, maximum lateness and late policy (`reject`, `drop-sequence`, or `execute-and-report`). The default is `reject`. Admission validates the complete bounded sequence and reserves queue capacity before acknowledging it. Events in one frame are applied atomically to input state; different frames execute in offset order with stable submission order for equal timestamps.

The device rejects a sequence exceeding its queue horizon or timing precision. On suspend, lease loss or topology invalidation it cancels the remaining sequence and releases its state. The host MUST NOT silently retime an already accepted sequence.

### 13.3 Barriers

`barrier.wait` takes explicit dependencies and a milestone: input dispatched, settings revision applied, app lifecycle reached, layout committed, frame presented, file durable, or stream cursor reached. It returns the actual reached milestones and their timestamps. "Idle" requires declared observable conditions and a maximum timeout; it is not an unbounded promise that the entire OS has stopped working.

Multi-device scheduling reports each device's clock uncertainty and achieved timestamp. TDK does not claim simultaneous execution when the requested tolerance is below the available uncertainty.

---

## 14. Full drive mode

### 14.1 Lease

`drive.acquire` selects user, seat, input classes, displays and sharing policy. The default is one exclusive synthetic controller per seat. The response returns lease ID, lease generation, effective scope, topology revision and expiry. An observer does not require a drive lease. Other controllers receive `Busy` with a non-sensitive owner label unless policy permits sharing.

The default lease timeout is 2 seconds, renewed at intervals of at most 500 ms. The input service checks expiry independently of `tdkd`. Revocation and local emergency stop bypass normal work queues. A host can explicitly release a lease at any time.

### 14.2 Coexistence with local input

Physical input remains distinguishable from synthetic input. Policies are `cooperative`, `yield-on-local-input`, and `exclusive-test-seat`. Cooperative mode merges physical and synthetic devices through normal routing. Yield mode cancels remote sequences and releases synthetic state when local input arrives. Exclusive-test-seat requires a dedicated authorized test seat; it never disables the system's local emergency-stop path or trusted UI.

Shared synthetic control is optional and requires an arbiter. Each controller owns distinct synthetic device instances; one cannot release another's keys or contacts. Focus-changing operations remain serialized per seat. The selected policy is visible to both the host and local user.

### 14.3 Fail-safe cleanup

Lease expiry, disconnect, principal revocation, seat removal, user switch, input-service restart, device lock where disallowed, or emergency stop MUST:

1. Stop admitting input from the old lease generation.
2. Cancel queued events and timelines.
3. Release keys and buttons, cancel contacts and composition, center axes, zero triggers, stop synthetic haptic output and remove virtual devices as appropriate.
4. Publish a termination reason and the last applied input sequence.

Cleanup MUST complete within 100 ms of the input service detecting the condition, subject to the service being scheduled. After service restart the initial synthetic state is neutral before routing resumes. A stale packet cannot revive a released lease.

### 14.4 Observation-to-action binding

Drive requests can require a particular observation, focused surface, topology and layout revision. The service validates the target immediately before routing. A stale target returns `StaleObservation` or `TopologyChanged`. Screenshot coordinates MUST NOT be blindly applied after rotation, scale change, fold transition or platform switching.

---

## 15. Input devices and events

### 15.1 Event model

Each synthetic device has a declared class, descriptor, routing scope and instance generation. Input enters MosaicDisplay's input service as synthetic HID-equivalent state, preserving DeviceKit's input model. TDK MUST NOT inject through a hardware driver to disguise provenance.

Every input frame contains lease ID/generation, synthetic device reference, sequence number, clock epoch, topology revision, target, timestamp or schedule offset, and typed events. Frames are validated in full before any state transition. Hardware-originated provenance is never assignable by a host.

| Class | Required fields and behavior |
| --- | --- |
| Touch | Stable contact ID, down/move/up/cancel, position, pressure, contact ellipse, orientation, tool kind, confidence and palm classification |
| Pen | In-range/out-of-range, hover/down/move/up, position, pressure, tilt, twist, distance, eraser and barrel buttons; unsupported axes explicitly absent |
| Touchpad | Contacts plus device-relative coordinates, click state and declared precision-touchpad descriptor; interpretation remains system policy |
| Keyboard | HID usage page and usage, down/up, repeat policy, device location and modifier state; physical keys separate from text |
| Text/IME | UTF-8 commit, composition begin/update/commit/cancel, selection and replacement ranges bound to a text-context revision |
| Mouse/pointer | Absolute or relative motion, button edges, wheel axes and high-resolution scroll phase; pointer acceleration mode declared |
| Controller | Buttons, D-pad/hat, analog sticks, triggers, calibrated axes, optional gyro/accelerometer and touch surfaces |
| Consumer/system | Media controls, volume, navigation and allowed power-button semantics using registered usages |
| Accessibility | Semantic focus, activation, text editing, scroll and value adjustment through the accessibility owner |

### 15.2 Coordinates and numeric domains

Absolute coordinates identify a display or surface and its coordinate-space revision. Logical coordinates use device-independent units with origin at the target's top-left, positive x right and positive y down before the declared transform. Physical pixel coordinates explicitly name the display mode. Normalized coordinates are finite values in `[0,1]`; mapping is to the target's continuous bounds, with edge clipping reported. Relative pointer motion uses declared device units or logical units, never an implicit pixel scale.

Pressure and triggers are `[0,1]`; centered axes are `[-1,1]`; angles name their unit and range in the descriptor. Core pen tilt is radians in `[-pi/2, pi/2]`, twist is radians in `[0,2*pi)`. NaN, infinity, invalid contact geometry and out-of-range values are rejected, not silently clamped. Device-specific dead zones, response curves and calibration are reported; clients may request raw calibrated or normal routed input, with distinct capability names.

### 15.3 Touch and multi-touch

A frame contains all changes that must be simultaneous. Contact IDs are unique among active contacts and cannot be reused before termination. Move/up of an absent contact and duplicate down are errors. Capacity overflow rejects the complete frame. The mandatory full-device synthetic touch capability supports at least 16 simultaneous contacts; the negotiated maximum may be higher.

Palm and confidence metadata follow normal input policy. Setting a flag does not force applications to accept a contact that the OS rejects. Cancel differs from up and is used for interrupted gestures. Display or segment removal cancels affected contacts unless an explicit transition operation has established a new mapping.

### 15.4 Keyboard and text

Key injection uses HID usages, not host key codes. Modifier down/up and chord order are explicit. Repeats are either generated by normal device policy or supplied explicitly; both cannot be enabled for the same held key. Lock keys are normal state transitions with resulting state observable.

Text commit is a separate operation and is never implemented by guessing keyboard layouts. Text ranges are UTF-8 byte offsets at Unicode scalar boundaries, with grapheme-safe validation where the target requires it. Composition operations bind a text context and revision; focus changes invalidate them. Password fields do not expose contents, surrounding text or composition history. Text injection into them requires an explicit secret-input grant and is never recorded in ordinary logs.

### 15.5 Mouse and controller

Absolute mouse motion and relative motion are separate event types. Raw relative mode is supported for pointer-locked applications without forcing the OS cursor to move. Scroll events include begin/update/end/cancel and precise horizontal/vertical deltas; discrete wheel steps remain available.

Controller descriptors enumerate every axis, button, hat, touch region, sensor and output effect. Analog axes remain at their last applied value until updated, explicitly neutralized, or lease cleanup occurs. Disconnect synthesizes a neutral state and device removal. Rumble, lights, adaptive triggers and pen haptics are observable output reports; forwarding them to host hardware requires a host-local output grant and hard duration/amplitude limits.

### 15.6 Raw reports and future classes

Raw HID reports are available only for a descriptor validated at device creation and a separately granted test scope. Reports are length-checked and parsed by the normal input stack; they cannot overwrite arbitrary service memory or inject trusted provenance. Core typed events remain mandatory even when raw HID is supported.

Additional input classes use versioned, schema-addressed descriptors with declared routing, units, neutral state and cleanup behavior. An unknown class is `UnsupportedInputClass`. The extension mechanism covers future spatial, accessibility and specialist controllers without pretending they are keyboard events.

---

## 16. Gestures, recording and replay

`gesture.compile` converts a declarative gesture into an inspectable input timeline. Required primitives are tap, multi-tap, long press, swipe, drag, fling, pinch, rotate, multi-contact path, chord, scroll, controller trajectory and synchronized combinations. Paths support linear and cubic Bézier segments; timing supports constant velocity and explicit easing curves. Sampling rate and interpolation are explicit and bounded by device capability.

A compiled timeline includes resolved targets, topology revision, every contact/key/button lifetime, duration, generated event count and cleanup state. Validation catches overlapping contact IDs, incomplete key releases, invalid pressure, impossible timing and queue overflow before execution. A gesture is not recompiled against a different display without caller acknowledgement.

`input.record` requires observation authority for the selected seats and event classes. Recording retains provenance, timestamps, descriptors, transforms, platform/topology changes and gaps. Secret text and trusted authorization events are redacted. Recording physical input does not make its replay hardware-originated.

Replay modes are `exact-topology`, `normalized-target`, and `semantic`. Exact mode requires matching descriptors and geometry. Normalized mode explicitly maps named targets and reports the transform. Semantic mode resolves stable accessibility identifiers and waits for declared conditions. None may silently substitute for another. Replay returns the first divergence, last applied event and any remaining held state; cleanup always follows failure.

A recording manifest includes schema versions, build identifiers, clock information, required capabilities, content digests and redaction metadata. Imported recordings are untrusted input and cannot contain executable host code.

---

## 17. Dynamic platforms and topology

### 17.1 Platform model

TDK preserves LibTessera's distinction between hardware device class, form factor and dynamic platform. Switching interaction platform does not relabel the hardware or imply a reboot.

| Dynamic platform | Required integration |
| --- | --- |
| `AdaptiveMobile` | Touch and pen, orientation, virtual keyboard, safe areas, fold/hinge segments, mobile app lifecycle and adaptive layout |
| `AdaptiveDesktop` | Multiple displays, windows, pointer/keyboard focus, relative pointer capture, desktop workspaces and scaling |
| `Console` | Controller navigation, player/seat assignment, focus, full-screen transitions, controller output and suspend behavior |
| `Media` | Directional/remote and consumer input, focus navigation, playback controls, large-screen safe areas and output routing |

Each platform supports all applicable input classes; the table identifies required platform-specific behavior, not exclusive input types. A phone may use a controller, and a console platform may receive keyboard or touch input. Capabilities report supported transitions for the actual device and image.

### 17.2 Topology descriptor

`topology.get` returns a revisioned graph of users, seats, physical/virtual displays, segments, surfaces, workspace membership, focus, scale, orientation, bounds, safe insets, occlusion, input transforms and current platform. References include generation. Protected surfaces provide redacted geometry only where policy permits.

Foldables report hinge relationships and inactive/occluded regions. Multiple displays can have different scales and rotations. Coordinates are always resolved through the returned transform graph. A topology subscription emits ordered changes and snapshot-required gaps.

### 17.3 Live switch transaction

`platform.prepare` takes target platform, expected platform/topology revision, seat scope, transition options and operation ID. The coordinator validates hardware, policy, applications and required resources, returning a plan with consequences, affected seats, reconfiguration requirements and a short expiry. Preparing has no visible platform side effect.

`platform.commit` consumes the plan once and performs:

1. Quiesce input admission on affected seats and cancel or finish active sequences according to the explicit plan policy; default is cancel and release.
2. Notify affected applications through their normal lifecycle/configuration mechanism.
3. Prepare compositor layout, focus, input routing and platform settings as one owner-coordinated transaction.
4. Commit the new platform/topology revision, or restore the old coherent state on pre-commit failure.
5. Publish the resulting platform, topology and first-presented-frame milestone, then allow newly validated input.

The switch MUST NOT restart the device, replace the TDK session, kill applications merely for convenience, or silently keep old input coordinates. Apps unable to adapt are reported with their actual lifecycle outcome. Post-commit presentation failure reports the committed revision and degraded state; it cannot claim that the old platform remained active.

Prepared plans expire after 10 seconds by default and reserve only bounded resources. A changed policy, topology, app readiness requirement or settings revision invalidates the plan before commit. Only one platform commit may execute at a time for overlapping seats. The coordinator persists the operation ID and committed platform revision atomically with its owner state. After coordinator restart it reconstructs the committed configuration or reports a recovery operation; it never exposes mixed old/new routing as a completed switch.

### 17.4 Automatic transitions and persistence

Docking, undocking, fold posture, attached displays, controller changes and policy may initiate the same transition machinery. Explicit overrides specify `session`, `until-undocked`, `until-user-change`, or `persistent` lifetime; persistent overrides require settings authority. User or safety policy may supersede an override and emits the reason.

Topology changes unrelated to a platform switch still advance topology revision. Drive leases survive only if their seat and scope remain valid, with all active contacts released and coordinates revalidated. Capture streams emit reconfiguration markers before frames in the new layout.

---

## 18. Settings

### 18.1 Registry

TDK calls settingsd directly through `tessera.tdk.settings`. It MUST NOT edit backing files or automate the Settings UI to simulate a direct operation. settingsd publishes every registered setting's stable key, type, scope, default/effective value rules, constraints, mutability, sensitivity, owner, availability and apply semantics.

Scopes include device, user, seat, display, dynamic platform and application where supported. A key can be read-only, policy-managed, unavailable, secret, or writable. "Any setting" means the API can address every registered setting and report its actual contract; it does not mean that read-only or policy-protected values become writable.

### 18.2 Reads and transactions

`settings.list` and `settings.describe` expose authorized metadata. `settings.get` returns stored value, effective value, origin, revision and pending-apply state, with secrets redacted. `settings.begin` creates a bounded transaction against a revision. `settings.stage` validates typed set/reset operations. `settings.validate` returns cross-key conflicts and application consequences. `settings.commit` is atomic within settingsd and returns committed revision plus owner-application operations.

Single-key `settings.set` is the same transaction path. Compare-and-set is mandatory. A stale expected revision returns `RevisionConflict` without partially applying the batch. Reset means restore the registered default/inheritance behavior, not write a guessed literal. Unsupported keys and values are not ignored.

### 18.3 Application and rollback

Settings classify application as immediate, asynchronous, service restart, platform transition or reboot-required. The commit receipt distinguishes stored from effective values. `settings.wait` waits for a declared effective revision. Cross-service application failure reports the stored revision and failed owners; rollback is an explicit new revision, never silent history rewriting.

Network, authentication and listener settings that may sever the controlling path use a safety transaction. It applies a candidate, starts a `Boottime` rollback timer of 30 seconds by default, and requires `settings.confirm` over a newly validated surviving path. Confirmation binds the candidate revision and principal. Without confirmation, settingsd restores the previous safe configuration and reports the rollback on reconnection. A separately approved persistent-disconnect operation may bypass this mechanism.

Secret replacement accepts write-only secret values over encrypted channels. Reads, diffs, watch events, CLI output and MCP output never reveal the stored secret. Security policy changes require their own authorization and cannot be approved through injected UI input.

---

## 19. Applications and processes

`apps.list` reports stable application identity, package version/digest, installation state, supported platforms and authorized runtime instances. `apps.inspect` provides lifecycle, resource and entitlement information within scope. Hidden applications are not leaked through errors or pagination.

### 19.1 Install and update

Installation stages a content-addressed package, verifies its manifest/signature and compatibility through the system installer, performs required AOT preparation, and atomically activates the resulting application version. TDK MUST NOT bypass Tessera's package or image verification. Development packages require the device's development policy and are visibly marked.

Progress distinguishes transfer, verification, compilation, activation and launch readiness. Cancellation before activation removes staged state according to retention policy. Once activation commits, status reports the installed version even if the reply is lost. Rollback uses the installer's supported rollback mechanism and reports data-migration limitations.

### 19.2 Lifecycle

Launch specifies app identity, arguments, permitted activation data, target user/seat/platform and explicit startup resources. It returns a generation-qualified process/app instance and optional readiness subscription. Readiness predicates are started, lifecycle foreground, surface created, first frame presented or application-declared ready.

Stop requests graceful termination with a deadline. Forced termination requires explicit permission and is reported separately. Uninstall, clear data, reset permissions and stop are distinct methods. Uninstall and data deletion require resource-specific authorization and an exact target/version precondition when requested.

Application links, document opening, notifications and background activations use typed owner APIs with normal validation. TDK MUST NOT forge an arbitrary process identity or supply another app's `System` or `Presence` startup handle.

### 19.3 Debug sessions

Process debugging requires an explicit target grant and a debug-capable app/image. Attach binds process generation, exposes only the authorized debugger channel, and reports suspension behavior. Device-process debugging and kernel debugging are different capabilities. Symbols are matched by build identity and digest; the host MUST NOT execute symbol-download hooks supplied by the device.

---

## 20. Files and transfers

### 20.1 Namespace model

Files are addressed as `{rootRef, components}`. A root reference is a session-scoped capability proxy to an authorized Namespace `Node`. Components are individual validated names; absolute paths, `..`, embedded separators, NUL and malformed encodings are rejected. Display paths are presentation metadata only.

The Namespace service resolves beneath the authorized root and prevents escape through symlinks, mount changes, rename races or object replacement. Follow-link behavior is explicit and confined to authorized roots. Rights remain independent: creation does not imply update or deletion; reading does not imply listing.

### 20.2 Operations

Required operations are roots, list, stat, read, write, create directory, rename, copy, remove, metadata, watch, push, pull and scoped tree synchronization. Listings are paginated with snapshot/revision-bound cursors. Enumeration order is stable within the snapshot. A stale cursor returns `CursorExpired` rather than silently restarting and duplicating entries.

Publication uses a temporary object in the destination scope, verifies byte count and digest, then atomically renames/replaces with an expected destination version. Overwrite and deletion are explicit. The device reports whether it reached visible or durable completion; durable completion requires the owning filesystem's synchronization contract.

### 20.3 Transfer protocol

A transfer manifest carries size, whole-content SHA-256, chunk size, per-chunk digests and metadata policy. Default chunk size is 1 MiB, negotiated between 64 KiB and 4 MiB. Transport DATA frames may split a chunk. Chunk acknowledgement means verified storage of that chunk, with durability level stated separately.

Resume identifies transfer ID, principal, root scope, target generation and verified-chunk bitmap. Resume never skips destination authorization or digest verification. Changed source content produces a new manifest. Partial files are not exposed as completed destinations. Storage exhaustion stops admission before commit and returns the retained checkpoint or cleanup result.

Tree sync first computes an inspectable plan containing creates, updates, metadata changes, deletions and conflicts. Deletions require an explicit mode. Commit uses per-object preconditions; concurrent local edits become conflicts. Cross-volume tree synchronization is not advertised as globally atomic. Case collisions, Unicode normalization differences, unsupported attributes and sparse-file handling are reported before destructive publication.

### 20.4 Host artifact safety

Device names and paths cannot select arbitrary host output locations. Pulls and archives enforce an explicit host destination root, reject traversal and symlink escape, and apply overwrite policy. Executable permission, quarantine metadata and automatic opening are host policy decisions; downloading a file never executes it.

---

## 21. Shells and execution

`exec.start` launches a named authorized executable with an argument vector, explicit startup resources, working-directory Node where supported, deadline and job limits. Native Tessera execution has no POSIX environment-variable map, `fork`, ambient root filesystem or implicit host shell expansion. A display-only working-directory hint confers no authority.

`tdk shell` opens the system's authorized native command environment or terminal service. `tdk exec -- ...` passes arguments literally. A script string is accepted only through an explicitly selected interpreter and `exec.script` authority. Compatibility runtimes, if present, are named adapters with their own declared environment and filesystem semantics; they are not the native default.

Execution returns a job reference and separate stdin, stdout and stderr channels. Terminal mode adds size, resize events, encoding and terminal-control negotiation. Non-terminal mode preserves arbitrary bytes. Half-close of stdin signals end-of-input without closing output. Process exit is a typed event containing exit status and termination reason; it is not inferred from channel closure.

Output backpressure is bounded. Policy is block the child, spool to a quota-controlled authorized artifact, or terminate with `OutputLimitExceeded`; silent truncation is forbidden. Ctrl-C requests cancellation through the job API; it MUST NOT be described as a native POSIX signal. Persistent jobs require explicit detach authority and can be listed, reattached and terminated by their owner.

---

## 22. Observation, screenshots and media streams

### 22.1 Observation bundle

`observe.snapshot` can collect topology, focus, accessibility tree, application state and display captures. It returns an observation ID, per-source revisions/timestamps, capture skew, redaction metadata and optional input/application barriers. Unless the compositor and owners support a shared barrier, the result MUST NOT claim cross-service atomicity.

Accessibility nodes expose stable identifiers where applications provide them, roles, allowed actions, bounds, state and generation. Text and values obey privacy policy. An accessibility action targets node generation and expected state, not an unvalidated selector string. Tree updates support snapshot plus ordered deltas; gaps require a fresh snapshot.

### 22.2 Screenshots

Screenshots select display, surface or region, coordinate space, scale, color policy and cursor inclusion. PNG is mandatory; raw pixels with explicit layout are available for testing. Metadata includes dimensions, pixel format, color space, transfer function, alpha mode, orientation, crop transform, topology revision, capture and presentation timestamps, and protected regions.

Capture occurs through MosaicDisplay's capture contract, including composition and authorized cursor state. Protected surfaces are redacted before pixels leave the owner. TDK cannot bypass protection by using display writeback, GPU readback or a driver path. HDR-to-SDR conversion is explicit; clients MUST NOT interpret HDR bytes as ordinary sRGB.

### 22.3 Live streams

Required stream types are display video, frame sequence, accessibility changes, input feedback, logs, traces, operation progress and terminal bytes. Audio loopback, microphone, camera and sensor streams require separate capability and privacy grants; enabling screen control does not enable them.

A stream descriptor specifies codec/profile, dimensions, frame rate/range, color format, timebase, latency mode, bitrate bounds, keyframe policy, maximum queue and adaptation policy. Full devices MUST provide a lossless image-frame fallback; compressed video codecs are negotiated, with H.264 and AV1 supported where the system codec stack exposes them. A codec name alone is insufficient: profile, level and format compatibility are mandatory.

Each video frame identifies stream generation, frame ID, dependencies, capture/presentation timestamps, topology revision, damage region and keyframe status. Decoder configuration precedes frames that require it. Reconfiguration, rotation and platform changes emit an ordered discontinuity and fresh configuration/keyframe before the new format.

Interactive mode drops obsolete undecoded frames at safe codec boundaries, reports drops and requests a keyframe when needed. Recording mode prioritizes completeness and stops with an explicit limit error if it cannot keep up. Slow readers MUST NOT stall the compositor or retain unlimited GPU buffers. Capture buffers are released using fences and bounded lifetimes.

### 22.4 Clipboard and privacy

Clipboard read and write are separate scopes, scoped to a user/seat and declared MIME types. Rich formats are size-limited and sanitized by the owning service. Clipboard synchronization is off by default and cannot continuously bridge users or principals without a specific grant. Secret/managed clipboard restrictions remain enforced.

---

## 23. Logs, tracing, profiling and debugging

`logs.read` and `logs.follow` support subsystem, category, severity, process/app identity, boot, time range and cursor filters. Entries preserve device monotonic timestamps, structured fields, privacy classification and source sequence. Ring overrun emits explicit lost ranges. A reconnect cursor is scoped to the source epoch and cannot imply continuity across a reboot.

`trace.start/stop` configure authorized sources, buffers, duration and trigger conditions through the trace service. Export uses Tarwin's Perfetto trace format with clock correlation and lost-event counters. System-wide profiling requires the relevant debug authority; per-app profiling remains target-scoped. Collection overhead and buffer consumption are reported.

`crash.list/export` returns authorized application crashes, kernel panic records and boot diagnostics. Tarwin's retained panic record is bounded by its kernel contract; TDK does not claim that a full memory dump exists on release images. Private memory and secrets are redacted according to the producer's policy.

Device inspection exposes DeviceKit registry snapshots, driver identities, lifecycle, health and restart history through the manager. Driver restart and fault injection require explicit testing authority and cannot evade DeviceKit's ownership rules. Normal observation does not acquire MMIO or DMA capabilities.

Debugger channels support protocol adapters such as DAP on the host and the target's debugger transport. Kernel GDB-remote forwarding exists only on debug images with Tarwin's debugger enabled and explicitly authorized. Release images return `UnavailableOnImage`; no fallback may create equivalent unrestricted kernel access.

Support bundles are manifest-based, scoped and size-limited. The manifest identifies included sources, time ranges, redactions and digests before export. Bundling MUST NOT silently include all app containers, microphone data or credentials.

---

## 24. Network, peripherals and simulation

### 24.1 Forwarding

`network.forward` and `network.reverse` create authenticated, session-owned tunnels to explicit device or host endpoints. The grant binds direction, protocol, address scope, port/service identity and lifetime. Host listeners bind loopback by default. Non-loopback binding requires explicit host policy and caller authorization.

Forwarding to arbitrary host services is not implied by device control. DNS rebinding and address changes are revalidated against scope. Tunnel close, half-close, backpressure and byte quotas are observable. Reverse tunnels cannot access the broker's control socket, key store or unrelated user sessions.

### 24.2 Network diagnostics

The network service provides link state, addresses, routes, resolver diagnostics and bounded connectivity tests within scope. Packet capture, traffic shaping, loss/delay simulation and Wi-Fi changes are distinct grants. Captures are privacy-sensitive artifacts. Disruptive changes use the safety-transaction mechanism where appropriate.

### 24.3 Event and peripheral simulation

Testing adapters MAY expose schema-defined battery, thermal, sensor, location, hinge/lid, network, notification, telephony, NFC, USB and accessory events when the owning service supports simulation. Each event reports whether it changes a real service, an isolated test realm, or a purely virtual device. A simulated call or payment event MUST NOT trigger a real external effect unless a separate explicitly authorized operation requests it.

There is no untyped "send any kernel event" operation. `events.describe` enumerates registered event schemas, scope, ordering, acknowledgement and cleanup behavior; `events.emit` accepts only these schemas. This gives extensible coverage without accepting arbitrary IPC bytes or forging hardware/authentication provenance.

Virtual devices are owned by a session or explicit durable test job. They identify themselves as synthetic, have bounded resources and disappear or reset on owner loss. Sensor injection preserves unit, sample rate, range, clock and calibration metadata and cannot bypass the sensor service's application permissions.

---

## 25. Power, updates, recovery and boot

Power operations distinguish wake request, display wake, suspend, reboot, soft reboot, shutdown and recovery entry. They return an operation ID and expected identity/boot transition before disconnect where possible. A disconnect alone is not evidence that reboot succeeded. `device.wait` observes the authenticated identity and required boot/mode milestone.

Wake locks are explicit, time-limited resources with reason, owner and maximum duration. Streaming or connection liveness MUST NOT silently hold the device awake indefinitely. Thermal policy may reduce capture rate, encoding quality or test workload; the device reports degradation. TDK cannot disable safety shutdown or exceed thermal limits through drive authority.

Updates are submitted to the system update service, which verifies boot sets, inactive-slot preparation and compatibility, including DeviceKit's driver API window. TDK reports staging, verification, activation, reboot, health confirmation and rollback. It does not write arbitrary live partitions as a substitute for the update contract.

Recovery exposes its own capability set and authentication policy. Repair, reinstall and erase require exact target identification and the recovery service's credential/owner approval. A broad session grant is not implicit authority to erase the device. Recovery cannot export protected user data merely because normal boot failed.

Early boot and panic diagnostics may use a separately specified limited transport. They MUST identify their authentication/confidentiality level and MUST NOT silently inherit full TDK trust. Production TDK never falls back to an unauthenticated emergency shell.

---

## 26. Host daemon and SDK

### 26.1 Local broker

`tdk-hostd` runs per user by default. Its local endpoint is a protected Unix-domain socket, named pipe, or equivalent authenticated local channel. Peer credentials and a scoped client session bind requests to their caller. Filesystem permissions alone are insufficient when the host platform supplies stronger peer identity. A system-wide broker requires explicit administration and separate per-user stores and policies.

Keys use the host's secure credential store where available. Configuration, enrollment records, journals, artifacts and caches have distinct retention policies. Secrets never appear in diagnostic bundles. A second broker instance must rendezvous with the existing owner or fail cleanly; it cannot corrupt shared trust state.

Local clients receive only device/session/resource references within their delegation. An MCP client cannot enumerate another client's captures, inherit its drive lease or attach to its terminal. Broker restart invalidates local client sessions; device operations are reconciled through their IDs, not replayed.

### 26.2 SDK

The host SDK exposes typed asynchronous methods, cancellation, operation handles, subscriptions, binary streams and structured errors. Generated bindings preserve explicit-width values and unknown fields. Convenience helpers for gestures and waits use the same normative methods as the CLI; no private more-privileged SDK path exists.

SDK clients can inspect effective scope, topology, capabilities and planned mutations before execution. They distinguish transport failure, operation failure and indeterminate outcome. SDK retry middleware retries only methods whose declared class permits it.

---

## 27. Command-line interface

### 27.1 Grammar

```text
tdk [global-options] <group> <command> [command-options]
tdk -s <device-id-or-alias> <command> ...
tdk --devices <explicit-selector> <command> ...
```

Global options include `--device/-s`, `--transport`, `--timeout`, `--json`, `--jsonl`, `--non-interactive`, `--session`, and `--profile`. Structured input accepts a file or stdin with a declared schema. Secrets use protected prompts/input descriptors. Argument parsing never invokes a host shell implicitly.

| Group | Required commands |
| --- | --- |
| Discovery | `devices`, `discover`, `connect`, `disconnect`, `wait-for-device` |
| Trust | `pair`, `unpair`, `trust list`, `trust inspect`, `trust revoke` |
| Introspection | `info`, `capabilities`, `schema`, `doctor` |
| Sessions | `session open/list/inspect/close`, `grant inspect` |
| Drive | `drive start/status/stop`, `input devices/send/release`, `gesture compile/run`, `record`, `replay` |
| Platform | `platform list/get/plan/set/watch`, `topology get/watch` |
| Settings | `settings list/describe/get/set/reset/transaction/watch/confirm` |
| Applications | `apps list/inspect`, `install`, `uninstall`, `launch`, `stop`, `apps clear-data` |
| Files | `files roots/ls/stat/mkdir/mv/cp/rm/watch`, `push`, `pull`, `sync` |
| Execution | `shell`, `exec`, `jobs list/attach/stop` |
| Observation | `observe`, `screenshot`, `screen stream/record`, `ui tree/action/watch`, `clipboard get/set` |
| Diagnostics | `logs`, `trace`, `profile`, `crash`, `debug`, `bugreport`, `devices inspect` |
| Network/testing | `forward`, `reverse`, `network`, `events`, `simulate` |
| Lifecycle | `power`, `reboot`, `update`, `recovery` |
| Host | `server start/status/stop`, `mcp serve`, `artifact list/export/delete` |
| Automation | `run`, `operations get/watch/cancel`, `barrier` |

### 27.2 Output and exit behavior

Human output goes to stdout; progress and diagnostics go to stderr. `--json` emits exactly one versioned result envelope for finite commands. `--jsonl` emits one envelope per record for streams, ending with a terminal record when termination is orderly. Raw binary output is only enabled by an explicit output mode and cannot be mixed with JSON or progress.

| Exit code | Meaning |
| --- | --- |
| 0 | Requested operation reached its requested success milestone |
| 1 | Operation failed |
| 2 | Invalid arguments or schema |
| 3 | Device missing, ambiguous or selection failed |
| 4 | Authentication/authorization/approval failure |
| 5 | Transport unavailable or disconnected before a known outcome |
| 6 | Deadline exceeded |
| 7 | Cancelled |
| 8 | Partial fleet result or indeterminate operation outcome |

`exec` returns the wrapper's result envelope containing the child's exit code; `--propagate-exit` may propagate a representable child exit code, with transport failures still distinguishable through stderr/JSON. Noninteractive mode never waits indefinitely for approval; it returns a structured pending-approval result and challenge reference. An affirmative CLI flag cannot create device-side consent.

### 27.3 Examples (informative)

```text
tdk devices --json
tdk -s lab-phone drive start --seat main
tdk -s lab-phone input send --file input-frames.json
tdk -s lab-phone platform set AdaptiveDesktop --wait presented
tdk -s lab-phone settings set display.brightness --value 0.6 --if-revision 42
tdk -s lab-phone screenshot --output capture.png
tdk -s lab-phone exec -- tool-name argument
tdk mcp serve --transport stdio
tdk mcp serve --transport http --listen 127.0.0.1:0
```

The setting key and executable in these examples are illustrative; actual keys and executable identities come from their registries.

---

## 28. MCP server

### 28.1 Protocol and transports

The host provides an MCP server over stdio and Streamable HTTP. MCP protocol version `2025-06-18` is the mandatory baseline interoperability profile; later revisions may be negotiated only when implemented and tested. The release manifest pins the MCP schemas and authorization profile it implements. TDK's device wire protocol is independent of MCP versioning.

Stdio uses the MCP-defined framing on stdin/stdout. Stdout contains only MCP protocol messages; diagnostics go to stderr. EOF closes that caller's session and releases its transient resources. The MCP server MUST NOT spawn a shell to interpret tool arguments.

Streamable HTTP exposes a configured `/mcp` endpoint, supports the baseline request/response and server-event behavior, and binds MCP session IDs to an authenticated principal. Session IDs are routing identifiers, not bearer authorization. Disconnect/reconnect, event resumption and expiry follow the negotiated MCP revision without replaying tools.

### 28.2 Network security

The default HTTP listener is loopback on an ephemeral port with authenticated access. Non-loopback service requires explicit configuration, TLS and per-caller authentication. Remote deployments implement the negotiated MCP authorization profile using protected-resource metadata, audience-bound access tokens and authorization-code flow with PKCE where interactive authorization is used. Provisioned machine clients may use separately issued, short-lived audience-bound credentials.

The server validates token issuer, audience, expiry and scope, validates `Origin` where present, rejects disallowed origins, and protects against DNS rebinding through allowed-host validation. A missing Origin is not authentication. Reverse-proxy identity is trusted only from an explicitly configured authenticated proxy. Untrusted forwarding headers cannot select a caller identity.

### 28.3 Delegation

Every MCP connection maps to a host client principal and an explicit subset of devices, operations and resources. The broker sends that delegation to the device; the device intersects it with its paired-host grant. A network caller cannot inherit all authority possessed by `tdk-hostd` simply because the host is paired.

Device labels, screen text, logs, accessibility contents, application messages and files are untrusted tool data. They cannot modify MCP server policy, tool definitions, grants or approval decisions. A tool result containing instructions is still data.

### 28.4 Tool surface

Tools are typed and grouped by domain. Required discoverable tools include `tdk_devices`, `tdk_capabilities`, `tdk_session_open`, `tdk_observe`, `tdk_drive_acquire`, `tdk_input_send`, `tdk_gesture_run`, `tdk_platform_prepare`, `tdk_platform_commit`, `tdk_settings_get`, `tdk_settings_set`, `tdk_apps`, `tdk_files`, `tdk_exec`, `tdk_logs`, `tdk_operation_get`, `tdk_operation_cancel`, and `tdk_drive_release`.

Domain tools such as `tdk_apps` use a closed discriminated action schema, not an arbitrary shell command. Additional catalogue methods are exposed through generated typed tools or a schema-validated domain dispatch tool. No unrestricted `call_any_service`, raw kernel call or host-shell fallback is permitted.

Tool annotations identify read-only, destructive, idempotent and open-world behavior accurately; annotations are hints for clients, never authorization. Every tool returns structured content with operation status, device identity, revisions, error or result, and references to large artifacts. A tool call that starts long work returns an operation reference promptly; clients use progress notifications where negotiated and polling otherwise.

### 28.5 Resources and media

Resource URIs use opaque IDs, for example `tdk://device/<id>/artifact/<artifact-id>`. Resolution checks the current caller, grant, device, artifact owner and expiry. URIs cannot expose host paths or act as ambient bearer tokens. Downloads through HTTP use separately scoped short-lived authenticated endpoints and bounded ranges; URLs are redacted from logs when they contain credentials.

Small screenshots may be returned as MCP image content. Large recordings, traces and files are resource references with MIME type, size, digest and expiry. Continuous video is not encoded as an unbounded JSON array or base64 stream of tool results; MCP returns a stream descriptor and authenticated host media resource, with frame-sampling tools as a fallback.

### 28.6 Approval and cancellation

MCP may report an approval challenge and, where supported, collect an explicit client response. Such a response does not satisfy device-local physical presence unless device policy separately authorizes that principal and action. Tool cancellation requests operation cancellation; it does not erase a committed setting or uninstall. MCP session termination releases drive state and transient resources according to the same device rules as CLI termination.

---

## 29. Automation and multi-device orchestration

An automation plan is a versioned declarative graph of typed calls, dependencies, waits, assertions, artifact captures, timeouts and optional compensations. It is not arbitrary executable host code. Validation resolves devices to fixed identities, checks schemas and required scopes, and reports unavailable capabilities before execution.

Actions target named resources and may bind observation, topology, app and settings revisions. Waits use subscriptions and predicates rather than mandatory fixed sleeps. Each action has an operation ID derived from a run ID and stable action identity; retries obey the operation class. A resumed run queries previous outcomes before dispatching dependent work.

Fleet execution supports bounded concurrency, per-device results, fail-fast or continue policy, and scheduled starts with reported clock uncertainty. There is no cross-device atomic commit. Partial completion is first-class. Loss of one device cannot cause work to move to an unintended replacement.

Artifacts include a run manifest, device/build identities, capability digests, effective scopes, action outcomes, timing, gaps and redactions. Secret parameters are supplied through scoped secret inputs and excluded from exported plans. Replay and test reports distinguish observed results from assumptions or skipped capabilities.

---

## 30. Resource limits and performance

### 30.1 Mandatory bounded limits

Limits are negotiated as the minimum of peer limits and policy. Lower values are allowed only for explicitly declared recovery/constrained profiles or temporary resource pressure, which must be visible before admission.

| Resource | Full-device baseline |
| --- | --- |
| Frame payload | Default 64 KiB; negotiated maximum 1 MiB |
| Control payload | At most 64 KiB; large schemas/results use paginated resources or data channels |
| CBOR nesting | At most 32 levels |
| Outstanding requests | At least 64 supported; negotiated hard cap |
| Concurrent data/event channels | At least 32 supported; per-principal quotas |
| Input contacts | At least 16 per synthetic touch device |
| Input schedule horizon | At least 5 seconds supported; default maximum 30 seconds |
| Input frame rate | At least 240 frames/s supported for bounded touch/pointer/controller frames |
| Queued input | At least 4,096 events; explicit negotiated byte and event caps |
| Default session data buffering | At most 32 MiB, excluding explicitly reserved recording/transfer storage |
| Default interactive video queue | At most 3 decoded-frame equivalents; codec reference surfaces counted separately |
| Artifact/transfer/journal storage | Explicit per-principal and global byte quotas; no unbounded retention |

Limits must account for decoded data, queued control work, handles, GPU buffers, encoder surfaces, subscriptions and durable storage, not only wire bytes. Admission failure is explicit and leaves no partial input frame or half-created resource.

### 30.2 Performance gates

Performance is measured on published reference devices and hosts, with build, transport, network conditions, workload, power mode and thermal state recorded. These are release gates, not claims about every network or device.

| Measurement | Gate |
| --- | --- |
| Device input admission to input-service dispatch, no intentional scheduling delay | p95 ≤ 2 ms, p99 ≤ 5 ms under concurrent bulk transfer |
| Lease cleanup after watchdog detection | ≤ 100 ms |
| Healthy local USB command round trip, excluding domain work | p95 ≤ 10 ms |
| Healthy local Wi-Fi command round trip, excluding domain work | p95 ≤ 20 ms under the published reference network |
| 1080p60 interactive capture, where hardware codec capability is advertised | p95 capture-to-host-decode ≤ 100 ms on reference USB and Wi-Fi conditions |
| Large-file transfer | ≥ 80% of the authenticated transport's separately measured sustainable throughput when no higher-priority workload competes |
| Idle paired connection | No continuous polling of UI, no implicit wake lock, measured CPU/wakeup budget published |

Tests report distributions, drops, scheduling lateness and steady-state memory. A throughput result cannot hide starving input or unbounded buffering. Thermal degradation is reported and tested; a device never violates safety policy to meet a benchmark.

---

## 31. Failures and diagnostics

Errors have stable `code`, `domain`, `message`, `retryClass`, optional `operationId`, `auditRef`, structured details and the last known execution milestone. Messages are explanatory text, not fields clients must parse.

| Code | Meaning / required handling |
| --- | --- |
| `InvalidArgument`, `SchemaMismatch` | Rejected before domain side effects |
| `UnsupportedMethod`, `UnsupportedInputClass` | Protocol feature absent; no silent substitute |
| `UnavailableInMode`, `UnavailableOnImage` | Capability exists but current mode/image cannot provide it |
| `NotPaired`, `AuthenticationFailed`, `IdentityConflict` | Stop authenticated work; require trust resolution |
| `Denied`, `ApprovalRequired`, `GrantExpired`, `Revoked` | Authority insufficient or ended |
| `ProtectedSurface`, `ProtectedContent`, `SecretRedacted` | Protected boundary enforced |
| `NoDevice`, `AmbiguousDevice`, `DeviceDisconnected` | Device selection or path failure |
| `Busy`, `LeaseLost`, `SeatRemoved` | Control ownership invalid; neutralize old input |
| `TopologyChanged`, `StaleObservation`, `RevisionConflict` | Reobserve/replan before mutation |
| `ResourceExpired`, `ServiceRestarted`, `BootChanged` | Reference epoch invalid; reacquire explicitly |
| `QueueFull`, `QuotaExceeded`, `OutputLimitExceeded`, `StorageFull` | Bounded resource exhausted |
| `DeadlineExceeded`, `TooLate`, `Cancelled` | Query operation outcome where side effects may already exist |
| `OperationConflict`, `Indeterminate` | Do not retry with guessed new identity |
| `Gap`, `CursorExpired`, `StreamDiscontinuity` | Reestablish observation continuity |
| `IntegrityFailure`, `ProtocolViolation`, `AuditUnavailable` | Stop affected work and retain safe diagnostics |

`tdk doctor` reports discovery, endpoint reachability, TLS identity, version negotiation, authorization, service health and transport statistics as separate checks. It MUST NOT "repair" trust by accepting a new fingerprint or enabling an insecure transport. Diagnostics include correlation IDs and bounded context, not secrets.

---

## 32. Security requirements

### 32.1 Threat model

Implementations assume hostile local networks, malicious discovery packets, untrusted connected devices, compromised applications, untrusted MCP tool output, malformed media and HID descriptors, interrupted transports and concurrent users. A compromised authorized host can exercise its grants; TDK limits and audits that authority but cannot turn an authorized arbitrary-execution grant into a safe observer grant.

### 32.2 Required controls

1. Mutual authenticated encryption after pairing; no trust-on-first-use for a remotely discovered device.
2. No early-data mutations, unchecked replay, cross-session resource reuse or privilege widening through transport changes.
3. Parser limits before allocation, fuzzed CBOR/frame/HID/media/manifest decoders, checked arithmetic and bounded queues.
4. Independent service-side authority checks and immediate revocation generation validation.
5. Protected host IPC, per-client delegation and no ambient access to broker keys or artifacts.
6. Secrets excluded from arguments printed in diagnostics, audit payloads, recordings and MCP resources.
7. Physical presence and protected-content boundaries preserved on every input/capture/debug path.
8. Rate limits on discovery, pairing, authentication, approval requests, resource creation and expensive diagnostics.
9. Explicit authorization for non-loopback host listeners, reverse forwarding, destructive operations and durable unattended jobs.
10. Fail-safe neutral input and bounded cleanup on every failure path.

### 32.3 Revocation races

Admission and final commit both check current authority. Revocation wins over queued work that has not committed. A committed irreversible effect remains in the audit and is reported; revocation cannot rewrite history. Long-running streams check revocation without waiting for a new request and stop producing protected data immediately after the owning service processes it.

### 32.4 Locked devices and users

Lock state is a policy input, not an authentication substitute. Default grants pause drive, UI capture and user-data access when the target user locks or switches. A separately provisioned lab grant may allow selected locked-state diagnostics, but never exports user credentials or biometric material. A session bound to one user cannot follow a different user after switching.

---

## 33. Versioning and compatibility

The network protocol uses independent major/minor versions. Major changes may alter framing or incompatible semantics; minor changes are additive and negotiated. Service API versions use `YY.M`; capabilities identify exact supported method and schema revisions. TDK versioning does not alter DeviceKit's twelve-month Driver API window or LibTessera's ABI rules.

Core method names and field meanings are never repurposed. A changed shape requiring different semantics receives a new method/schema revision. A release supports the current and previous protocol major for at least twelve months after a new major ships, unless a documented security defect requires disabling a vulnerable profile. Security removals fail explicitly; they never silently fall back to insecure behavior.

Extensions use reverse-domain names, immutable schema digests, negotiated versions, declared limits and security scopes. Experimental extensions cannot masquerade as core conformance. A host can inspect unknown extension metadata without executing it.

---

## 34. Conformance

### 34.1 Required suites

| Suite | Required cases |
| --- | --- |
| Wire | Fragmented/coalesced frames, endian vectors, CBOR canonicalization, duplicate keys, invalid lengths, overflow, unknown bits, sequence errors and fuzzing |
| Authentication | QR pinning, wrong keys, replayed enrollment, expired secret, key rotation, revoked TLS tickets, MITM and identity collision |
| Authorization | Scope intersection, principal isolation, lock/user switch, approval digest binding, revocation at admission/commit and protected presence |
| Transport | USB detach/reset, TCP half-close, QUIC migration, UDP blocked fallback, IPv6 scope, Wi-Fi roam and relay trust |
| Operations | Duplicate same/different payload, crash before/after commit, lost response, journal expiry, cancellation and indeterminate outcomes |
| Input | Every typed class, 16-contact frames, pen hover/pressure, text/IME, key repeat, pointer lock, analog controller state, output reports and neutral cleanup |
| Drive | Competing controllers, local input policies, emergency stop, daemon/input-service crash, lease expiry and reconnect without replay |
| Platforms | All advertised transitions among four platforms, fold/rotation/dock/multi-display, focus changes, rollback and active capture/input |
| Settings | Typed schema, CAS, batch atomicity, secret redaction, async apply, reboot-required state and connectivity rollback |
| Apps/files/exec | Install verification, AOT failure, activation replay, path/symlink races, partial transfer, digest failure, disk full, literal argv and terminal backpressure |
| Media | Protected layers, HDR metadata, orientation, codec change, keyframe recovery, slow consumer, capture skew and bounded GPU retention |
| Diagnostics | Log gaps, trace clocks, privacy filters, debug-image restrictions and bounded support bundles |
| MCP | Baseline protocol conformance, clean stdio, HTTP auth/origin/host checks, session isolation, cancellation, artifact access and untrusted tool content |
| Fleet | Ambiguous selection, identity pinning, partial completion, clock uncertainty and no cross-device command redirection |
| Recovery | Separate policy, verified repair, destructive approval, boot change and no plaintext fallback |

### 34.2 Execution matrix

Suites run against simulator and real hardware for each supported transport and architecture. Full-device conformance includes the four platform contracts even when individual physical configurations make some transitions unavailable; transition capability declarations must be tested against actual supported configurations. Release and debug images are tested separately.

Fault injection covers every durable commit boundary, stream reconfiguration, service restart, grant revocation and topology transition. Security tests include malicious device-to-host names, archives, schemas, media and log content. Tests verify the absence of secret leakage in stderr, journals, artifacts and MCP responses.

A release publishes supported profiles, tested matrix, limits, performance distributions and known exclusions. A skipped mandatory software feature blocks the corresponding profile claim. Passing an emulator test alone does not establish physical-device latency or recovery correctness.

---

## 35. Delivery gates

This section defines acceptance order, not permission to ship a partial implementation as complete TDK.

| Gate | Exit condition |
| --- | --- |
| T0: contracts | RIDL schemas, wire vectors, method registry, error catalogue and threat model agree with this specification |
| T1: secure connection | USB/TCP/QUIC, discovery, pairing, mutual authentication, grants and multi-device identity tests pass |
| T2: operation core | Journaling, cancellation, reconnect, scoped resources, quotas and audit tests pass |
| T3: full drive | Every input class, gestures, observations, watchdog cleanup and all platform contracts pass |
| T4: system management | settingsd, apps, files, execution, diagnostics, forwarding, power and recovery contracts pass |
| T5: host and agents | CLI/SDK parity, stdio and HTTP MCP, principal isolation and automation plans pass |
| T6: release | Hardware fault matrix, performance gates, privacy/security suites and compatibility publication pass |

No gate authorizes bypassing platform security to make the next gate easier. Recovery and debug-only features remain explicitly marked in the release manifest.

---

## 36. Appendix A: wire layouts and common schemas

### A.1 Frame header

| Offset | Type | Field |
| --- | --- | --- |
| 0 | `u8[4]` | Magic ASCII `TDK1` |
| 4 | `u16` | Protocol major, 1 |
| 6 | `u16` | Selected minor, 0 for this specification |
| 8 | `u16` | Frame type from section 10 |
| 10 | `u16` | Flags, zero in version 1.0 |
| 12 | `u32` | Header bytes, exactly 48 in version 1.0 |
| 16 | `u32` | Payload bytes, checked against type and channel limits |
| 20 | `u32` | Reserved, zero |
| 24 | `u64` | Channel ID |
| 32 | `u64` | Per-direction, per-channel frame sequence |
| 40 | `u64` | Correlation ID, or zero |

The header is authenticated by TLS/QUIC; no independent CRC is required. Before version negotiation completes, the header uses major 1/minor 0 and only Hello/Welcome/error traffic is legal. Version mismatch closes cleanly with no domain dispatch.

### A.2 Common types

```text
Id128          = 16 random bytes; JSON: 32 lowercase hex characters
Identity       = 32-byte SHA-256 digest; JSON: 64 lowercase hex characters
Digest         = { algorithm: "sha256", value: bytes[32] }
ResourceRef    = { id: Id128, kind: text, epoch: Id128 }
Timestamp      = { bootId: Id128, clockEpoch: Id128,
                   clock: "monotonic" | "boottime" | "realtime", ns: u64 }
Preconditions  = optional named revisions/references defined by the method
Request        = { sessionId: Id128, method: text, params: map,
                   timeoutNs: u64, operationId?: Id128,
                   preconditions?: Preconditions }
Response       = { status: "ok" | "accepted" | "error",
                   result?: map, operation?: Operation, error?: Error }
Operation      = { id: Id128, state: text, stage: text,
                   milestone: text, retainUntil?: Timestamp,
                   result?: map, error?: Error }
Error          = { code: text, domain: text, message: text,
                   retryClass: "never" | "read" | "same-operation" | "reobserve",
                   operationId?: Id128, auditRef?: text, details?: map }
Event          = { subscriptionId: Id128, cursor: text, kind: text,
                   timestamp: Timestamp, revision?: u64, data: map }
Gap            = { firstMissing?: text, lastMissing?: text,
                   count?: u64, reason: text, requiresSnapshot: bool }
Page           = { items: array, snapshot: text, nextCursor?: text }
```

`Response.status=error` requires `error` and forbids a success result. `accepted` requires an operation reference. An `ok` response may contain a terminal operation. Optional fields are absent, not ambiguous nulls. Resource IDs are not bearer capabilities: every dereference checks the current principal and grant.

### A.3 Channel records

```text
ChannelOpen = { channelId: u64, kind: text, schema: Digest,
                initialSendCredit: u64, initialReceiveCredit: u64,
                maxFrameBytes: u32, maxDecodedBytes: u32,
                lossPolicy: "lossless" | "drop-oldest", metadata: map }
Credit      = { bytes: u64 }
Close       = { status: "complete" | "cancelled" | "error",
                finalSequence: u64, error?: Error }
Ping        = { nonce: bytes[16], sent: Timestamp }
Pong        = { nonce: bytes[16], received: Timestamp, sent: Timestamp }
```

Credit directions are defined from the channel creator's perspective and echoed in the open response. CREDIT grants the receiver of that frame additional sending capacity. CLOSE ends only the sender's direction; both directions must close before resource reclamation unless an error aborts the channel. `finalSequence` equals the CLOSE frame's own sequence. Closed directions reject subsequent DATA/EVENT.

### A.4 Input frame

```text
InputFrame = { leaseId: Id128, leaseGeneration: u64,
               device: ResourceRef, sequence: u64,
               topologyRevision: u64, clockEpoch: Id128,
               target: ResourceRef, atMonotonicNs?: u64,
               maxLatenessNs: u64, events: array<TypedInputEvent> }
InputReceipt = { sequence: u64,
                 stage: "accepted" | "dispatched" | "cancelled",
                 timestamp: Timestamp, topologyRevision: u64,
                 disposition: "on-time" | "late" | "rejected",
                 error?: Error }
```

Typed event discriminators are `touch`, `pen`, `touchpad`, `key`, `text`, `composition`, `pointer`, `scroll`, `controller`, `consumer`, and `accessibility`. Each event uses the fields and ranges of section 15. The published core schema MUST fully enumerate fields for every discriminator; no unconstrained event payload is allowed.

#### A.4.1 Common event fields

The following notation defines record fields, not executable code. `f64` values are finite CBOR floating-point values encoded in their shortest exact representation; unit/range constraints still apply. Omitted optional axes mean unavailable, not zero. A target's coordinate space is fixed by `{kind, target, revision}` where `kind` is `logical`, `physical-pixel`, `normalized`, or `device-relative`. Absolute events additionally carry `{x: f64, y: f64}`. Mixing spaces inside one synthetic device's contact lifetime is invalid.

```text
Usage       = { page: u16, usage: u16 }
Position    = { space: text, target: ResourceRef, revision: u64,
                x: f64, y: f64 }
AxisValue   = { axis: u16, value: f64 }
ButtonEdge  = { button: u16, state: "down" | "up" }
TextRange   = { startByte: u32, endByte: u32 }
```

`TextRange` is half-open and requires `startByte <= endByte`; offsets must be valid boundaries in the associated text-context revision. Every event has a `kind` discriminator. The fields below are in addition to that discriminator. Unknown fields are rejected except in a declared versioned extension record.

| Kind | Required fields | Optional fields / constraints |
| --- | --- | --- |
| `touch` | `contactId: u32`, `phase: down/move/up/cancel` | `position` required for down/move and optional for up; `pressure: f64`, `major: f64`, `minor: f64`, `orientationRad: f64`, `tool: finger/palm`, `confidence: bool`; major/minor are nonnegative lengths in the position's space |
| `pen` | `phase: enter/hover/down/move/up/leave/cancel` | Position required except leave/cancel; `pressure`, `tiltXRad`, `tiltYRad`, `twistRad`, `distance`, `eraser: bool`, `buttons: array<ButtonEdge>`; distance is nonnegative in descriptor units |
| `touchpad` | `contacts: array<TouchpadContact>`, `buttons: array<ButtonEdge>` | Each contact has contactId, phase and device-relative x/y; optional pressure and contact geometry; the descriptor defines physical dimensions and units |
| `key` | `usage: Usage`, `state: down/up/repeat` | `location: standard/left/right/numpad`, `repeatMode: system/explicit`; repeat requires an already-held key and explicit mode |
| `text` | `context: ResourceRef`, `contextRevision: u64`, `utf8: text` | `replace: TextRange`; omission inserts at the current validated selection |
| `composition` | `context: ResourceRef`, `contextRevision: u64`, `compositionId: Id128`, `phase: begin/update/commit/cancel` | Begin/update require UTF-8 text and selection within it; optional replacement range; commit may provide final text, otherwise commits the last composition; cancel carries no text |
| `pointer` | `mode: absolute/relative`, `buttons: array<ButtonEdge>` | Absolute requires position; relative requires `dx`, `dy` and `units: device/logical`; `acceleration: normal/raw`; empty motion with button edges is allowed |
| `scroll` | `phase: begin/update/end/cancel`, `dx: f64`, `dy: f64`, `units: logical/line/page/detent` | `momentum: bool`; target is the frame target; axis sign and unit conversion follow the published device descriptor |
| `controller` | `buttons: array<ButtonEdge>`, `axes: array<AxisValue>`, `hats: array<HatValue>` | Optional typed sensor/touch records declared by the descriptor; duplicate axis/button/hat entries in one event are invalid |
| `consumer` | `usage: Usage`, `state: down/up` | Only declared consumer/system usages; destructive power actions retain their separate policy |
| `accessibility` | `node: ResourceRef`, `treeRevision: u64`, `action: activate/focus/scroll/setValue/setText/increment/decrement` | Exactly the argument record declared for that node/action; unsupported actions are rejected |

`HatValue` is `{hat: u16, x: i8, y: i8}` with each axis in `{-1,0,1}`; zero/zero is neutral. Controller axes use their descriptor's declared centered/trigger/ranged semantics. Buttons use edge state, so duplicate down/up transitions are rejected. A controller packet is a partial update: omitted axes retain their previous values. Descriptor state identifies neutral values for every field.

#### A.4.2 Descriptors and state

`input.create` accepts `{class, name, descriptorVersion, seat, capabilities, outputPolicy}`. Capabilities enumerate usages, contact capacity, axes with units/min/max/neutral/resolution, button/hat IDs, supported report sizes, maximum sample rate, output effects and coordinate-space policy. The service validates the descriptor against class limits and returns a resource reference plus its normalized immutable descriptor. Altering a descriptor requires a new device generation and neutralizing the old instance.

`input.state` returns the caller's synthetic state: active contacts, held keys/buttons, lock indicators, current axes/hats, composition ID, focus reference and last accepted/dispatched sequence. It does not reveal another principal's secret text or held inputs without observation authority. `input.release` accepts a device or complete lease and releases all associated state atomically from the input service's perspective.

Per-device input sequences begin at one and increase without wrap. Repeating the last accepted sequence with an identical digest returns its receipt without reapplying it; the same sequence with different content is `OperationConflict`. A gap is rejected with the next expected sequence, rather than guessed through. Receipts and their digests remain available for the active lease lifetime; reconnect invalidates that lifetime. Frame-level operation IDs still protect submission through the common request API.

#### A.4.3 Composition and contact state machines

```text
touch: absent -> down -> move* -> up/cancel -> absent
pen:   absent -> enter -> hover* -> down -> move* -> up -> hover*
       hover -> leave -> absent; cancel -> neutral/absent from any active state
key:   up -> down -> repeat* -> up
IME:   absent -> begin -> update* -> commit/cancel -> absent
```

Pen eraser and barrel-button changes are validated against the same device state. Pen cancellation releases its buttons. Touchpad contacts use the touch state machine. A pointer button or controller button uses the key edge state machine without key-repeat events. Invalid transitions reject the complete containing input frame. A device-removal or lease-cleanup event may always force the neutral state; it does not depend on the host sending a valid final frame.

### A.5 Bootstrap and session records

```text
Hello = { protocolMajors: array<u16>, protocolMinors: array<u16>,
          clientNonce: bytes[32], clientKind: "host" | "enrollment",
          schemaRevisions: map, limits: map, features: array<text> }
Welcome = { major: u16, minor: u16, connectionNonce: bytes[32],
            deviceId: Identity, bootId: Id128, daemonEpoch: Id128,
            mode: text, limits: map, capabilityDigest: Digest,
            monotonic: Timestamp, boottime: Timestamp }
Delegation = { clientPrincipal: text, parentGrant: Id128,
               requestedScope: map, expiry: Timestamp,
               deviceId: Identity, connectionNonce: bytes[32],
               algorithm: text, signature: bytes }
SessionOpen = { delegation: Delegation, requestedScope: map,
                reconnectWindowNs: u64 }
SessionResult = { sessionId: Id128, effectiveScope: map,
                  policyGeneration: u64, expires: Timestamp,
                  resumeSecret?: bytes[32], reconnectWindowNs: u64 }
```

A delegate's expiry is capped by its parent grant. Bootstrap signatures cover all fields other than `signature`, using deterministic CBOR and a domain prefix `TDK-DELEGATION-1` followed by a zero byte. Enrollment signatures use prefix `TDK-PAIR-1` followed by a zero byte before the transcript. Algorithm identifiers are closed enums from the negotiated cryptographic profile. A signature parser cannot choose arbitrary code or a device-provided algorithm implementation.

### A.6 Method declaration contract

Every machine-readable method declaration contains name, API version, input/result schemas, required scopes, supported profiles, mutability class, preconditions, commit point, cancellation semantics, progress/terminal events, limits, privacy classification and retry class. Omitting one is a schema-conformance failure. Core methods cannot be implemented as undocumented escape hatches to an owning service.

---

## 37. Appendix B: method catalogue

The following names are reserved core methods. A slash-separated suffix denotes separate methods sharing the domain contract. Parameters and results use common schemas plus the domain fields specified in the referenced section. Implementations MUST publish their complete RIDL and JSON/CBOR schemas before claiming T0 conformance.

| Methods | Principal inputs and results | Contract |
| --- | --- | --- |
| `hello`, `session.open/resume/inspect/close` | Versions, client delegation, scope → epochs, limits, session | 9 |
| `pair.begin/finish/status`, `trust.list/revoke/rotate` | Enrollment transcript or exact trust record → enrollment result | 6–7 |
| `capabilities.get`, `schema.get` | Optional digest/version → capability snapshot/schema resource | 12 |
| `device.info/wait` | Identity/mode/milestone → authenticated state | 5, 25 |
| `clock.sample` | Probe → receive/send samples and clock epoch | 13 |
| `operation.get/watch/cancel` | Operation ID → state, events, cancellation outcome | 11 |
| `stream.open/inspect/close` | Kind, schema, limits → channel descriptor | 10 |
| `barrier.wait` | Dependencies and requested milestones → reached milestones | 13 |
| `drive.acquire/renew/inspect/release/stop` | Seat, scope, policy or lease → lease/state/cleanup result | 14 |
| `input.devices/create/remove/send/state/release` | Descriptor, frames or device reference → references/receipts/state | 15 |
| `gesture.compile/run`, `input.record/replay` | Declarative gesture/manifest and timing → timeline/operation/artifact | 16 |
| `topology.get/watch` | Scope/revision → graph/deltas | 17 |
| `platform.list/get/prepare/commit/cancel/watch` | Target, preconditions, plan → transition state/revision | 17 |
| `settings.list/describe/get/watch` | Keys, scope, cursor → metadata/values/revisions/events | 18 |
| `settings.begin/stage/validate/commit/abort` | Revision, typed edits, transaction → validation/commit receipt | 18 |
| `settings.set/reset/wait/confirm` | Key/value or candidate revision → stored/effective outcome | 18 |
| `apps.list/inspect/install/launch/stop/uninstall/clearData` | App/package/instance and options → operation/lifecycle | 19 |
| `apps.activate/notify/resetPermissions` | Typed activation/notification or exact permission target → owner result | 19 |
| `files.roots/list/stat/read/write/mkdir/rename/copy/remove/metadata/watch` | Scoped root/components and preconditions → object/result/stream | 20 |
| `transfer.begin/status/resume/commit/cancel` | Manifest, destination and transfer ID → checkpoint/publication result | 20 |
| `files.syncPlan/syncCommit` | Scoped tree manifests and plan → conflicts/per-object outcomes | 20 |
| `exec.start/inspect/resize/cancel/detach/attach/list` | Executable/argv/resources or job → job/channels/exit | 21 |
| `observe.snapshot`, `ui.tree/watch/action` | Targets, revisions, action → observation/tree/action result | 22 |
| `capture.screenshot/start/reconfigure/stop` | Targets and media descriptor → artifact/stream/discontinuity | 22 |
| `clipboard.read/write` | User/seat/MIME data → scoped clipboard result | 22 |
| `logs.read/follow`, `trace.start/stop/export`, `profile.start/stop/export` | Filters/sources/budgets → events/session/artifact | 23 |
| `crash.list/export`, `diagnostics.bundle` | Scope and manifest → redacted artifact | 23 |
| `debug.attach/detach`, `devices.registry/health/restart` | Exact process/node generation and mode → channel/operation | 23 |
| `network.forward/reverse/list/close/inspect/test/capture/simulate` | Scoped endpoints or diagnostic plan → tunnel/operation/artifact | 24 |
| `events.describe/emit`, `simulation.create/configure/destroy` | Registered schema and test realm → receipt/resource | 24 |
| `power.get/wake/suspend/reboot/shutdown/wakeLock` | Exact action and bounded options → operation/resource | 25 |
| `update.plan/stage/activate/status/rollback` | Verified release/plan → update operation | 25 |
| `recovery.enter/inspect/repair/reinstall/erase` | Exact target, plan and approval → recovery operation | 25 |

Read methods are side-effect-free apart from bounded accounting and audit. Resource creation, subscriptions, capture, execution and all mutations require operation IDs even when their primary purpose is observation. `watch`/`follow` return a subscription resource and channel; cancellation closes that resource. List methods use `Page`; long work uses `Operation`; bulk data uses announced channels or scoped artifacts.

---

## 38. Appendix C: decision log

| ID | Decision | Reason |
| --- | --- | --- |
| TDK-001 | One typed protocol shared by CLI, SDK and MCP | Identical device semantics and authorization across clients |
| TDK-002 | Per-user host broker; per-client device delegation | Connection reuse without ambient authority sharing |
| TDK-003 | TLS TCP fallback, QUIC multiplexing and TLS USB stream | Reliable cross-platform connectivity with authenticated transport parity |
| TDK-004 | High-entropy pinned QR enrollment as the mandatory pairing profile | Avoid weak-code authentication and discovery-based trust |
| TDK-005 | Pairing identifies a host; grants authorize operations | Trust does not imply unrestricted device access |
| TDK-006 | Synthetic input never creates trusted presence | Preserve LibTessera's hardware-causality security model |
| TDK-007 | Input-service watchdog and neutralization | Daemon or network failure cannot strand held controls |
| TDK-008 | HID-equivalent typed input through MosaicDisplay | Match DeviceKit ownership while supporting rich device classes |
| TDK-009 | Platform and topology transitions are revisioned transactions | Prevent stale coordinates and incoherent live switching |
| TDK-010 | Direct settingsd transactions with stored/effective distinction | Correct settings automation without backing-store bypass |
| TDK-011 | Capability-rooted file APIs and explicit native launch resources | Preserve Tessera's namespace and process model |
| TDK-012 | Durable operation IDs with explicit indeterminate outcomes | Recover from lost replies without false exactly-once claims |
| TDK-013 | Monotonic scheduling, Boottime expiry and explicit clock epochs | Correct behavior across sleep and clock changes |
| TDK-014 | Bounded channels, separate control reserve and stream priorities | Keep stop/input responsive under streaming load |
| TDK-015 | Protected compositor capture and separate media grants | Full drive does not imply access to protected pixels or microphones |
| TDK-016 | MCP stdio and authenticated Streamable HTTP | Local and remote agents share the same scoped control surface |
| TDK-017 | Declarative automation with per-device results | Reproducible work without fabricated fleet atomicity |
| TDK-018 | Recovery/debug capabilities remain image- and policy-specific | Device tooling does not weaken verified boot or release security |

New decisions use `{id, decision, reason, affected sections, compatibility impact, conformance evidence}`. Changes to normative behavior require updating this specification and its versioned schemas together.
