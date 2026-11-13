# Tessera Home vs iOS 27 SpringBoard — code and API comparison

**Research build:** iPhone18,3 / iOS 27.0.1 / 24A446, arm64e.  
**Tessera components audited:** `desktop/layout/`, `desktop/app/Home/`, `platform-ui/`, `adaptive-mobile/`, `libtessera/`, and the `app-registry` data model.  
**Evidence:** runtime-generated headers at `~/Code/re/ios27/springboard/synthetic-codebase/Headers/`, assembly-backed method inventory and C-like Ghidra outputs in that same research workspace.

Legend: **[R]** interface recovered from the Apple firmware, **[T]** verified Tessera source, **[D]** proposed Tessera design. A recovered selector **does not** establish the original Apple method body or source-file layout. We should create **Tessera-owned Kira/RIDL services** with equivalent behavior, not call Apple's private binaries or claim API/ABI compatibility.

## Bottom line

Tessera already has a real, testable Home layout model, persistent pages, folders, hidden pages, a Dock settings path, App Library, and two built-in widget types. The architectural gap is that the Home view still owns almost all presentation and interaction state, and layout edits are persisted immediately. SpringBoard instead has separately observable icon models, a root folder/page-state controller, a drag manager, a Dock controller, application lifecycle integration, and a save/undo boundary.

**First improvement implemented in this audit:** `HomeLayout` now exposes `homePageTransition`, `homePageDestination`, `homeScreenKind`, and `homeDockVisibility`. `HomeScreen.kira` consumes them and draws one anchored Dock outside the horizontally scrolling icon pages; it fades the Dock around App Library. This is a Tessera design guided by [R] `SBRootFolderController` page transitions and `SBFloatingDockViewController`; the exact Apple transition curve is **not** recovered.

## Component-by-component comparison

| Area | Apple evidence [R] | Tessera today [T] | Next actual API [D] |
|---|---|---|---|
| Icon identity | `SBApplication.bundleIdentifier`, `SBHIconManager` icon descriptors and locations | `HomeItem.App(String)` and `HomeFolder.apps: [String]` use **display names**; `Home.txt` version 3 persists names | `HomeIconID` backed by registry `AppIdentity`, persistent folder ID and widget ID; migration from old names. Never identify an app by its label. |
| Icon layout | `SBIconListModel.insertIcon:atIndex:`, fixed icon locations, layout grid/sizes, list observers | `HomeLayout/HomeSpace` stores ordered arrays and overflows them into later pages; widgets reserve a separate top band | `HomeIconGrid` with stable icon coordinates, icon/widget size classes, per-display layout metrics and change events. Preserve existing array migration. |
| Editing and undo | `SBHIconManager.setEditing:...`, `SBIconDragManager.registerUndoWithPreparation:draggedIcons:` | `HomeScreen` booleans; `beginHomeEdit` writes `Home-before.txt`; every operation invokes `commitHome` and disk write | `HomeEditSession`: begin, preview, move, commit, cancel, undo/redo. Group one drag into one undoable transaction and one durable commit. |
| Persistence | `SBIconListModel.markIconStateDirty`, `SBIconController.canSaveIconState`, icon-state save callbacks | `arrangedHome()` calls `loadArrangement()` during UI body evaluation and saves reconciliation; edits write `Home.txt.next` and rename | Cache a model snapshot by generation; emit `HomeChange` with identity + version; persist after a successful transaction, recover from crash journal. |
| Page / App Library transitions | `SBRootFolderController.beginPageStateTransitionFromPageState:...`, `pageTransitionHandle:updateCurrentPageStateTransitionToProgress:`, end-success callback | `page`, `swipe`, `swiping`, `query`, `overview`, `folderOpen`, `searching` are separate state variables in the view | `HomePresentationCoordinator` with explicit states, progress and lifecycle events; now starts from `HomePageTransition` in `desktop/layout/`. |
| Floating Dock | Separate `SBFloatingDockViewController` and list / visibility behavior | `platformDock()` already exists; previously instantiated once **per scrolling icon page** | Keep one root-owned Dock with controlled visibility, a typed contents model, pinned/recent separation and direct edit session. **Anchored rendering implemented.** |
| Folder controller | `SBFolderController.contentView`, nested visibility, page navigation, drop and presentation delegates | `HomeFolder.apps` has no persistent folder identity; folder panel shows a fixed 3-column set and actions | `HomeFolderController`: stable folder ID, presentation state, rename and member-mutation transactions, multiple pages, drag auto-open and spring-loaded drop. |
| Drag and drop | `SBIconDragManager` owns sessions, location, hover, previews, autoscroll, can-snap-to-grid and undo | `HomeScreen` stores `carrying`, `carryPage`, `carryIndex`, finger XY and edge timer; drop calls `moveItem` / `dropItem` | `HomeDragSession` model with source/target/icon IDs, placeholder, hover dwell, edge-scroll, cancellation and drop-validation callbacks. |
| Widgets | `SBHWidgetStackViewController`, widget descriptors, stacks, active data source, content readiness and snapshot | Built-in Clock/Battery, refreshed at most once/minute; widgets live in a two-row band and no independent provider contracts | `HomeWidgetProvider` and `HomeWidgetTimeline` service over RIDL, snapshots, readiness, privacy and adaptive size classes; stack carousel separate from provider. |
| App Library | Root folder/library visibility transitions plus library categories and app state | Local alphabetical/category grouping from `Application.category`, `homeLibrary` view | Read library index by stable app ID; emit install/update/uninstall diffs; separate search/filter and scene presentation. |
| App launch / return | `SBHomeScreenController`, `SBApplication` and window-scene lifecycle hooks | UI calls `openApplicationFromIcon` / `openApplication`; mobile platform tracks surface and has `goHome` | `HomeLaunchCoordinator` over RIDL: launch requested → app identified → surface prepared → transition → activation / failure → return-to-Home. Use registry identity, not name. |
| Search | `SBSearchPresenter` states/progress and `SBSpotlightPresentableViewController` material/keyboard tracks | `HomeSearch.kira` uses recovered 24/75/150 thresholds and a Tessera search panel; some curves/geometry inferred | `HomeSearchTransition` as a platform presentation state; typed input focus handoff, keyboard scene alignment, remote search results/provider lifecycle. |
| Observability | Model observers, page-state events, icon-state dirty/save, drag observers | UI mostly redraws on local state mutations and file changes | Publish typed changes, generations and transition events to UI, platform and accessibility over explicitly scoped service interfaces. |

