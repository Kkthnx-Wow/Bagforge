# Changelog

All notable changes to Bagforge are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
