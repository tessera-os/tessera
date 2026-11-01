# 25 — App Store

Discover software, understand what it does, install it and keep it current.
The App Store is a planned system application using the application image and
installation model in [12](12-apps.md).

## 1. Browse and choose

The store has browse collections, categories and search. A product page shows
the app's icon, name, description, screenshots, publisher, version, release
notes, download size, supported Dynamic Platforms and system compatibility.
Requested access is explained before installation. Installed apps show Open
or Update, and incompatible apps explain why they cannot be installed.

Search distinguishes no results from a connection failure. Cached pages can
still be read offline and say when their information was last refreshed.
Opening a product link reaches the same page inside the store.

- [ ] Browse a collection and a category, search for an app, inspect its page
      and navigate back with the previous search and scroll position retained.
- [ ] A product link opens the intended app page. An unknown or withdrawn
      listing produces a useful unavailable state.
- [ ] A listing incompatible with the system or current platform explains the
      constraint. An app supporting another installed platform says how it can run.
- [ ] Go offline: cached listings remain readable, new requests show an offline
      state, and no stale listing claims a completed download or available install.

## 2. Install and open

Get starts a download with progress and cancellation. The store reports the
stages that matter: downloading, verifying, installing, ready or failed. Leaving
the store does not cancel a download. The same app cannot be installed twice
by repeated clicks, and interrupted work is reconciled on the next launch.

Once installed, the app appears in App Library and in Home according to the
person's placement preference ([24](24-home-and-personalisation.md)). Open
launches that installed version through the ordinary platform path.

The catalogue identifies the expected publisher and artifact. Downloaded bytes
are checked before installation. Store metadata is not a substitute for image
signature verification, and an app is not ready until installation succeeds.
A failed install leaves a clear retry or cancel action and no broken app entry.

Ends when a person can find, install and open an app entirely on Tessera.

- [ ] Install an app from its product page, leave the store during the download
      and open the completed installation from Home and the store.
- [ ] Cancel, lose the network and run out of space during separate installs.
      Each ends in a recoverable state with accurate storage and app listings.
- [ ] A modified download or a publisher mismatch is refused before launch;
      the existing installed app, if any, remains usable.
- [ ] Repeated Get actions and restarting the store during installation result
      in at most one completed installation of the selected app.

## 3. Updates and installed apps

Updates lists available versions, release notes and their download sizes.
The person can update one app or all eligible apps, and choose an automatic
update policy. The store explains additional access a new version requests;
existing consent does not silently grant new access.

An update retains app identity, document associations, Home placement and app
data. A running app is not overwritten in place: the update waits for a safe
activation point and says when closing or reopening the app is needed.
An interrupted update keeps a launchable accepted version. App data migration
must be considered before promising a downgrade to an older version.

Settings' Apps page and the store agree on installed versions and pending
updates. Uninstall distinguishes removing the application from deleting its
saved data, then removes stale launch and Home entries. System components
continue to update as part of the OS rather than through app updates.

- [ ] Update an app and reopen its previous data with its Home placement and
      document associations intact; Settings and the store show the new version.
- [ ] Interrupt an update and restart the machine. One accepted version remains
      launchable, with the update status reconciled and no partial version offered.
- [ ] Update a running app without disrupting its unsaved work; the pending
      version activates at the documented close or relaunch point.
- [ ] Toggle automatic updates, reboot and observe the chosen policy. An update
      requesting additional access follows the documented review before that access is granted.
- [ ] Uninstall with data retained, reinstall and recover that data. A separate
      delete-data choice removes the named app data without affecting another app.

## Distribution and product decisions

The App Store adds a catalogue and an update channel. Direct downloads and
disk-image installation remain supported, with the same confinement and image
integrity rules. A catalogue can decide what it lists without becoming the
authority over everything the owner can run.