## Where the real Tessera APIs should live

```text
desktop/layout/                     # [T] pure data + geometry, no I/O
  app/Model.kira                    # HomeArrangement and HomeItem today
  app/PageTransition.kira           # NEW page state geometry, Dock visibility
  app/IconIdentity.kira             # [D] typed icon/app/folder/widget IDs
  app/IconGrid.kira                 # [D] grid coordinates and size classes
  app/EditTransaction.kira          # [D] move/drop/rename/edit/undo model

desktop/app/Home/                   # Home UI and animations, NOT state authority
  HomeScreen.kira                   # root presentation and gesture routing
  HomeSearch.kira                   # pull-to-search composition
  HomeDock.kira                     # pinned root Dock rendering
  HomeFolders.kira                  # folder visuals
  HomeWidgets.kira                  # widget host views

Home state service [D, component]:  # one authoritative model per user/session
  HomeModelService                   # snapshot + generation + subscriptions
  HomeEditService                    # transactional edits, undo/redo, durable save
  HomeIconLocationService            # ID → page/grid/Dock/folder location
  HomeWidgetHostService              # provider snapshots + timelines

adaptive-mobile + platform services [D]:
  HomePresentationCoordinator        # app scene / page / search / folder state
  AppActivationService               # launch, return home, app scene transitions
  InputFocusService                  # Spotlight keyboard and gesture ownership
```

Keep existing component boundaries: pure model rules in Kira, cross-process APIs over RIDL, display composition in the platform/UI layer. Do **not** create hidden byte-offset APIs or link Apple's SpringBoard frameworks into Tessera.

## Proposed API contract (design only, not implemented)

```text
HomeModelService.snapshot() -> HomeSnapshot { generation, pages, locations }
HomeModelService.observe(afterGeneration) -> HomeChange stream

HomeEditService.begin(baseGeneration) -> EditSessionID
HomeEditService.previewMove(session, iconID, targetLocation) -> PlacementResult
HomeEditService.commit(session) -> CommitResult { generation, undoID }
HomeEditService.cancel(session)
HomeEditService.undo(undoID) -> CommitResult

HomePresentationCoordinator.begin(fromState, toState, reason, interactive)
    -> TransitionID
HomePresentationCoordinator.update(transitionID, progress, velocity)
HomePresentationCoordinator.finish(transitionID, completed)

HomeLaunchCoordinator.activate(appIdentity, sourceIconID, sceneContext)
    -> ActivationResult { surfaceID, lifecycleState }
```

This is **not** valid `.ridl` syntax yet; it records capability, authority and message boundaries. The `HomeLayout` APIs below **are** compiled, public Kira functions:

```kira
public function homePageTransition(
    current: Number, translation: Number, width: Number, screenCount: Number
) -> HomePageTransition

public function homePageDestination(
    current: Number, predictedTranslation: Number, width: Number, screenCount: Number
) -> Number

public function homeScreenKind(index: Number, iconPageCount: Number) -> HomeScreenKind

public function homeDockVisibility(
    current: Number, translation: Number, width: Number, iconPageCount: Number
) -> Number
```

