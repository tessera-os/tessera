# 36 — Application lifecycle and integration

An installed application has a stable identity, documents and links it can
open, windows and work it can restore, and rules for starting, running in the
background, crashing and being removed. Tessera needs one coherent lifecycle
for these actions across Home, Inlay, search, Settings and the App Store.

The existing launch, supervision and image model in [12](12-apps.md) is the
starting point. Services are restarted by policy; applications that crash must
not be relaunched indefinitely in front of a person. This chapter adds the
integration and user controls around those mechanisms.

## Identity and registration

Define an application identity independent of display name, executable path,
installed image filename and process identifier. It binds the declared app
identifier to its publisher under the documented signing policy. Installed
version, supported platforms, document types, link handlers, background work
and startup requests are metadata associated with that identity.

An application registry owns accepted installations and publishes generation
changes to the launcher, store, search, Settings and document associations.
Install and update commit registration only after artifact verification and
activation preparation succeed. Uninstall removes registrations and scheduled
work together. Temporary staging images never become ordinary launch targets.

The manifest and descriptor/entitlement work still missing from
[12](12-apps.md) is required here. Keep declarations and effective grants
distinct: declaring a capability does not grant it. Per-app identity also
keys Home placements, retained data, notifications and permission decisions,
so a matching label cannot take over another application's state.

## Default applications and links

Apps declare supported document types and structured link schemes/domains.
The person chooses defaults in Settings or Open With. The resolver considers
compatibility and the accepted association, then asks the launcher to activate
the app with a typed document grant or link. It does not concatenate untrusted
input into executable arguments or expose an unrestricted filesystem path.

A link is data until dispatched through that resolver. Web/domain association
needs a documented proof of domain ownership before an app can claim a verified
association; arbitrary declarations cannot capture all links. Unsupported links
have a useful unavailable state and can be copied. Tessera's existing browser
non-goal remains unchanged; opening web content requires an explicitly supported
handler rather than a hidden browser implementation.

An already running app receives an activation event and can choose an existing
window or create the appropriate document window. If no compatible app exists,
the OS offers the supported selection/discovery flow, without granting a random
handler access. Removing the default selects no replacement silently unless
the person has already chosen an explicit fallback policy.

## Background activity and startup

Distinguish a foreground app, an invisible but running app, a scheduled job and
a service. Applications request bounded work with a reason, eligibility
conditions and an expiry. A supervised scheduling service owns durable job
records and asks the launcher to run eligible jobs in the app's existing
confinement and effective grants. It does not execute arbitrary user-provided
command strings or make an application a permanently privileged service.

Settings shows which apps may run background work, their current activity and
recent execution. Power, network and thermal policies can defer or stop work;
the app receives cancellation/deadline events and has a bounded checkpoint
period. Durable jobs reconcile after reboot so an acknowledged completion is
not blindly repeated, while applications still make externally visible work
idempotent where delivery cannot be exactly once.

Startup items are a separate explicit preference: what opens on login/session
start, what starts hidden, and what remains disabled. Apps cannot enable their
own startup entry silently. Disabling an entry does not uninstall the app.
Repeated startup failures suppress that entry with a visible recovery action,
not an endless launch loop. This remains a single local user/session model.

## Quit, force quit and crash recovery

Normal Quit asks the app to resolve unsaved work and close resources. Shutdown
has a bounded version of that flow. Force Quit names the app and the possible
loss of unsaved work, then terminates its whole job and closes grants/streams
owned by those processes. Other applications and the platform keep running.
The running-apps view distinguishes responding, busy, waiting and unresponsive
where observable; a long task is not labelled a crash solely for being slow.

Crash recovery offers Reopen or leave closed, with a local report and enough
context to identify the failure. Crash reporting requires the reporter work
currently absent from LibTessera; a guessed stack is not a reliable report.
Recovery records and document checkpoints are separate from diagnostic logs.
Logs avoid document contents and secrets, with explicit controls before export.

