# 24 — Home and personalisation

Home is the person's arrangement of the device. It includes pages, folders,
the application library, favourites, wallpaper and widgets.

## Starting point

Desktop.app draws an application grid, filters it by name and launches entries.
Adaptive Mobile shows that surface as Home with its Dock; Adaptive Desktop
offers it as its launcher. The following milestones extend those flows.

## 1. Pages and editing

Adaptive Mobile has horizontally navigable Home pages and an indicator of the
current page. An editing mode lets the person rearrange icons, move them
between pages, create a page, reorder pages and hide a page. Dragging toward a
page edge navigates while retaining the dragged item. Cancelling an edit
restores the arrangement from before that edit.

Folders have a name and an ordered collection of apps. Dropping an app onto
another creates a folder; apps can be added, reordered and moved out. Removing
the last item removes the empty folder. Dock favourites are edited through
the same model and do not change when switching Home pages.

Touch uses a deliberate edit gesture; pointer and keyboard have discoverable
equivalent commands. The arrangement is saved by stable application identity,
so an app update or renamed display label does not move its icon. Layout adapts
to output changes without losing placements. Desktop launcher arrangements and
mobile Home arrangements are kept independently.

The identity and installation registry come from [36](36-app-lifecycle.md).
Home observes committed registry changes instead of maintaining a second list
of installed applications. Shared input and accessibility behaviour follow
[33](33-language-and-input.md) and [34](34-accessibility.md).

Ends when someone can arrange Home and rely on finding it that way tomorrow.

- [ ] Create two pages, move an app between them, reorder the pages and reboot;
      the page order and app placement return.
- [ ] Create and rename a folder, reorder its apps, move one out and launch
      another from inside it. Each operation works with touch and keyboard.
- [ ] Hide and restore a page without uninstalling its applications or losing
      the page's arrangement.
- [ ] Add, reorder and remove Dock favourites; changing Home pages keeps the
      Dock unchanged and a running app remains discoverable after unpinning it.
- [ ] Rotate or resize the output, then restore it. Every placed app remains
      reachable; switching Dynamic Platforms preserves each one's saved layout.

Status (2026-10-26): Desktop's Home keeps pages, folders, hidden pages and
widgets in `Home.txt`, edited by touch (hold, carry, drop on an icon, carry
to the screen's side) and by keyboard (arrows ring an item, Shift moves it,
Return opens, Delete removes, Command-E edits, Command-G makes a folder,
Escape cancels). An icon carried onto the Dock is kept there at the drop
position. A page with more items than a smaller output has room for goes on
over extra screens without changing the saved arrangement. These compile
against the train's libraries; the checkpoints stay open until a boot shows
them.

Status (2026-10-31): Home's page overview now adds a page explicitly and
removes empty pages without deleting apps or widgets. Pages created on purpose
stay in `Home.txt` even while empty, hidden or reordered; ending an edit always
leaves a visible page. Home now also protects against duplicate and missing
applications, and the `version 3` text format escapes saved names while
accepting legacy `version 2` layouts. The host HomeLayout tests pass (34/34),
with zero findings from the Working with Kira result-rule checker. The staged
filesystem save helper passes an isolated write/rename test. The full desktop
boot checkpoints remain open.

Follow-up (2026-10-31): Home tolerates a zero-cell viewport during display
changes, and it restores a visible page if an old or damaged arrangement has
only hidden pages. New applications no longer get placed on a hidden trailing
page. The layout suite now passes 38/38 host tests, including the new recovery
and viewport cases. None of these host tests replaces the required boot check.

## 2. App Library and discovery

App Library lists every installed launchable app, including apps absent from
Home. It provides search and an alphabetical view. Removing from Home and
uninstalling are separate named actions. An app removed from Home can be added
back from the library, and a new installation is always discoverable there.
Settings chooses whether new installs are also placed on Home.

Search results and icons expose useful actions: Open, Add to Home or Remove
from Home, App Info and Uninstall when removal is supported. An app update keeps
its placement; uninstall removes its entries. An interrupted install never
leaves an icon that pretends the app can open.

- [ ] Remove an app from Home, find and launch it from the library, then add it
      back to a selected page without creating duplicate library entries.
- [ ] Install an app under each new-app placement preference. It appears in
      the library in both cases and on Home only when the preference says so.
- [ ] Update an app without changing its folder or Dock placement. Uninstall
      removes it from all pages, folders, Dock and search results.

## 3. Wallpaper and appearance

Settings and Home editing open a wallpaper picker with a live preview. Choose
a bundled image or an image granted from Files, adjust its crop and choose
Home, lock screen or both. Cancel preserves the previous wallpaper. Appearance
and icon labels stay legible across the chosen picture and supported light and
dark modes; changing appearance does not reset the layout.

- [ ] Apply a chosen image to Home only, confirm the lock screen is unchanged,
      and retain both choices after reboot.
- [ ] Change the crop, preview it at another output size and cancel. The
      previous saved image and crop remain in effect.
- [ ] Switch light/dark appearance and enable reduced motion and larger text;
      page controls, folders and icon actions remain reachable and legible.

## 4. Widgets

A widget gallery previews available widgets and supported sizes. Add, move,
resize and remove widgets in Home editing. A widget exposes a small amount of
app information and a useful action that opens its owning app in context.
The initial widgets should use existing system features, such as Clock and
battery state, before adding third-party widget publishing.

Widget content has a bounded update policy. An absent provider or a failed
update leaves a named placeholder, and a widget cannot bypass its application's
data permissions. The provider contract, update budget and behaviour while
locked must be specified before third-party widgets are enabled.

- [ ] Preview and add a Clock widget, move it to another page, change its size
      and retain its position and configuration after reboot.
- [ ] A battery widget reflects a power-state change; activating a widget opens
      the relevant application or Settings pane.
- [ ] A missing or failed provider leaves Home responsive, with a removable
      placeholder. Removing a widget ends its scheduled updates.