## Migration order

1. **Stable identities first.** `app-registry/app/Model.kira` already defines an `AppIdentity` tied to publisher and manifest ID. Wire this into installed-app services and Home, then migrate `Home.txt` version 3 names and Dock favourite names. Preserve names only as labels. Test same-name apps from two publishers and rename/update persistence. The registry's certificate-rotation limitation is documented in roadmap 36.
2. **One observable Home model.** Move authoritative mutable layout out of `HomeScreen`/file-per-edit helpers. Add `snapshot(generation)`, icon-list observers and transaction-scoped dirty/save/rollback. Keep existing `HomeLayout` math and atomic rename as durable storage primitives. Test cancelled edits, stale generation, crash between stage and replace, and simultaneous Dock and Home edits.
3. **Finish the presentation state machine.** Adopt the new page transition snapshot in the page indicator, wallpaper, icon translation, Dock and accessibility. Add separate typed states for folder, editing, App Library, search, and app activation; define cancellation and competing-gesture priority. Use the recovered `SBRootFolderController` lifecycle as reference, not an assumption of identical implementation.
4. **Make drag one session.** Introduce stable drag identifiers, hover/dwell, placeholder, target validation, edge auto-scroll and undo. Keep tentative mutations out of persistent storage until drop commits.
5. **Real widget services.** A provider protocol (RIDL), timeline updates, async content readiness, size classes and privacy; then add stacks/smart rotation. Clock/Battery can become the first providers without changing their current appearance.
6. **Scenes and launch transitions.** Platform owns window/surface authority, `HomeLaunchCoordinator` owns icon-flight/activation sequencing and handles scene failure/suspend/restore. Home only supplies icon geometry and user intent.
7. **Visual parity and device traces.** Compare Home/Dock/folder/search frame trajectories, spring timing, blur composition, keyboard, rotation and VoiceOver/reduced motion; only claim exact parity after matching behavior on real hardware.

## Concrete code changes made

- Added `desktop/layout/app/PageTransition.kira`: immutable page transition snapshot and pinned Dock visibility policy.
- Updated `desktop/app/Home/HomeScreen.kira`: horizontal paging delegates to these APIs. A single root Dock now remains anchored while pages scroll, fades into/out of App Library, and follows Home's vertical search pull.
- Added `desktop/tests/layout_kik/app/PageTransitionTests.kira`: test cases for progress, App Library, edge rubber-band, projected release, narrow viewport and Dock fade.

## Verification and boundaries

- `kira check tessera-packages/desktop/layout` → **`Check: Ok`**.
- `kira check tessera-packages/desktop` → blocked by **five** `MemoryExporter`/`MemoryExportFailure` diagnostics in `tessera-ui` and **one** `ViewModifier.kira` binding mismatch in upstream KiraUI; **no diagnostics in the new Home files**.
- `kira check tessera-packages/desktop/tests/layout_kik` → missing `@Main`/`@Plugin` entry for standalone check; this is a test-only package.
- `kira test tessera-packages/desktop/tests/layout_kik` → cannot link on this host: unresolved Apple/system runtime symbols such as `memcpy`, `memmove` and `pthread_self`. The tests have **not run successfully**.
- No Tessera device boot or side-by-side visual trace was performed. All UI parity claims remain hypotheses until tested.

## RE references for subsequent work

- `Headers/SpringBoardHome/SBIconListModel.h`: insertion, fixed locations, observers, dirty/clean events.
- `Headers/SpringBoardHome/SBHIconManager.h`: model, editing, locations, reset, Dock, widgets.
- `Headers/SpringBoardHome/SBRootFolderController.h`: page-state transition handles and progress.
- `Headers/SpringBoardHome/SBIconDragManager.h`: drag validation, preview, drop, undo.
- `Headers/SpringBoardHome/SBFolderController.h`: nested folder visibility and list pages.
- `Headers/SpringBoardHome/SBFloatingDockViewController.h`: separate Dock controller.
- `Headers/SpringBoardHome/SBHWidgetStackViewController.h`: host lifecycle and widget readiness.
- `Headers/SpringBoard/SBHomeScreenController.h`: page and icon-manager delegate callbacks.
- `Headers/SpringBoard/SBIconController.h`: icon-state save and app install updates.
- `Headers/SpringBoard/SBApplication.h`: app bundle identity and launch policy.

Read the actual generated headers first, then inspect `Indexes/DECOMPILATION-COVERAGE.tsv` before trusting a decompiled implementation. The research folder also carries 70,533 machine outputs, but those are not source-equivalent even when Ghidra emits C syntax.