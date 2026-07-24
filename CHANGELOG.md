# Changelog

All notable changes to Bagforge are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.2] - 2026-07-24

### Added

- **Saved searches** — right-click any search box (backpack, bank, or warband) to save the current query under a name, then recall or delete it later. Presets are account-wide.
- **Per-view icon size** — new sliders for the item button size on the backpack, character bank, and warband bank (24–64px). Windows resize to fit. Item borders, quality rings, quest markers, counts, and overlays scale with the icon via `SetScale` (Baganator's method) so everything stays aligned.

### Fixed

- **Merge Stacks dependency** — "Don't Merge Partial Stacks" now greys out when "Merge Stacks" is off.
- **Settings wording** — clearer Lower Level threshold tooltip, consistent American spelling ("Color") across labels and tooltips, and added the missing "Show Junk Total Price" strings.

### Housekeeping

- Removed dead code (two unused functions, ~33 unused local caches) and a duplicate locale entry; added a `.luacheckrc`. Addon is syntax- and lint-clean.

## [1.5.1] - 2026-07-16

### Fixed

- **Pitch-black bag icons** — 1.5.0 stacked a second warband dim (0.75) on Blizzard's `ItemContextOverlay` (0.8). Removed the custom overlay; bank open/close still refreshes context matching only.

## [1.5.0] - 2026-07-16

### Fixed

- **Blizzard bag teardown** — `RestoreBlizzardBags` puts stock open/toggle globals back on Backpack disable; Close* hooks gated while suppressed.
- **Bank double-scan** — slot churn (`PLAYERBANKSLOTS_CHANGED` / account tab slots / tab settings) marks dirty only; `BAG_UPDATE_DELAYED` owns the flush. Structural `BANK_TABS_CHANGED` still flushes eagerly.

### Added

- **Auto-close** — bags opened by merchant/mail/AH/trade/scrapping close on interaction HIDE only when `_autoOpened` (manual open stays open). Baganator `OpenClose.lua`.
- **Warband deposit dim** — backpack stacks ineligible for account bank use Blizzard `ItemContextOverlay` while warband bank is open (no second custom overlay).

### Improved

- **Narrow paints** — `ITEM_LOCK_CHANGED`, quest log, and cooldown update buttons only (no full Draw). Baganator `LiveBagOnEvent`.
- **Dirty-bag scratch reuse** — backpack/bank flush reuses `_dirtyBagCopy` instead of allocating every DELAYED.
- Pruned speculative Secret Value guards from item/container/money paths per Resources 12.0.7.

## [1.4.16] - 2026-07-10

### Fixed

- **Epic quality border** — stop preferring `GetItemQualityByID(itemID)` (base template is often Uncommon/green). Use container / `C_Item.GetItemQuality(ItemLocation)` / full hyperlink first, matching Baganator live bag buttons. Always clear `IconBorder` via `SetItemButtonQuality`.

## [1.4.15] - 2026-07-10

### Fixed

- **Quality border** — always call `SetItemButtonQuality` (nil clears `IconBorder`); prefer `C_Item.GetItemQualityByID` over container quality. `ClearItemButtonOverlay` never clears the quality ring, so skipping paint left a stale green border on epics until sort rebuilt (Baganator `ContainerSlots` / `ItemButtonTemplate.lua`).

## [1.4.14] - 2026-07-10

### Added

- **`Core/CombineStacks.lua`** — physical partial-stack combine before `SortBags` / `SortBank` (Baganator `CombineStacksAndSort`).
- **Mail / Trade category transfers** — header menu actions when mailbox or trade UI is open (`AddToMail` / `AddToTrade`).

### Improved

- **Bank tab switch** — `_sortRequired` forces full panel Layout (BetterBags `view.sortRequired` after Wipe/tab change).

### Docs

- Research lab scorecard: CombineStacks, OpenClose mail/trade transfers, bank sortRequired marked done.

## [1.4.13] - 2026-07-10

### Added

- **Auto-open matrix** — optional open bags on merchant / mail / auction / scrapping (plus existing trade), driven by `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` (Baganator OpenClose.lua).
- **`API:RequestItemButtonsRefresh(reason)`** — optional `paint` / `headers` / `layout` / `reclassify` / `chrome` routed through `UIRefresh` (Baganator RefreshReason shape).

### Improved

- **Right-click bank deposit** — prefers the selected tab, then depositFlags-matched tabs, then any free bank slot (same path as category deposit; Desktop BankTransferManager).

### Docs

- **`bagforge-bag-research.mdc`** — scorecard + backlog updated after Desktop BetterBags/Baganator audit (paint-only search and dirtyCategories already correct).

## [1.4.12] - 2026-07-09

### Added

- **`API:UnregisterJunkDetector`** — JunkPlugins can detach detectors on disable.
- **`ContainerWindow:EnsureShellSize`** — sizes the main panel before first `Show` / combat open.

### Fixed

- **Combat open** — bags/bank get a visible empty shell before layout; `pendingDraw` still flushes on `PLAYER_REGEN_ENABLED` (BetterBags-style regen flush).
- **`EQUIPMENT_SETS_CHANGED`** — full backpack refresh so the equip-set category stays correct (Events.lua + BetterBags wipe pattern).
- **Transfers disable** — clears deposit queue, unregisters queue `BAG_UPDATE`, gates `QueueDeposit` on `_hooksInstalled`.
- **JunkPlugins disable** — unregisters detectors; `RefreshButtons` no-ops while disabled; re-enable re-registers without stacking `hooksecurefunc`.
- **Free-slot deposit** — shows `ERR_BAG_FULL` when every bag is full.

### Docs

- **`bagforge-conventions.mdc`** — open/first-paint rules, event ownership table, full-rebuild whitelist, Resources secret notes.

## [1.4.11] - 2026-07-09

### Fixed

- **Secret quest / equip-set fields** — merged-stack lock refresh and `isInSet` use `SafeBool`/`SafeNumber` (ContainerDocumentation `ItemQuestInfo` / `GetContainerItemEquipmentSetInfo`).
- **Batch layout after combat** — cancelling an in-flight batch clears panel signatures so the next draw cannot early-out with missing buttons.
- **Search while bags closed** — `INVENTORY_SEARCH_UPDATE` still updates `isFiltered` / marks dirty; bank scanners warm when no view is open.
- **Hide non-matches toggle** — forces non-incremental layout (was patching via a stale incremental changeset).
- **Bank first paint** — `View:Open` layouts synchronously after `Run()` when the main panel is still unsized.
- **Empty bags / PEW / late item info** — `_hasScanned` replaces `#slots==0` open-rescan; `PLAYER_ENTERING_WORLD` and closed `GET_ITEM_INFO_RECEIVED` mark dirty.
- **Category import** — writes order pins then full `RefreshBags(true)` instead of racing budgeted reclassify + display-only draw.

## [1.4.10] - 2026-07-09

### Fixed

- **First open after login** — bags played the open sound but stayed invisible until close/reopen. `Open()` now always `Draw()`s after a dirty/empty scan instead of waiting on debounced `Items.Updated` (0×0 frame).
- **First bank open** — layout paints immediately when the main panel has never been sized; `OpenBanking` retries `PickView` one frame later if `CanViewBank` was not ready yet.

## [1.4.9] - 2026-07-09

### Fixed

- **Category import rename map** — when a saved search is renamed on clash, assignments / order / colours / managedOrder remap to the new name.
- **Bank close right-click** — resets only that bank view’s position (`enabledKey`), not both character and warband.
- **`/bf resetbank` / `resetwarbank`** — each targets its own view (`active` / `warband`).
- **Custom category rename** — rejects names that collide with an existing saved search.
- **`/bf cat clear`** — deletes search categories fully; clears colour overrides for custom categories.
- **Junk header vs layout hash** — `showJunkPrice` nil defaults to show (matches `LayoutOptsHash`).
- **Bag bar lock desaturate** — uses `F.SafeBool` before branching on inventory lock.
- **Bank view close** — clears `sections` / `_pendingChangeset` so reopen doesn’t paint a stale scan.
- **Organize / CategoryManager disable** — disarm edit modes; hide manager window.
- **Delete cheapest / paint hash** — secret-safe `hasNoValue` and boolean paint folds.

## [1.4.8] - 2026-07-09

### Added

- **`API:UnregisterItemButtonCallback`** — display integrations (CanIMogIt) can detach on disable.
- **`F.BucketEvent` returns handle** — callers can unregister the bucket callback on teardown.

### Fixed

- **Secret container booleans** — `BuildEntry` / lock refresh / `RefreshFiltered` normalize `isLocked` / `isBound` / `isFiltered` via `F.SafeBool`; Transfers and Vendor sell path guard live `info.isLocked` the same way.
- **Search `unbound:`** — uses `isBound ~= true` so a leftover secret never hits `not secret`.
- **ItemButton teardown** — `OnDisable` clears delete-mode hook, events, and BagSlot registry callbacks; `Release`/`ReleaseAll` nil-safe; delete hook restores the global only when we still own it.
- **JunkPlugins** — tracks ADDON_LOADED waiters and one-shots detector install so re-enable does not stack hooks.
- **CanIMogIt disable** — unregisters the item-button overlay callback.
- **`UpdateNewItem` quality** — skips secret quality when painting the new-item glow.

## [1.4.7] - 2026-07-09

### Added

- **Module event teardown** — `TrackEvent` / `UnregisterModuleEventHandles` on the engine; `OnDisable` for Items, Backpack, Recent, and Transfers (idempotent `_hooksInstalled` guards).

### Changed

- **Recent / Items event ownership** — `BAG_UPDATE_DELAYED` is Items-only (GUID walk inside `Items:Scan`); Recent owns `BAG_NEW_ITEMS_UPDATED` for flag refresh only.
- **Login scan** — dropped redundant `PLAYER_LOGIN` full backpack refresh (initial `Items:Scan` in `OnEnable` is enough).
- **`/bf resetwarbank`** — resets warband bank position only (no longer clears character bank).

### Fixed

- **Secret stack counts** — slot dirty detection treats secret `stackCount` as changed instead of coercing to `1`.
- **Bank Sort callback** — `Sort.StateChanged` unregisters with the rest of bank hooks on disable.
- **Saved-search caches** — `InvalidateItemProps` wipes hyperlink winner/reject caches (not just `id:N`); import and `searchEnable` toggle clear search caches before reclassify; Categories `OnDisable` clears them too.
- **Guild repair teardown** — cancel pending guild-repair timer/listener on merchant close, vendor disable, or settings toggle (no orphan personal-funds fallback).

## [1.4.6] - 2026-07-09

### Added

- **Budgeted reclassify** — `Scan:RefreshCategories` yields after ~100ms (`F.ReportFrameBudget` / `FrameBudgetExceeded`) and resumes next frame; `ApplyScannerRefresh` waits for backpack + bank before drawing. Newer reclassify or a full `Run()` cancels in-flight work without hanging the coordinator.

### Fixed

- **Free-slot deposit** — dropping onto the free-slot box no longer picks up the first occupied bag slot (inverted empty-slot check).
- **Bank bag refresh** — `BAG_UPDATE` only marks dirty bags; flush runs on `BAG_UPDATE_DELAYED` (matches backpack, avoids early/double scans).
- **Backpack rebuild** — `BuildWindow` is a no-op when the main frame already exists (re-enable no longer duplicates frames).

## [1.4.5] - 2026-07-09

### Changed

- **Transfer targeting** — deposit/withdraw routes prefer specialty bags (herb, engineering, reagent, etc.) via `GetItemFamily` / bag family checks (Baganator `BagUsageChecks` pattern).
- **Warband deposits** — category deposit into account bank moves up to 5 items per burst and waits until the bank absorbs the prior batch before continuing.
- **Vendor category** — sells up to 6 items per step instead of one-at-a-time.

## [1.4.4] - 2026-07-09

### Removed

- **Currency & item tracking** — removed the currencies toolbar button, tracking panel, shift+click item tracking, and `Modules/CurrencyTrack.lua`. Blizzard's backpack token bar (footer currencies) is unchanged.

### Changed

- **Free-slot chrome** — empty-slot counter now uses the `bags-item-slot64` atlas (Baganator's retail slot background) instead of `ItemSlotBackgroundCombinedBagsTemplate`.

## [1.4.3] - 2026-07-09

### Added

- **Junk plugin API** — `Bagforge.API:RegisterJunkDetector` + `IsItemJunk` (Baganator `RegisterJunkPlugin` pattern); `RequestItemButtonsRefresh` now routes through `ns:UIRefresh({ paint })`.
- **Junk plugin bridges** — auto-detect SellJunk, Scrap, Dejunk, and Vendor junk rules (`Modules/JunkPlugins.lua`).

### Changed

- **Item junk coin** — unified through `API:IsItemJunk` (built-in grey/custom + third-party detectors).
- **Plugins settings** — tooltips list junk detectors; toggling a source refreshes junk overlays.

## [1.4.2] - 2026-07-09

### Added

- **`ns:UIRefresh`** — Baganator-style narrow refresh routing (`paint`, `headers`, `layout`, `reclassify`, `chrome`) with backpack/bank zones.
- **Withdraw category** — bank category context menu moves a whole category into backpack bags (`Transfers:WithdrawCategory`).
- **Frame budget helpers** — `F.ReportFrameBudget` / `F.FrameBudgetExceeded` (~100ms) for future hot-path deferral.
- **Layout generation tokens** — batched category layout cancels when a newer draw supersedes it.

### Changed

- **Settings live-apply** — backpack/bank toggles use `UIRefresh` instead of full `Draw()` where safe (counts/junk header, chrome-only, layout-only).
- **Incremental draw** — `PatchChangedEntries` also refreshes category headers (counts, junk total) on dirty categories.
- **Saved-search classify** — `GetSearchCategory` iterates `GetSortedSearches()` with winner + reject caches (Baganator CategoryFilter pattern).
- **Slot diff** — `ProcessSlotDiff` skips `updated` when paint fields are unchanged.
- **Transfers** — `WaitingItemData` waits on `RequestLoadItemDataByID` when stack size is unknown; withdraw/deposit/vendor all gate on cache pending.
- **Item buttons** — paint snapshot includes `isNewItem` so new-item glow clears on incremental refresh.

## [1.4.1] - 2026-07-09

### Changed

- **Loot path (Baganator-style)** — single-item add/remove patches section lists in place (`EnsureSection`, `SectionInsertSorted`, `SectionRemoveEntry`) instead of running `_FinalizeBuild` on every pickup; layout narrows to `dirtyCategories` only.
- **Transfer pacing** — vendor/deposit steps wait on `ns:IsBagCachePending()` so moves do not race ahead of the dirty-bag scanner flush (mirrors Baganator's `IsBagEventPending` gate).
- **Item buttons** — skip redundant widget repaints when cached display fields are unchanged (`Button_SetItem` paint snapshot).

## [1.4.0] - 2026-07-08

### Changed

- **Incremental scan audit complete** — every hot path now uses per-slot diff, changeset patching, or targeted refresh APIs; full `scanner:Run()` is reserved for first open, bag-container changes, stack-merge disable, and finalize fallbacks.
- **Unusable tint refresh** — level-up and toggle repaint via changeset (`RefreshUnusable`) instead of a global draw-epoch bump.
- **New-item events** — `BAG_NEW_ITEMS_UPDATED` no longer queues a full backpack rescan in Items (Recent handles it incrementally when windows are open).
- **Category import** — reclassify + reorder in place; header colours repaint only (`RefreshBags(false)`).
- **`dontMergePartial` toggle** — full rescan only when stack merge is already enabled (otherwise no-op).

### Fixed

- **Category import** — removed duplicate `ApplyManagedOrder` call that ran before junk/assignments were merged and before reclassify.
- **Recent click with bags closed** — `RefreshRecentSlot` now updates scanner data and marks scan dirty even when no window is open.
- **Recent event wiring** — `RefreshRecentFlags` runs on `BAG_NEW_ITEMS_UPDATED` only, not every `BAG_UPDATE_DELAYED` (Items incremental scan already sets `isNewItem` on loot).

### Notes

Intentional full rescans remain for: initial `PLAYER_LOGIN` scan, `BAG_CONTAINER_UPDATE`, disabling stack merge, section-patch finalize failures (`needsFinalize`), and `GET_ITEM_INFO_RECEIVED` when category moves cannot be applied in place.

### Documentation

- **Developer guide** — scan/refresh architecture, API picker table, event ownership, import order, and gotchas added to `.cursor/rules/bagforge-conventions.mdc`.
- **`Core/Scan.lua` header** — changeset fields and in-place refresh API index.
- **`README.md`** — Performance section updated for incremental scan and targeted refresh.
- **Ecosystem rules** — `AddOns/.cursor/rules/wow-addon-shared-patterns.mdc` §10 + hub §6 cross-ref; synced to all addons via `sync-addon-rules.ps1`.

## [1.3.11] - 2026-07-08

### Changed

- **Recent click patch** — clicking a new item clears Recent and patches that slot in place (`RefreshRecentSlot`); loot with bags open uses `Recent:Scan` + `RefreshRecentFlags` instead of waiting for a full scan.
- **Custom junk toggle** — mark/unmark junk reclassifies only that itemID; clear-all uses `ReclassifyBags`.
- **`/bf filter`** — slash filter toggles and ilvl threshold use `ReclassifyBags`.
- **Delete mode** — relies on `BAG_UPDATE` dirty-bag flush instead of an immediate full rescan.
- **Delete cheapest / transfers** — same `BAG_UPDATE` path after item removal or vendor sell.
- **`/bf cat order|unorder|clear`** — category order pins and bulk unassign use incremental refresh APIs.
- **Plugin category registration** — debounced `ReclassifyBags` instead of full rescan.

## [1.3.10] - 2026-07-08

### Changed

- **Category rename** — custom category renames patch the scanner section in place (`RenameCategorySection`); search renames use `ReclassifyBags`.
- **Category delete** — assignment/search deletes reclassify in place instead of a full bag scan.
- **Category order UI** — manager reorder, reset, and visible-category nudge use `RefreshCategoryOrders`.
- **Recent startup** — post-login baseline uses `RefreshRecentFlags` (reclassify into/out of Recent Items) instead of `RefreshBags(true)`.

## [1.3.9] - 2026-07-08

### Changed

- **Display overlay refresh** — Pawn/ItemInfo toggles patch only changed entries via changeset (`RefreshDisplayFields`) instead of bumping the global draw epoch across every panel.
- **Custom assignments** — assign/unassign one item reclassifies only that itemID's stacks (`RefreshItemCategory`).
- **Search categories** — create/edit/delete saved searches call `ReclassifyBags` instead of a full bag scan.
- **Category order pins** — `SetOrder` uses `RefreshCategoryOrders` (re-sort sections in place).

## [1.3.8] - 2026-07-08

### Added

- **Sort-mode resort** — changing `itemSort` re-sorts each category panel in place (`RefreshSortOrder`) instead of a full bag scan.
- **Stack-merge fast path** — enabling `stackMerge` runs `_MergeStacks` + section rebuild on existing scan data; disabling merge or enabling `dontMergePartial` still requires a full rescan to restore split stacks.
- **`ns:ApplyScannerRefresh`** — shared coordinator for in-place scanner updates (backpack + bank, open/closed, fallback to full rescan).

### Changed

- **Organize settings** — `customEnable` / `searchEnable` use `ReclassifyBags`; `itemSort` uses `ResortBags`; `stackMerge` / `dontMergePartial` use targeted merge paths.
- **Plugins** — sort-mode fallback calls `ResortBags` instead of full rescan when only the comparator changes.

## [1.3.7] - 2026-07-08

### Added

- **Filter reclassify fast path** — `Scan:RefreshCategories` and `ns:ReclassifyBags` move items between category panels in place when filters/plugins toggle; full rescan only when section lists cannot be patched. New category panels are created on demand via `EnsureSection`.
- **Search hide toggle** — `searchHideNonMatches` live-applies with relayout-only refresh (`RefreshBags(false)`); search keystrokes use changeset-aware incremental vs. structural layout based on hide mode.

### Changed

- **Categories / Plugins settings** — filter and plugin source toggles call `ReclassifyBags` instead of always forcing `RefreshBags(true)` (plugin sort fallback still triggers full rescan when sort mode changes).

## [1.3.6] - 2026-07-08

### Changed

- **RefreshItemID fast path** — late `GET_ITEM_INFO_RECEIVED` data updates entries in place and moves them between category panels when both sections exist; only falls back to full rescan when section lists cannot be patched. Batched item-ID flushes merge into one changeset.
- **Quest log reclassification** — `RefreshQuestState` re-runs `GetCategory` after quest overlay refresh so quest items can move into/out of Quest Items without a full scan; dirty panels layout via changeset.

## [1.3.5] - 2026-07-08

### Added

- **Category-move fast path** — slot diffs that only reclassify an item (same itemID, new category) move the entry between section lists in place instead of running full sort/merge finalize when both panels already exist.
- **Bank quest overlays** — `QUEST_LOG_UPDATE` refreshes open bank views the same way as the backpack; no-op when quest/lock fields did not change.

### Changed

- **Quest refresh narrowing** — `RefreshQuestState` compares overlay fields before/after and skips redraw when nothing moved; incremental patch is suppressed when `structureChanged` (e.g. category moves between panels).

## [1.3.4] - 2026-07-08

### Added

- **Slot-level dirty narrowing** — `Scan.CollectDirtySlotKeys` compares live bag slots to the scanner before `Run()`; no-op `BAG_UPDATE` bursts skip scan and redraw when nothing actually moved.
- **Dirty-section layout** — category panels in `StackCategories` / main panel skip `Layout()` when `changeset.dirtyCategories` names only the panels that changed (anchors still update); falls back to full layout when stack-merge finalize could reshape other categories.

### Changed

- **Bank refresh** — `RefreshIfOpen` / `Draw` pass `dirtySlotKeys` through the bank view scan path (parity with backpack flush).

## [1.3.3] - 2026-07-08

### Added

- **Per-slot scan diff** — dirty-bag updates patch individual slots (`added` / `removed` / `updated` changeset) instead of rescanning whole bags; count-only loot uses a fast path that skips sort/section rebuild.
- **Incremental UI redraw** — category panels split structure vs. paint signatures; unchanged grids patch buttons in place via `buttonsByKey` / `PatchEntry` instead of full `Layout()`.
- **Search text cache** — `Search.IndexEntry` builds a per-entry search blob at scan time for faster saved-search bareword matching.
- **Don't merge partial stacks** — optional Organize setting (BetterBags parity): partial stacks never combine with full or other partial piles.

### Changed

- **Items.Updated** — scan callback passes `scanner.lastChangeset`; backpack/bank use incremental draw when `changeset.incremental` is set.

## [1.3.2] - 2026-07-08

### Fixed

- **Incremental bag scan** — dirty-bag tracking now rescans only changed bags (`Scan:_BuildPartial`) instead of every backpack/bank slot on each `BAG_UPDATE`; sort flush and container updates still force a full rebuild.
- **Combat layout holes** — when the item-button pool is dry in combat, layout reuses stale cells from the previous draw instead of leaving blank slots until regen.
- **Merged stack lock/quest** — non-root stacks in a merged pile update the root entry's lock and quest overlay without a full rescan (`_mergedSlots`, `RefreshEntryLiveFields`, merged `RefreshSlot`).
- **Bank RefreshItemID** — returns category/junk change flags like the backpack scanner; `GET_ITEM_INFO_RECEIVED` invalidates bank categories when item metadata shifts.
- **Delete-mode click hook** — `HandleModifiedItemClick` is installed only while delete mode is armed (Organize), avoiding conflicts with other bag addons at load time.

### Changed

- **Async scan completion** — `Scan:_ScheduleScanComplete` debounces the progressive refine pass (50ms) so ContinuableContainer does not double-fire layout callbacks.
- **Money footer** — shared `F.CanUpdatePlayerMoney` / `F.UpdatePlayerMoneyFrame` for backpack and bank footers (combat + secret guards).
- **Category prop cache** — bounded via `F.CacheSet` (800 entries) so long sessions cannot grow `propCache` without bound.
- **Bank windowPos migration** — removed one-time `position`/`positions` → `windowPos` copy (schema stable).

## [1.3.1] - 2026-07-03

### Fixed

- **Scan crash** — `PopulateEntryFromSlot` was declared below `meta:_Build`, so the first bag scan called a nil function (`attempt to call a nil value` at line 720).
- **Post-sort categories** — `RefreshAfterSort` no longer reuses stale section assignments; cached metadata covers static item fields only and `GetCategory` always runs from live slot data (Recent, Reagent Bag, Quest, etc.).
- **Backpack sort flush** — pre-register the post-sort callback before `SortBags()` (parity with bank) so refresh still runs when Blizzard emits no `BAG_UPDATE`; helper locals moved above `Items:Sort()` (Lua forward-reference).
- **Poor-quality items** — `RefreshEntryItemFields` treats quality `0` as valid (Lua falsy bug).
- **Bank display refresh** — `RefreshBags(false)` relayouts the bank from existing scan data instead of a full `scanner:Run()`.
- **Post-sort async redraw** — `RefreshAfterSort` async continuation calls `_Build` once instead of re-entering `Run()` (avoids triple layout passes).
- **Populate guard** — skip appending entries when `PopulateEntryFromSlot` returns false.
- **Backpack open** — defer `Draw()` when a deferred scan runs on open (no double layout).
- **Sort tooltips** — `ScanAfterSort` invalidates search tooltips like full `Scan()`.

### Changed

- **Bank sort flush** — pre-registered post-sort callback uses `ScanAfterSort()` instead of full `RefreshIfOpen()` / `Run()` when Blizzard emits no `BAG_UPDATE`.
- **Layout fallbacks** — `perColumn` and bank column defaults use `C.Layout.*` when saved settings are nil.

- **Pawn init spam** — gate upgrade checks on `PawnIsReady()`; Items scans before Pawn finishes `PLAYER_LOGIN` init no longer call Pawn APIs (fixes "Can't check to see if items are upgrades until Pawn is initialized" flood).
- **Pawn plugins duplicate** — built-in Pawn/CanIMogIt toggles stay on Item Display only; Plugins lists category/sort API sources, not overlay integrations.
- **Unusable item tint** — replaced `C_PlayerInfo.CanUseItem` with the Bagnon/LibUnfit model (proficiency tables, tooltip class requirements, required level only). Wrong-stat leather no longer paints red when your class can wear the armor type.
- **Refresh hardening (BetterBags patterns)** — combat-deferred bag/bank data refresh (flush on `PLAYER_REGEN_ENABLED`); bank `DrawLayout` debounced after async scan; `BAG_CONTAINER_UPDATE` triggers full backpack rescan; Item mixin cache cleared on zone cache wipe.

- **Item level display** — Midnight returns `C_Item.GetItemInfo` as an ItemInfo table; old `select()` unpacking left `classID`/`itemLevel` nil, so ilvl never painted on gear even with the toggle on.
- **GetItemInfoInstant shape** — Blizzard documents a different return layout than `GetItemInfo` (`itemID`, `itemType`, …); our normalizer had reused the wrong field map, corrupting `classID` at scan time.
- **Equipment / Legacy / Legendary filters** — scan and category code now read `classID`, `expansionID`, and bind type through `F.GetItemInfoRecord()` / `F.GetItemInfoInstantRecord()` so specialty panels populate again.
- **Organize labels, delete-cheapest filters, transfer stack limits, category drop** — same ItemInfo-table normalization; hyperlinks fall back to `Item:GetItemLink()` per Blizzard's Item mixin when container info omits the link.
- **Midnight secret guards** — `classID`/`subClassID` comparisons, stack counts, quest overlay fields, junk header totals, and transfer stack limits now use `F.SafeNumber` / `F.SafeBool` so combat/instance secrets cannot throw in category, search, or sort paths.
- **Item level (Blizzard bug)** — dropped `GetDetailedItemLevelInfo` fallback ([WoWUIBugs #828](https://github.com/Stanzilla/WoWUIBugs/issues/828)); ilvl now comes from bag tooltip data, then `Item:GetCurrentItemLevel()`, then static item record only.
- **Uncached item data** — scan now calls `C_Item.RequestLoadItemDataByID` for slots missing cache (pairs with `GET_ITEM_INFO_RECEIVED` / `ContinuableContainer`).
- **Bank deposit matching** — tab deposit flag checks use `F.SafeNumber` on class/expansion fields from item records.
- **Delete Cheapest** — repaired stack-count pricing after a partial edit left broken `if`/`else` syntax.
- **Legacy filter prop cache** — `expansionID` from `GetItemInfo` is read via `F.SafeNumber` (no secret `~= nil` compare).
- **Item buttons (BetterBags #991)** — parent frames expose `IsCombinedBagContainer`; mouse wheel disabled so bag scroll boxes receive wheel events.
- **Frame levels** — `F.ClampFrameLevel` keeps computed levels in WoW's valid `[0, 65535]` range (BetterBags #990).
- **Batch layout** — always snapshot entry lists before deferred placement; cancel in-flight batches on combat/close/invalidate; fix `#buttons` cleanup when the array has holes; nil-guard `SetItemEntry`.
- **Midnight string fields** — sanitize `itemType`/`itemEquipLoc`/names from `GetItemInfo`; saved-search grouping and slot labels guard secret compares.
- **Async item refresh** — `RefreshItemID` now updates class/type/quality/icon fields; bind labels work without hyperlinks; prop cache invalidates on `GET_ITEM_INFO_RECEIVED`.
- **Pool prewarm** — estimate includes warband bank tab slots when both backpack and bank may be open.
- **Sort spam** — ignore repeat sort clicks while Blizzard sort is in flight; sort buttons dim until the post-sort refresh finishes (~0.35s after the last bag update).
- **ItemLoader** — static per-slot `Item` mixin cache (BetterBags pattern); ContinuableContainer reuses mixins instead of allocating per scan.
- **Pre-computed overlays** — ilvl, bind label, unusable tint, and Pawn upgrade arrows are resolved at scan time (`entry.showIlvl`, `showBindLabel`, `isUpgrade`); item buttons paint only.
- **Post-sort fast path** — after Blizzard sort, reuse prior category metadata when item IDs match instead of a full re-classify + search-cache wipe.
- **Audit fixes** — `ItemLoader` hyperlink fallback now resolves correctly (Lua local scoping); post-sort refresh no longer double-scans; classify runs after ilvl/bind are populated; search cache invalidates when sort introduces new item IDs.

## [1.3.0] - 2026-06-16

### Added

- **Open on Trade** — optional setting to open bags when a trade window appears.
- **Pet trash currencies** — grey pet-battle vendor items can stay out of Junk/auto-sell and group under Collections (NDui `PetTrash`).
- **Specialty bag bar colors** — tint equipped herb/enchanting/mining/etc. bag slots on the bag bar.
- **CanIMogIt** — shows learnable overlays when the CanIMogIt addon is installed.
- **Crafting quality overlay** — profession gear quality gems on item buttons when the API is available.

### Changed

- **Bag scan hardening** — secret/nil `itemID`, quality, class, and hyperlink guards before classify (BetterBags-style).
- **Bank free-slot count** — footer shows free slots for the selected bank tab when the tab bar is visible.
- **Bank close cleanup** — clears deposit target and pending money refresh state on close.

### Fixed

- **Legacy / Lower Level filters** — `C_Item.GetItemInfo` returns an ItemInfo table on Midnight; expansion ID was never read when using old multi-return unpacking, so those categories stopped matching.

### Removed

- **Quick Split** — dropped; it fought Merge Stacks (combined counts vs. real slot sizes) and Blizzard already supports shift-drag / right-click split on item buttons.

## [1.2.2] - 2026-06-16

### Fixed

- **Warband bank gold deposit** — right-click deposit opens the popup again; one secure proxy now routes left → withdraw and right → deposit (overlapping proxies blocked right-clicks after the withdraw fix).
- **Custom junk** — marking or unmarking junk immediately moves items into/out of the Junk category without sorting first.

## [1.2.1] - 2026-06-16

### Fixed

- **Warband bank gold** — left-click withdraw works again; deposit click proxy was layered above withdraw and swallowed left-clicks.
- **Warband bank gold deposit** — right-click deposit works again; single money proxy handles both mouse buttons (overlapping proxies blocked right-clicks).
- **Custom junk** — marking or clearing junk immediately moves items into/out of the Junk category (rescan on change, not only after sort).
- **Settings master toggles** — `enable` / `active` now always run `OnSettingChanged` after lifecycle hooks (Pawn arrows, Delete Cheapest button, category filters live-apply without `/reload`).
- **Pawn module** — `OnDisable` unregisters equipment events and clears upgrade arrows; prevents duplicate handlers on re-enable.
- **Categories module** — `OnDisable` unregisters zone-entry cache wipe; filter master toggle rescans immediately.
- **Bank window toggles** — disabling both bank views closes Bagforge UI instead of reopening at the banker; deposit-reagents CVar no longer overwrites saved settings on every enable.
- **Combat bank chrome** — secure purchase/money proxies rewire after combat ends.
- **Unusable item tint** — trusts `C_PlayerInfo.CanUseItem` when usable (fixes false red tints on legacy gear).

### Changed

- **Midnight secret guards** — item names, qualities, bind types, and expansion IDs gated before sort/search/compare; bag-bar equipped-bag tooltips wrapped in `pcall`.
- **Scan caches** — item name, expansion, max-stack, and sell-price caches bounded via `F.CacheSet` (800 entries).
- **Bind label cache** — bounded to 600 entries.
- **Cooldown refresh** — removed per-draw full-pool scan; relies on batched `BAG_UPDATE_COOLDOWN` handler.
- **Currency bar** — `CURRENCY_DISPLAY_UPDATE` refreshes only the token row, not the full backpack grid.
- **Category counts toggle** — relayout-only refresh (`RefreshBags(false)`) instead of full rescan.
- **Event bucket** — `F.BucketEvent` reuses a scratch args table to avoid per-fire allocations.

## [1.2.0] - 2026-06-16

### Added

- **Collapsible backpack toolbar** — sort and bag bar stay visible; assign, junk, delete, and delete-cheapest tuck behind a character-create arrow toggle (KkthnxUI-style).
- **Item button callback API** — `Bagforge.API:RegisterItemButtonCallback` and `RequestItemButtonsRefresh` for third-party bag overlays (e.g. TransmogLootHelper); mirrors OneWoW_Bags' integration pattern.
- **Vendor value sort** — sort items within each category by vendor sell price (highest first), with quality and name as tiebreakers.
- **Category item counts** — optional stack totals in category panel headers (e.g. `Equipment (24)`); toggle under Custom Categories settings.
- **Warband deposit highlighting** — while the Warband Bank is open, backpack items that cannot be deposited are dimmed so eligible items stand out.
- **Bank right-click deposit queue** — right-click backpack items to queue deposits into the selected purchased bank tab (tab bar must be enabled).
- **Bank tab deposit target** — left-click a purchased tab to select it as the deposit destination (blue highlight).
- **Scan-time sell price cache** — vendor values resolved during bag scan for junk totals, delete-cheapest, and vendor sort.
- **Scan-time unusable detection** — `C_PlayerInfo.CanUseItem` and class/level fallback cached at scan time for the unusable-item tint.
- **Combat-safe item button pool** — buttons pre-warmed at login; pool growth deferred until combat ends.
- **Bank batch layout** — large warband banks render in batches (80 slots per frame) to avoid UI hitches.
- **Backpack batch layout** — category panels and the main bag use the same batched placement.
- **Bag refresh coalescing** — trailing debounce on `BAG_UPDATE_DELAYED`, dirty-bag queues (BagBrother/BetterBags), and sort-gated flush so Blizzard sort storms trigger one rescan instead of many.
- **Recent GUID cache** — `Recent:Scan()` runs inside `Items:Scan()` when windows are open, avoiding a duplicate backpack walk per update.
- **Cooldown refresh bucket** — `BAG_UPDATE_COOLDOWN` batched at 200ms (BetterBags); only visible item buttons update, gated when all windows are closed.
- **Tooltip sell-price guard** — `TooltipDataProcessor` replaces Blizzard's MoneyFrame sell line (BagBrother anti-taint); secret prices are suppressed in combat.
- **Dynamic pool prewarm** — button pool sized from actual bag + bank slot counts at login (capped at 900).
- **Smart bag toggle debounce** — prevents double-fire when toggling bags with the `B` key.

### Fixed

- **Settings live-apply** — Item Info toggles, custom junk markers, and junk header price now bump `DrawEpoch` so overlays repaint immediately (rescan alone left `SectionSignature` unchanged).
- **Bank window toggle** — `bank.active` / `warband` no longer route through module enable (fixes stale bank window and duplicate event registration).
- **Bank sort** — sort button registers a post-sort flush so the open bank redraws once Blizzard's sort finishes (matches backpack coalescing).
- **Bank module teardown** — disabling both bank windows unregisters bank events/callbacks and restores Blizzard's bank frame; re-enabling reinstalls hooks.
- **Deposit queue** — stops retrying after 20 failures when the bank is full (no infinite timer).
- **Midnight hardening** — `pcall` on tooltip bind/unusable paths; secret guards on bind enums and `SetItemButtonQuality`; `maxStack` merge guard.
- **Combat** — defer Blizzard bag frame reparent to `PLAYER_REGEN_ENABLED` during combat lockdown.
- **Junk header** — async sell prices recompute section total; signature includes junk value and price toggle.
- **Deposit queue allocator** — fixed a name collision that broke right-click bank deposits.
- **Junk header formatting** — junk panel shows `Junk (count) - value` with formatted coin text.
- **Deposit queue semantics** — combat, locked items, and full tabs no longer swallow Blizzard's right-click; deposits pace one item per tick.
- **Deposit queue drain** — re-entry guard prevents overlapping drains; retryable failures stay queued instead of being dropped.
- **Secure bank actions** — tab purchase uses Blizzard's `BankPanelPurchaseButtonScriptTemplate` + `overrideBankType` (Baganator/BetterBags/Sorted pattern). Money transfer uses `InsecureActionButtonTemplate` click proxies to Blizzard withdraw/deposit buttons.
- **Unusable item tint** — trusts `C_PlayerInfo.CanUseItem` when it says an item is usable (fixes false red tints on legacy gear); class/level fallback only when the API is unavailable; removed tooltip red-line heuristics that flagged wrong stats.
- **Bank tab settings** — right-click purchased tabs opens Blizzard's native icon/name/filter editor (`BankPanelTabSettingsMenuTemplate`); was calling non-existent `BankFrame.BankTabSettingsMenu`. Tab icons and names refresh immediately on save (`BANK_TAB_SETTINGS_UPDATED`).
- **Item Info (Midnight)** — required-level and tooltip colour checks guard secret values before compare/arithmetic.
- **Plugin API** — `API:SafeSortNumber()` for secret-safe custom sort comparators; plugin sort errors fall back to itemID tiebreak.
- **Module lifecycle** — toggling `enable` / `active` in settings runs `OnDisable` / `OnEnable` (e.g. vendor automation unregisters `MERCHANT_SHOW` when off).
- **Right-click deposit routing** — works with the tab bar hidden (defaults to first purchased tab).
- **Reagent bag bar click** — Blizzard's `ContainerFrame6` no longer opens alongside Bagforge when clicking the reagent bag slot (global toggle replacement).
- **Warband Bank Convergence toy** — account-only banker access opens warband bank only; character bank tab hidden via `C_Bank.CanViewBank`, warband tab label still shown.
- **Warband bank deposit dim** — removed duplicate dark overlay; rely on Blizzard's `ItemContextOverlay` (was stacking ~75% + ~80% black).
- **Item level display** — read ilvl from `C_TooltipInfo.GetBagItem` so timewarped gear matches the tooltip (not scaled `GetDetailedItemLevelInfo` values like 509).
- **Bag slot highlight** — clear `BagIndicator` on all slots when unhighlighting or closing bags; fixes stuck blue tint on pooled/hidden buttons.
- **Bank drag relayout** — cancelling mid-batch layout clears layout signatures; drag stop invalidates and redraws so grids stay complete.
- **Drag tooltip cleanup** — active bag tooltips hide when dragging a window.
- **Backpack batch layout** — main panel uses the same 80-slot-per-frame batching as the bank.
- **Bag highlight performance** — tab/bag hover highlights use a per-bag index instead of scanning every slot.
- **Sort fallback** — secret `itemID` values no longer crash the stable sort fallback.
- **Midnight tooltips** — bag item tooltip show/hide wrapped in `pcall`; secret money skips pick-up hint; sell-price line uses `TooltipDataProcessor` instead of MoneyFrame.
- **Pool prewarm** — pool size follows equipped bag + purchased bank tab slot counts at login (400–900 cap) instead of a fixed 400.
- **Scan.lua `C` nil** — scanner module binds `ns.C` at load.
- **ItemButton drag** — fixed nil `GetFrameLevel` call when opening/dragging items.

## [1.1.0] - 2026-06-25

### Added

- **Bag slot hover highlighting** — hovering over equipped bags in the Bag Bar or bank tabs in the Bank window highlights the slots belonging to that bag in the window.
- **Blizzard bag filter settings** — right-clicking an equipped bag in the Bag Bar opens the native Blizzard filter menu to configure gear filters (Equipment, Consumables, Trade Goods, Junk) and ignore clean up/junk selling.
- **Bank tab settings** — right-clicking a bank tab in the Bank window triggers Blizzard's native tab popup editor to rename, change icons, and customize deposit/expansion filters.
- **Tooltip bindings & assignments** — equipped bag tooltips now display keybindings and active filters, and bank tab tooltips show deposit/expansion assignments.
- **Junk total price display** — the Junk panel header now displays the total gold value of all items categorized as junk, complete with coin texture icons.
- **Junk price toggle option** — added a settings checkbox under Backpack options to show or hide the junk total price display.
- **Category title color customization** — right-clicking any category header panel opens a context menu to customize the title text color via WoW's native color picker or reset it to the default yellow.

### Fixed

- **Character bag title possessive grammar** — updated English localization string to correctly show possessive ownership (e.g., "Formtroll's Bags" instead of "Formtroll Bags").

## [1.0.0] - 2026-06-16

### Added

- **Backpack window** — cargBags-style categorized layout with a main Bag panel, specialty category panels, search bar, sort controls, gold/currency footer, and movable frame with saved position.
- **Built-in category filters** — Recent Items, Junk, Equipment, Equipment Sets, Warbound Until Equipped, Legendary, Azerite Armor, Collections, Housing Decor, Reagents, Consumables, Quest Items, Anima, Primordial Stones, Legacy, and Lower Level buckets (each toggleable).
- **Custom categories** — manual item assignments, drag-drop onto panels, assign mode, `/bf cat` commands, header colours, and pinned draw order.
- **Saved search categories** — rule-based panels with a compact query language (field tests, flags, `tt:` tooltip tokens, OR/NOT).
- **Category Manager** — rename, recolour, reorder, enable/disable, and JSON import/export for custom and search categories.
- **Free-slot box** — trailing empty-slot counter that accepts click and drop to fill the next open slot.
- **Authenticator backpack slots** — Blizzard padlock slots and green **+** button when the account is not Battle.net Authenticator–secured.
- **Bag bar** — optional equipped-bag slot flyout.
- **Character bank window** — categorized panels, deposit-all, sort, money footer, purchased tabs, and tab-bar toggle.
- **Warband bank window** — separate categorized account-bank view.
- **Item display** — item level, bind labels, unusable tint, junk/custom markers, and configurable overlay corners.
- **Pawn integration** — optional upgrade arrow corner widget when Pawn is installed.
- **Organization tools** — stack merge, within-category sort (quality/name/ilvl/expansion), slot locks (Ctrl+right-click), flash-find (Alt-click), custom junk list, quick-delete mode, and delete-cheapest button.
- **Auto vendor** — optional auto-sell junk/custom junk and auto-repair at merchants.
- **Plugin API v2** — register categories, sort modes, and corner widgets from separate addons; per-source enable toggles in settings.
- **Slash commands** — `/bf` and `/bagforge` with sort, deposit, column, filter, category, and junk management.
- **Settings panel** — Blizzard Settings API integration with General, Item Display, Filters, Extras, and Plugins groups; live-apply toggles.
- **Midnight compatibility** — Secret-value guards, throttled tooltips, event-driven rescans, and Interface `120000+` support.

### Notes

- Initial public release for **World of Warcraft: Midnight** retail.
- Replaces Blizzard's default combined-bags UI while enabled.

[1.1.0]: https://github.com/Kkthnx-Wow/Bagforge/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Kkthnx-Wow/Bagforge/releases/tag/v1.0.0
