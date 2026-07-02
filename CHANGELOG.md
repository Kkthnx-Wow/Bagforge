# Changelog

All notable changes to Bagforge are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **Tooltip unusable cache** — red-line tooltip detection cached at scan time for the unusable-item tint.
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
- **Warband bank gold** — left-click withdraw works again; deposit click proxy was layered above withdraw and swallowed left-clicks; tooltip hover overlay removed in favor of the withdraw proxy.
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