App identity must remain stable across versions and be bound to its publisher;
a matching name or icon is insufficient. The store must distinguish apps it
manages from directly installed apps, and cannot silently replace the latter
with a catalogue entry sharing their name. Taking over update management needs
an explicit matching identity and the owner's choice.

[36 App lifecycle](36-app-lifecycle.md) owns the shared identity, registry,
activation and update state. The store presents those operations and their
progress; it does not create separate installations invisible to Settings,
Home, document associations or background-task management.

Before a public store, decide catalogue ownership, publishing and review,
publisher-key changes, withdrawn listings and retention of installed versions.
Accounts, purchases, subscriptions, ratings and reviews need separate product
decisions; this chapter does not assume a billing service or an account requirement.

## Dependencies and evidence

The first complete flow needs network configuration, DNS and HTTPS from
[20](20-networking.md), plus app identity, update activation and installation
support. It can be proven against a controlled catalogue with two app versions;
a static storefront mockup does not close install or update checkpoints.
Publishing to a public catalogue and introducing payments are later work.

## Implementation status (2026-10-31)

A host-testable **App Store core model** now lives in `app-registry/` and
`app-catalog/`. Its registry binds a stable app ID to a publisher-key
fingerprint rather than display name. Accepted and pending image versions,
permission grants, update-ownership consent, retained-data ownership,
strict versioned persistence, recovery after interrupted writes, and basic
signed-image *manifest syntax* are modeled and tested. Publisher authentication
and artifact signature verification are **not** provided by the core model;
those are the responsibility of the separately privileged installer.

The catalogue model supports browsing and search, category filters, offline
cache, platform/build compatibility, Open/Update/Get presentation, withdrawn
listings, downloadable-update availability, a multi-stage install job queue,
cancellation, progress, and a persisted restart-safe job journal. On restart
a queued/verified/in-progress job cannot claim an accepted application without
the independently accepted registry version. A product page retains an Open
action for a locally installed app even when its new catalogue version is
withdrawn, offline or incompatible.

This work does **not** implement the network catalogue, signed server feed,
download transport, quarantine, actual image installation, immutable image
activation, storefront UI or Home/Settings integration. In particular, no
metadata file or journal may confer signature trust on executable bytes.
The original boot and product acceptance checkpoints remain open. The current
PID 1 installer uses display-name image paths and requires migration to the
identity-based registry for fully safe, versioned application updates.


### Signed application image verification (2026-10-31)

`AppRegistry.verifyAppImageCandidate` checks an immutable staged file's actual
SHA-256 bytes and a canonical manifest statement under an Ed25519 certificate
whose SHA-256 fingerprint the privileged installer must supply from a trusted
policy or explicit owner approval. `AppCatalog.InstallQueue.verifyDownloadedImage`
connects that verifier to the download transaction and requires the signed
manifest to match the catalog's publisher identity and image digest. Public
host fixtures exercise valid signatures, altered bytes and mismatched pins.
No private signing key is part of the checkout. This does **not** yet provide
an OS-owned immutable installation slot or a privileged-only queue endpoint;
`stageInstall` and `finishInstall` still rely on the trusted installer to
ensure the verified bytes are the bytes eventually activated. Boot acceptance
checkpoints remain open.

### Staged-image activation safety (2026-10-31)

The signed-image verifier also rejects path-alias and linked-parent staging
paths, checks file metadata before/after digesting, and exposes a separate
`finishVerifiedInstall` queue operation that repeats signed-byte checks at the
activation boundary. Host regressions exercise tampering after download and
before activation. These checks are defense in depth: the installer still
needs to own an immutable image file descriptor and atomically activate that
exact verified image; the public pure-state queue is not an authorization
service. The model-only `finishInstall` operation remains available for
internal testing and is *not* a secure API to expose to untrusted clients.

The catalog installation queue enforces a three-active-download slot limit
and releases a slot on cancellation or when download verification begins;
queued work remains queued until a slot is available. This is a tested model
limit and not yet enforced by the missing privileged network downloader.