Apps publish versioned restoration tokens and durable document checkpoints.
The system remembers eligible app/window identities and placement through
PlatformKit ([28](28-desktop-and-displays.md)). Reopen validates the token and
app version, handles missing documents and discarded grants, and offers a fresh
start when restoration itself repeatedly fails. Never replay transient process
or surface handles from a previous boot.

## Updates and removal

An update is staged beside the active accepted version. It verifies identity,
checks declarations and prepares migration before activation. A running app's
loaded executable and libraries are not changed in place. The store or Settings
states whether closing/relaunching is required and preserves pending state
across interruption. [25](25-app-store.md) supplies the user-facing update flow.

Data-format migration declares compatibility and commits a recoverable change.
Retaining an old binary alone does not promise a safe data downgrade. Uninstall
stops the app and jobs, removes associations and placements, and offers a named
retain/delete-data choice. Retained data stays attributable and visible in
storage management; another publisher cannot acquire it by reusing the name.

## Implementation order

1. Introduce stable app identity, manifest parsing, registry transactions and
   effective-grant calculation; migrate installed-app consumers to that registry.
2. Add document/link activation and default handlers, including already running
   app routing and grant-scoped content delivery.
3. Add running-app status, whole-job Force Quit and restoration checkpoints;
   integrate durable background scheduling and startup preferences.
4. Complete crash reporting and safe reopening, then interruption-safe update
   activation, migration and coordinated uninstall.

Ends when the same app can be found, activated with a document, updated,
restored after a crash and removed with consistent identity and data handling.

## Checkpoints

- [ ] Install two apps with the same display name and different identities;
      their data, permissions, Home entries and update ownership stay separate.
- [ ] Set defaults for a document and a supported link, reboot and activate
      each with the intended existing or new window and only the selected grants.
- [ ] Run a bounded background task, defer it under power policy, cancel it,
      reboot and reconcile its completion without duplicate externally visible work.
- [ ] Enable and disable a startup item. A repeatedly failing item is suppressed
      visibly without preventing the rest of the session from starting.
- [ ] Force Quit an app with helper processes and active capture; the whole
      job stops, resource indicators clear and unrelated applications continue.
- [ ] Crash during an edited document, reopen through a supported checkpoint
      and retain recoverable edits. Failed restoration offers a fresh start without looping.
- [ ] Interrupt update activation and data migration on test data; recover a
      documented compatible app/data pair with no partially registered version.
- [ ] Uninstall with retained data, inspect its storage ownership and reinstall
      the matching app. A different publisher cannot claim that retained data.

## Implementation notes (2026-10-31)

A Foundation-only `AppRegistry` model and host regression suite now exist at
`tessera-packages/app-registry/`. It models stable publisher-bound identity,
a pending versus accepted image version, explicit activation after an image
digest is externally verified, update ownership, grants separate from requested
capabilities and data ownership retained after uninstall. Two publishers using
the same display name remain distinct. This is the transaction *model*, not
a signed image verifier, durable installer, process manager, running-app
activation, automatic update service, installed-app migration or App Store.
The registry now also has strict persisted accepted/pending records and
startup reconciliation, and checks for real application-manifest fields
(`id`, `name`, `version`, `exec`, `needs`). `AppCatalog` adds a separate
versioned offline cache, product action model, install job lifecycle and
restart-safe journal. These pure state models are tested on the host; none
provides an authenticated publisher verifier, network installer, OS-backed
activation, or durable permissions enforcement in PID 1. The original eight
end-to-end checkpoints above remain open.

App registry v2 retains one rollback candidate with older signed-image
metadata and preserves it across restart. Owner-approved rollback is gated on
a reverified previous image digest, and rollback or delayed activation cannot
re-grant capabilities revoked since the update was staged. Rollback remains a
state model, not yet a completed immutable-image slot switch in PID 1.

**Publisher identity caveat:** the current verifier binds an app identity to a
SHA-256 fingerprint of its *certificate DER*, not a standalone public-key
fingerprint. Certificate renewal will therefore change the identity even when
the underlying Ed25519 key is unchanged. An owner-approved, authenticated
certificate-rotation/migration protocol must be implemented before calling
this a stable production publisher identity across certificate renewals.
