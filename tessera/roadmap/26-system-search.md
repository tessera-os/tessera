# 26 — System search

A person should be able to ask for an app, a document, a setting or a small
calculation without first deciding which application owns the answer. System
search is the common entry point. It opens from a platform shortcut or gesture,
keeps the keyboard while it is open, and returns focus to the previous task
when dismissed.

This is broader than the launcher's current application-name filter. It joins
several kinds of result while preserving their identities and permissions.
Searching for a document does not give every application access to it, and
finding a setting does not require opening Settings at its first page.

## The experience

Results are grouped as applications, documents, settings, calculations and
actions. Each shows enough context to make a choice: an app's name and icon,
a document's location and modification date, or the Settings section containing
a preference. One result is selected for keyboard activation; moving between
groups and previewing an item must not activate it accidentally.

An empty query may show recent intentional actions and pinned results. Typing
replaces those suggestions with matches. Exact names and prefixes precede loose
matches, and the ranking is stable while a person moves through results. New
results may arrive progressively without moving the selected item to another
identity underneath the pointer or keyboard focus.

Calculations produce an answer that can be copied. Unit conversion can follow
arithmetic, using a defined set of units and the person's number conventions.
Quick actions include opening a Settings pane and selecting a known system
command. A destructive action such as shutting down has its ordinary named
confirmation flow; a query is never interpreted as a command line.

Search is local first. Network suggestions, if introduced later, must be a
separate visible source with a preference controlling whether queries leave
the device. An offline machine retains app, setting and indexed-document search.

## Ownership and interfaces

A system search service owns query execution and the document index. The
Dynamic Platforms own presentation and invocation; PlatformUI supplies the
shared result rows, selection and preview components. PlatformKit preserves
the originating task and routes the selected result to the appropriate action.
The service and its clients communicate through RIDL, with public capabilities
exposed through LibTessera where applications need them.

Providers supply typed records rather than arbitrary executable callbacks:
stable identity, result kind, display text, optional preview, ranking fields
and an activation description. Installed apps come from the application
registry ([36](36-app-lifecycle.md)). Settings supplies stable destinations.
Documents come from the indexed locations permitted to the service, with
activation returning through the file and grant workflows in
[19](19-files-and-documents.md). Third-party providers are later work and need
quotas, cancellation and an entitlement boundary before being enabled.

The query protocol carries a generation and allows cancellation. Responses
from an earlier query cannot overwrite the current query's results. A slow
provider has a deadline and cannot block other result groups or dismissal.
Provider failure is reported for its group while other results remain usable.

## Index and activation

The index stores stable file identity, names, selected metadata and access
scope. Initial indexing and change notifications reconcile creates, renames,
moves and removals. Notification overflow triggers a scoped rescan. A removed
volume becomes unavailable rather than leaving actionable stale file results.
Content extraction follows filename search and runs under resource limits;
an invalid document cannot take down indexing.

Indexes and previews are disposable caches. Rebuilding them does not remove
documents or recent-action preferences. The service excludes application-private
data unless an explicit supported integration grants access. Result summaries
must not reveal inaccessible contents, and the lock screen has no unrestricted
document-search surface.

Activation revalidates the selected identity. Apps go through the ordinary
launcher, documents through their association and grant, and Settings through
its destination routing. A result that disappeared produces a useful message
and can be removed from the current list. Arithmetic uses a bounded expression
parser, with explicit errors for invalid operations and unsupported input.

## Implementation order

1. Define provider records and activation types; integrate apps and Settings
   with the existing launcher and Settings navigation.
2. Add the shared search surface and keyboard, touch and pointer navigation,
   including cancellation, restored focus and asynchronous result generations.
3. Index filenames in selected document locations, follow changes and removable
   volumes, then add previews and recent actions.
4. Add arithmetic and unit conversion as local providers. Add content indexing
   only after filename correctness and permission filtering are proven.

Ends when one invocation finds and opens an app, a granted document and a
Settings page, and copies a calculation's answer without losing the prior task.

## Status

Steps 1, 2 and 4 have a first slice in PlatformUI, without a service yet:
`searchResults` ranks installed applications and Settings panes
(`SettingsPane`, with keywords) and answers a sum with the Calculation rules
Calculator uses; `SearchPanel` groups the results, walks them with the arrows
and opens an app, opens Settings at a pane through `settings.destination`, or
copies an answer. Home opens it with Command-Space or a pull down on a page.
Documents are found by name by walking Documents at each query, bounded to
2000 entries and six folders deep, and open Inlay on their folder. Every
provider answers synchronously, so results always belong to the latest
query. Search now follows the selected result's identity when its ranking
changes, and the keyboard can move through the full result set instead of
stopping at the first nine visible rows. The index service, content search and
the platforms' own invocation are not started. No checkpoint is verified on
a boot yet.

## Checkpoints

- [ ] Search by full name and prefix, activate an app and open a particular
      Settings pane; dismissing search restores the previous input focus.
- [ ] Type quickly while a provider is deliberately delayed. Results correspond
      only to the latest query and selection never changes to a different item.
- [ ] Find a document, rename and move it, then find its current identity and
      open it with the correct application and permissions.
- [ ] Unmount a volume and revoke a document scope. Results and previews no
      longer expose those files; another app's private data is never returned.
- [ ] Restart indexing after a notification gap and rebuild a deleted index.
      Results converge without duplicate files or changes to source documents.
- [ ] Copy an arithmetic result, reject an invalid expression and remain fully
      usable offline. No query executes an arbitrary program or shell command.
- [ ] Exercise keyboard-only and screen-reader navigation, empty results,
      provider failure and activation of a file removed after it was found.
