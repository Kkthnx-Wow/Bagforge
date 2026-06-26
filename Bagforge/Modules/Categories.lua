--[[
	Bagforge - Categories
	-------------------------------------------------------------------------
	Item classifier used by the backpack view to group items into sections.
	This mirrors the filter set NDui ships for its cargBags layout (see NDui's
	Modules/Bags/Filters.lua + Core.lua), adapted to our single-category-per-item
	model. cargBags routes an item to the first container whose filter matches,
	so the *resolution order* below is the priority order (first match wins),
	while `Categories.order` controls where each panel is drawn (NDui's Index).

	Every specialty filter is individually toggleable through `ns.db.filters`
	(NDui gates each behind a checkbox the same way), with a master `enable`
	switch that collapses everything back into one bag when off.

	Contract: Items.lua calls `Categories:GetCategory(entry)` while scanning. The
	view never decides membership; it only renders what the data layer handed it.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local select = select
local next = next
local ipairs = ipairs
local format = string.format
local tsort = table.sort
local C_Item = C_Item
local C_ToyBox = C_ToyBox
local C_AzeriteEmpoweredItem = C_AzeriteEmpoweredItem
local C_Container = C_Container
local C_TooltipInfo = C_TooltipInfo
local REAGENT_BAG_INDEX = Enum.BagIndex and Enum.BagIndex.ReagentBag

-- Bind-detection enums mirrored from ItemInfo so IsWarbound can fall back to
-- a direct tooltip-data check when ItemInfo hasn't populated entry.bindLabel.
local LINE_ITEM_BINDING = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.ItemBinding
local BIND = Enum and Enum.TooltipDataItemBinding
local ITEM_BIND = Enum and Enum.ItemBind

-- dbKey "filters" binds our settings to ns.db.filters (flat table) so the
-- options builder can register each toggle directly. `enable` doubles as the
-- module's IsEnabled() master switch.
local Categories = ns:NewModule("Categories", "filters")
Categories.title = L["Item Filters"]
Categories.order = 20
Categories.group = "filters"

local ITEM_CLASS = Enum.ItemClass
local ITEM_QUALITY = Enum.ItemQuality
local MISC_SUBCLASS = Enum.ItemMiscellaneousSubclass
-- Items flagged from an expansion older than this count as "Legacy".
-- Bracket access dodges stale type-stub "undefined field" warnings on _G globals.
local CURRENT_EXPANSION = _G["LE_EXPANSION_LEVEL_CURRENT"] or 11

-- Filter defaults. Mirrors NDui's GUI defaults (FilterJunk/Consumable/Equipment/
-- Collection/AOE/Decor on by default; Goods/Quest/EquipSet/Azerite/Anima/Stone/
-- Legacy/Lower off), but we keep Goods (reagents) and Quest on to preserve
-- Bagforge's existing buckets, and add our own "recent" bucket.
ns:RegisterDefaults({
	filters = {
		enable = true, -- master switch (NDui ItemFilter)
		recent = true, -- Blizzard isNewItem flag
		junk = true, -- poor quality
		equipSet = true, -- member of an equipment set
		warbound = true, -- Warbound Until Equipped (NDui FilterAOE)
		azerite = false, -- Azerite empowered armor
		legendary = false, -- legendary-quality items (NDui FilterLegendary)
		legacy = false, -- gear from a previous expansion
		lowerLevel = false, -- gear below minItemLevel
		minItemLevel = 1, -- threshold for the lowerLevel filter
		equipment = true, -- weapons/armor
		collection = true, -- toys, mounts, battle pets
		primordialStone = false, -- Dragonflight primordial stones
		consumables = true, -- consumables + enhancements
		reagents = true, -- trade goods / reagents
		quest = true, -- quest items
		anima = false, -- Shadowlands anima
		decor = true, -- housing decor
	},
})

-- ---------------------------------------------------------------------------
-- Category names + display order (lower = drawn first). Mirrors NDui's Index.
-- ---------------------------------------------------------------------------
local CATEGORY_RECENT = L["Recent Items"]
local CATEGORY_AZERITE = L["Azerite Armor"]
local CATEGORY_EQUIPMENT = L["Equipment"]
local CATEGORY_EQUIPSET = L["Equipment Sets"]
-- Blizzard's own localized string (NDui labels its AOE bag the same way).
local CATEGORY_WARBOUND = _G["ITEM_ACCOUNTBOUND_UNTIL_EQUIP"] or L["Warbound Until Equipped"]
-- Blizzard's own localized string (NDui labels its Legendary bag the same way).
local CATEGORY_LEGENDARY = _G["LOOT_JOURNAL_LEGENDARIES"] or L["Legendary"]
local CATEGORY_COLLECTION = L["Collections"]
local CATEGORY_DECOR = L["Housing Decor"]
local CATEGORY_REAGENTS = L["Reagents"]
local CATEGORY_REAGENT_BAG = L["Reagent Bag"]
local CATEGORY_ANIMA = L["Anima"]
local CATEGORY_STONE = L["Primordial Stones"]
local CATEGORY_CONSUMABLES = L["Consumables"]
local CATEGORY_QUEST = L["Quest Items"]
local CATEGORY_LEGACY = L["Legacy"]
local CATEGORY_LOWER = L["Lower Level"]
local CATEGORY_JUNK = L["Junk"]
local CATEGORY_OTHER = L["Other"]

-- Display order of each category panel (lower = drawn first). File-local so it
-- doesn't collide with `Categories.order`, the module's options-sort weight.
local ORDER = {
	[CATEGORY_RECENT] = 5,
	[CATEGORY_AZERITE] = 7,
	[CATEGORY_LEGENDARY] = 7.5,
	[CATEGORY_EQUIPMENT] = 8,
	[CATEGORY_EQUIPSET] = 9,
	[CATEGORY_WARBOUND] = 10,
	[CATEGORY_COLLECTION] = 11,
	[CATEGORY_DECOR] = 12,
	[CATEGORY_REAGENT_BAG] = 6, -- NDui puts the reagent bag right above the main bag
	[CATEGORY_REAGENTS] = 13,
	[CATEGORY_ANIMA] = 14,
	[CATEGORY_STONE] = 15,
	[CATEGORY_CONSUMABLES] = 16,
	[CATEGORY_QUEST] = 17,
	[CATEGORY_LEGACY] = 18,
	[CATEGORY_LOWER] = 19,
	[CATEGORY_JUNK] = 20,
	[CATEGORY_OTHER] = 100,
}

-- Custom categories and saved search categories aren't in the ORDER table; draw
-- them near the top (just above Recent Items at 5) unless the player pinned a
-- specific order. Shared by GetSearchCategory and GetOrder.
local CUSTOM_CATEGORY_ORDER = 4

-- ---------------------------------------------------------------------------
-- Per-itemID property cache
--   Toy/anima/decor/azerite/warbound status is intrinsic to an item type, so we
--   resolve it once per unique itemID and reuse it across every rescan instead
--   of re-querying the API for the same stack every BAG_UPDATE. Session-scoped;
--   the set of distinct items a player touches is small and bounded in practice.
-- ---------------------------------------------------------------------------
local propCache = {}

local function GetProps(itemID)
	if not itemID or F.IsSecret(itemID) then
		return nil
	end
	local p = propCache[itemID]
	if p == nil then
		p = {}
		p.anima = C_Item.IsAnimaItemByID and C_Item.IsAnimaItemByID(itemID) or false
		p.decor = C_Item.IsDecorItem and C_Item.IsDecorItem(itemID) or false
		p.azerite = C_AzeriteEmpoweredItem and C_AzeriteEmpoweredItem.IsAzeriteEmpoweredItemByID and C_AzeriteEmpoweredItem.IsAzeriteEmpoweredItemByID(itemID) or false
		propCache[itemID] = p
	end

	-- Toy: tri-state nil = unknown, true/false = resolved once C_ToyBox has data.
	if p.toy == nil then
		if C_ToyBox and C_ToyBox.GetToyInfo then
			local toyInfo = C_ToyBox.GetToyInfo(itemID)
			if toyInfo ~= nil then
				p.toy = true
			elseif C_Item.GetItemInfo(itemID) then
				p.toy = false
			end
		else
			p.toy = false
		end
	end

	-- expacID for legacy/lower filters; only finalise once GetItemInfo returns.
	if p.expacID == nil then
		local _, _, _, _, _, _, _, _, _, _, _, _, _, _, expacID = C_Item.GetItemInfo(itemID)
		if expacID ~= nil then
			p.expacID = expacID
		end
	end

	return p
end

-- Dragonflight primordial stones (4 socketable stones + the Onyx Annulet shard).
-- IDs are static legacy content, so a literal range is safe and cheap.
local primordialStones = {}
for id = 204000, 204030 do
	primordialStones[id] = true
end
for id = 204573, 204579 do
	primordialStones[id] = true
end
primordialStones[203703] = true -- Primordial Stones (Onyx Annulet shard)

-- ---------------------------------------------------------------------------
-- Detection helpers (entry fields come from Items:Scan)
-- ---------------------------------------------------------------------------
local function IsGearClass(entry)
	return entry.classID == ITEM_CLASS.Weapon or entry.classID == ITEM_CLASS.Armor
end

-- NDui's CheckEquip: real gear above common quality (poor gear is junk first).
local function IsUpgradeGear(entry)
	local q = entry.quality
	return IsGearClass(entry) and F.NotSecret(q) and q > ITEM_QUALITY.Common
end

-- Effective item level, only computed for the legacy/lower filters that need it.
local function GearItemLevel(entry)
	return entry.ilvl
end

local function IsJunk(entry)
	local q = entry.quality
	if F.NotSecret(q) and q == ITEM_QUALITY.Poor then
		return true
	end
	-- Custom junk (Modules/Organize): items the player flagged are grouped here
	-- too. itemID is the table key, so guard against a secret value first.
	local junk = ns.global and ns.global.customJunk
	if junk then
		local id = entry.itemID
		if id and F.NotSecret(id) and junk[id] then
			return true
		end
	end
	return false
end

local function IsConsumable(entry)
	return entry.classID == ITEM_CLASS.Consumable or entry.classID == ITEM_CLASS.ItemEnhancement
end

local function IsTradeGood(entry)
	return entry.classID == ITEM_CLASS.Tradegoods or (ITEM_CLASS.Reagent and entry.classID == ITEM_CLASS.Reagent)
end

local function IsQuestItem(entry)
	return entry.quest or entry.questID ~= nil or entry.classID == ITEM_CLASS.Questitem
end

local function IsCollection(entry)
	local p = GetProps(entry.itemID)
	if p and p.toy then
		return true
	end
	-- Mounts and battle pets are Miscellaneous items with a specific subclass.
	return entry.classID == ITEM_CLASS.Miscellaneous and entry.subClassID and (entry.subClassID == MISC_SUBCLASS.Mount or entry.subClassID == MISC_SUBCLASS.CompanionPet)
end

local function IsWarbound(entry)
	if entry.isBound then
		return false
	end
	-- Primary: ItemInfo populated bindLabel at scan time (the normal path).
	if entry.bindLabel ~= nil then
		return entry.bindLabel == "WuE"
	end
	-- Fallback: ItemInfo wasn't active or item data wasn't cached at scan time.
	-- Mirror ItemInfo:GetBindLabel's two-stage detection so the filter still works
	-- when the module is unavailable. We cache the positive result on the entry so
	-- repeated calls per draw are free; a ContinuableContainer rebuild will
	-- overwrite with the same value once ItemInfo resolves it properly.
	if entry.bag and entry.slot and C_TooltipInfo and C_TooltipInfo.GetBagItem and BIND then
		local data = C_TooltipInfo.GetBagItem(entry.bag, entry.slot)
		if data and data.lines then
			for i = 2, #data.lines do
				local line = data.lines[i]
				if line.type == LINE_ITEM_BINDING then
					local bonding = line.bonding
					if bonding == BIND.AccountUntilEquipped or bonding == BIND.BindToAccountUntilEquipped then
						entry.bindLabel = "WuE"
						return true
					end
					-- Non-WuE binding confirmed: leave bindLabel nil so a later
					-- ContinuableContainer rebuild can fill it through ItemInfo.
					return false
				end
			end
		end
	end
	-- Last resort: GetItemInfo bindType (covers clients without C_TooltipInfo).
	if ITEM_BIND and entry.hyperlink and C_Item and C_Item.GetItemInfo then
		local bindType = select(14, C_Item.GetItemInfo(entry.hyperlink))
		if bindType ~= nil then
			if bindType == ITEM_BIND.ToBnetAccountUntilEquipped then
				entry.bindLabel = "WuE"
				return true
			end
			return false
		end
	end
	return false
end

local function IsAzerite(entry)
	local p = GetProps(entry.itemID)
	return p and p.azerite
end

-- NDui's FilterLegendary: any legendary-quality item (orange).
local function IsLegendary(entry)
	local q = entry.quality
	return F.NotSecret(q) and q == ITEM_QUALITY.Legendary
end

local function IsAnima(entry)
	local p = GetProps(entry.itemID)
	return p and p.anima
end

local function IsDecor(entry)
	local p = GetProps(entry.itemID)
	return p and p.decor
end

local function IsPrimordialStone(entry)
	return entry.itemID and primordialStones[entry.itemID]
end

local function IsLegacy(entry)
	if not IsUpgradeGear(entry) then
		return false
	end
	local p = GetProps(entry.itemID)
	return p and p.expacID and p.expacID < CURRENT_EXPANSION
end

local function IsLowerLevel(entry, threshold)
	if not IsUpgradeGear(entry) then
		return false
	end
	local ilvl = GearItemLevel(entry)
	return F.NotSecret(ilvl) and ilvl < (threshold or 1)
end

-- ---------------------------------------------------------------------------
-- Classification (first match wins == cargBags container resolution order)
-- ---------------------------------------------------------------------------
--- A reagent bag is equipped when the reagent bag slot reports container slots.
local function HasReagentBag()
	return REAGENT_BAG_INDEX and (C_Container.GetContainerNumSlots(REAGENT_BAG_INDEX) or 0) > 0
end

local function IsAccountBankEntry(entry)
	return C.IS_ACCOUNT_BANK_BAG and C.IS_ACCOUNT_BANK_BAG[entry.bag]
end

--- The dedicated reagent-bag panel (cargBags style). Exposed so the backpack can
--- force the panel to show (with its free-slot box) even when it's empty.
function Categories:GetReagentBagCategory()
	return CATEGORY_REAGENT_BAG
end

function Categories:HasReagentBag()
	return HasReagentBag()
end

-- Custom user assignment (Modules/Organize): an explicit itemID -> name map the
-- player controls. Checked before every built-in rule (and independent of the
-- filter master switch) so an assignment is absolute - BetterBags' behaviour.
local function GetCustomCategory(entry)
	local o = ns.db and ns.db.organize
	if not (o and o.customEnable) then
		return nil
	end
	local id = entry.itemID
	if not id or F.IsSecret(id) then
		return nil
	end
	return o.assignments[id]
end

-- Saved search categories (Modules/Organize): named rules that grab matching
-- items. Evaluated after explicit per-item assignments (which are absolute) but
-- before any built-in filter, and independent of the filter master switch - same
-- standing as custom categories. Among multiple matching searches the lowest
-- draw order wins (name breaks ties) so priority is predictable.
-- Saved-search winner cache (Baganator CategoryFilter pattern): per stable item
-- key, remember which search won so duplicate stacks don't re-run every query.
-- Cleared when saved searches change (Search.Invalidate -> InvalidateSearchCache).
local searchWinnerCache = {}
local sortedSearches

local function ItemSearchKey(entry)
	local link = entry.hyperlink
	if link and F.NotSecret(link) then
		return link
	end
	local id = entry.itemID
	if id and F.NotSecret(id) then
		return "id:" .. tostring(id)
	end
	return nil
end

function Categories:InvalidateSearchCache()
	wipe(searchWinnerCache)
	sortedSearches = nil
end

local function GetSortedSearches()
	if sortedSearches then
		return sortedSearches
	end
	local o = ns.db and ns.db.organize
	sortedSearches = {}
	if not (o and o.searches) then
		return sortedSearches
	end
	for name, def in pairs(o.searches) do
		if def.enabled ~= false and def.query and def.query ~= "" then
			sortedSearches[#sortedSearches + 1] = {
				name = name,
				def = def,
				order = def.order or CUSTOM_CATEGORY_ORDER,
			}
		end
	end
	tsort(sortedSearches, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.name < b.name
	end)
	return sortedSearches
end

local function QualityLabel(quality)
	if quality == nil or F.IsSecret(quality) then
		return nil
	end
	local label = _G["ITEM_QUALITY" .. quality .. "_DESC"]
	return label or format(L["Quality %d"], quality)
end

local function SlotLabel(entry)
	local loc = entry.itemEquipLoc
	if not loc or loc == "" then
		return nil
	end
	return _G[loc] or loc
end

local function ExpansionName(expacID)
	if not expacID then
		return nil
	end
	return _G["EXPANSION_NAME" .. expacID] or format(L["Expansion %d"], expacID)
end

local function GroupSuffix(entry, groupBy)
	if groupBy == "type" then
		return entry.itemType
	elseif groupBy == "subtype" then
		return entry.itemSubType
	elseif groupBy == "expansion" then
		return ExpansionName(entry.expacID)
	elseif groupBy == "quality" then
		return QualityLabel(entry.quality)
	elseif groupBy == "slot" then
		return SlotLabel(entry)
	end
	return nil
end

local function ApplyGroupFromDef(bestName, entry, def)
	local groupBy = def and def.groupBy
	if groupBy and groupBy ~= "none" then
		local suffix = GroupSuffix(entry, groupBy)
		if suffix and suffix ~= "" then
			return bestName .. ": " .. suffix
		end
	end
	return bestName
end

local function GetSearchCategory(entry)
	local o = ns.db and ns.db.organize
	-- next() so the common "no saved searches" case costs one check per item
	-- instead of entering the pairs() loop (this runs for every scanned slot).
	if not (o and o.searchEnable and o.searches and next(o.searches)) then
		return nil
	end
	local Search = ns.Search
	if not Search then
		return nil
	end

	-- Cache only the winning saved-search NAME per stable item key.
	-- The suffix (quality/slot/etc) is still derived per entry.
	local key = ItemSearchKey(entry)
	local cachedBestName = key and searchWinnerCache[key]
	if cachedBestName and o.searches[cachedBestName] then
		return ApplyGroupFromDef(cachedBestName, entry, o.searches[cachedBestName])
	end

	local bestName, bestOrder
	for name, def in pairs(o.searches) do
		if def.enabled ~= false and def.query and def.query ~= "" and Search.Match(def.query, entry) then
			local ord = def.order or CUSTOM_CATEGORY_ORDER
			if not bestName or ord < bestOrder or (ord == bestOrder and name < bestName) then
				bestName, bestOrder = name, ord
			end
		end
	end
	if not bestName then
		return nil
	end

	if key then
		searchWinnerCache[key] = bestName
	end
	return ApplyGroupFromDef(bestName, entry, o.searches[bestName])
end

function Categories:GetCategory(entry)
	-- Player-assigned category wins over everything, even with filters disabled.
	local custom = GetCustomCategory(entry)
	if custom then
		return custom
	end

	-- Saved search rules come next (also independent of the master switch).
	local search = GetSearchCategory(entry)
	if search then
		return search
	end

	-- Plugin categories (Bagforge.API:RegisterCategory): contributed by other
	-- addons. They rank after the player's own custom/search categories but ahead
	-- of the built-in filters, and are gated per-source on the settings Plugins
	-- page. The API pcall-guards each plugin filter.
	if ns.API then
		local plugin = ns.API:GetItemCategory(entry)
		if plugin then
			return plugin
		end
	end

	local f = ns.db and ns.db.filters
	-- Master switch off (or DB not ready yet): everything lands in one bag.
	if not f or not f.enable then
		return CATEGORY_OTHER
	end

	-- NDui's account/warband bank uses a smaller filter set than bags/character
	-- bank: AccountEquipment, AccountConsumable, AccountGoods, AccountAOE, and
	-- AccountLegacy only. Notably, there is no AccountQuest filter.
	if IsAccountBankEntry(entry) then
		if f.warbound and IsWarbound(entry) then
			return CATEGORY_WARBOUND
		end
		if f.legacy and IsLegacy(entry) then
			return CATEGORY_LEGACY
		end
		if f.equipment and IsGearClass(entry) then
			return CATEGORY_EQUIPMENT
		end
		if f.consumables and IsConsumable(entry) then
			return CATEGORY_CONSUMABLES
		end
		if f.reagents and IsTradeGood(entry) then
			return CATEGORY_REAGENTS
		end
		return CATEGORY_OTHER
	end

	if f.recent and entry.isNewItem then
		return CATEGORY_RECENT
	end
	if f.junk and IsJunk(entry) then
		return CATEGORY_JUNK
	end
	if f.equipSet and entry.isInSet then
		return CATEGORY_EQUIPSET
	end
	if f.warbound and IsWarbound(entry) then
		return CATEGORY_WARBOUND
	end
	if f.azerite and IsAzerite(entry) then
		return CATEGORY_AZERITE
	end
	if f.legendary and IsLegendary(entry) then
		return CATEGORY_LEGENDARY
	end
	if f.legacy and IsLegacy(entry) then
		return CATEGORY_LEGACY
	end
	if f.lowerLevel and IsLowerLevel(entry, f.minItemLevel) then
		return CATEGORY_LOWER
	end
	if f.equipment and IsGearClass(entry) then
		return CATEGORY_EQUIPMENT
	end
	if f.collection and IsCollection(entry) then
		return CATEGORY_COLLECTION
	end
	if f.primordialStone and IsPrimordialStone(entry) then
		return CATEGORY_STONE
	end
	if f.consumables and IsConsumable(entry) then
		return CATEGORY_CONSUMABLES
	end
	-- Reagent bag (cargBags): when one is equipped, trade goods (and anything
	-- physically in the reagent bag) collect in their own panel; otherwise trade
	-- goods fall back to the by-type Reagents bucket.
	if f.reagents and HasReagentBag() and (entry.bag == REAGENT_BAG_INDEX or IsTradeGood(entry)) then
		return CATEGORY_REAGENT_BAG
	end
	if f.reagents and IsTradeGood(entry) then
		return CATEGORY_REAGENTS
	end
	if f.quest and IsQuestItem(entry) then
		return CATEGORY_QUEST
	end
	if f.anima and IsAnima(entry) then
		return CATEGORY_ANIMA
	end
	if f.decor and IsDecor(entry) then
		return CATEGORY_DECOR
	end

	return CATEGORY_OTHER
end

function Categories:GetOrder(category)
	local o = ns.db and ns.db.organize
	-- Pinned order override (Modules/Organize) wins for any category.
	if o and o.order then
		local pinned = o.order[category]
		if pinned then
			return pinned
		end
	end

	local builtin = ORDER[category]
	if builtin then
		return builtin
	end

	-- Saved search categories carry their own order; their group-by sub-panels
	-- ("<search>: <suffix>") inherit it so they cluster with their parent.
	if o and o.searches then
		local def = o.searches[category]
		if not def then
			local base = category:match("^(.-): ")
			if base then
				def = o.searches[base]
			end
		end
		if def then
			return def.order or CUSTOM_CATEGORY_ORDER
		end
	end

	-- Plugin category order (Bagforge.API:RegisterCategory), so a plugin panel
	-- can set its place without the player pinning it.
	if ns.API then
		local pluginOrder = ns.API:GetCategoryOrder(category)
		if pluginOrder then
			return pluginOrder
		end
	end

	return CUSTOM_CATEGORY_ORDER
end

--- The main "Bag" panel (cargBags/NDui) holds everything that didn't land in
--- a specialty filter. In our classifier that's the Other bucket.
function Categories:GetMainCategory()
	return CATEGORY_OTHER
end

function Categories:IsMainPanel(categoryName)
	return categoryName == CATEGORY_OTHER
end

-- ---------------------------------------------------------------------------
-- Filter toggles (driven by /bf filter)
--   Booleans only, except minItemLevel which takes a number argument. Order
--   here is just the listing order shown to the user.
-- ---------------------------------------------------------------------------
local FILTER_KEYS = {
	"enable",
	"recent",
	"junk",
	"equipSet",
	"warbound",
	"azerite",
	"legendary",
	"legacy",
	"lowerLevel",
	"equipment",
	"collection",
	"primordialStone",
	"consumables",
	"reagents",
	"quest",
	"anima",
	"decor",
}

-- Map lowercased aliases back to canonical keys (slash input is lowercased).
local FILTER_ALIASES = {}
for _, key in ipairs(FILTER_KEYS) do
	FILTER_ALIASES[key:lower()] = key
end

local function GetFilters()
	return ns.db and ns.db.filters
end

--- Apply a filter change and rebuild the bag view. `key`/`value` already come
--- lowercased from the slash handler.
function Categories:HandleCommand(arg)
	local f = GetFilters()
	if not f then
		return
	end

	-- Filter names/values are all lowercase; the slash dispatcher now preserves
	-- case for other commands, so normalise here.
	local key, value = (arg or ""):lower():match("^(%S*)%s*(.*)$")

	-- No key: list every filter and its state.
	if not key or key == "" then
		F.Print(L["Item filters"] .. " (|cffffd200/bf filter <name> on|off|cffffffff):|r")
		for _, name in ipairs(FILTER_KEYS) do
			local state = f[name] and ("|cff55ff55" .. L["on"] .. "|r") or ("|cffff5555" .. L["off"] .. "|r")
			F.Print(format(L["  %s - %s"], name, state))
		end
		return
	end

	-- minItemLevel takes a number rather than on/off.
	if key == "minitemlevel" or key == "ilvl" then
		local num = tonumber(value)
		if num then
			f.minItemLevel = num
			F.Print(format(L["Lower level threshold set to %d."], num))
			ns:RefreshBags(true)
		else
			F.Print(L["Usage: /bf filter ilvl <number>"])
		end
		return
	end

	local canonical = FILTER_ALIASES[key]
	if not canonical then
		F.Print(format(L["Unknown filter: %s"], key))
		return
	end

	if value == "on" or value == "true" or value == "1" then
		f[canonical] = true
	elseif value == "off" or value == "false" or value == "0" then
		f[canonical] = false
	else
		f[canonical] = not f[canonical]
	end

	local state = f[canonical] and L["on"] or L["off"]
	F.Print(format(L["Filter %s is now %s."], canonical, state))

	ns:RefreshBags(true)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function Categories:OnEnable()
	-- propCache stores per-itemID properties (toy, anima, decor, azerite, expacID)
	-- that are truly static for an item type. However, the toy tri-state can get
	-- stuck if C_ToyBox returned inconclusive data before the toy database was
	-- fully loaded (which completes a few seconds after login). Clearing on zone
	-- entry ensures the next scan resolves any previously ambiguous toy flags and
	-- picks up correct expacID data for all items in the new environment.
	self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
		wipe(propCache)
	end)
end

-- ---------------------------------------------------------------------------
-- Settings panel (each filter is a live checkbox; rebuild on change)
-- ---------------------------------------------------------------------------
--- Re-classify and redraw whenever any filter toggle changes. A filter changes
--- item *membership*, so this rescans (true) rather than just repainting.
function Categories:OnSettingChanged()
	ns:RefreshBags(true)
end

function Categories:RegisterOptions(category, builder)
	local _, master = builder:Checkbox(category, self, "enable", L["Enable Item Filters"], L["Sort bag items into category panels. Off keeps everything in one bag."])

	-- Every specialty filter depends on the master switch.
	local function Filter(key, name, tooltip)
		local _, init = builder:Checkbox(category, self, key, name, tooltip)
		builder:DependsOn(init, master)
		return init
	end

	Filter("recent", L["Recent Items"], L["Group items flagged as newly looted."])
	Filter("junk", L["Junk"], L["Group poor-quality (grey) items."])
	Filter("equipSet", L["Equipment Sets"], L["Group items that belong to an equipment set."])
	Filter("warbound", L["Warbound Until Equipped"], L["Group account-bound-until-equipped items."])
	Filter("azerite", L["Azerite Armor"], L["Group Azerite-empowered armor."])
	Filter("legendary", L["Legendary"], L["Group legendary-quality items."])
	Filter("equipment", L["Equipment"], L["Group weapons and armor."])
	Filter("collection", L["Collections"], L["Group toys, mounts and battle pets."])
	Filter("consumables", L["Consumables"], L["Group consumables and enhancements."])
	Filter("reagents", L["Reagents"], L["Group trade goods and crafting reagents."])
	Filter("quest", L["Quest Items"], L["Group quest items."])
	Filter("decor", L["Housing Decor"], L["Group housing decor items."])
	Filter("anima", L["Anima"], L["Group Shadowlands anima items."])
	Filter("primordialStone", L["Primordial Stones"], L["Group Dragonflight primordial stones."])
	Filter("legacy", L["Legacy"], L["Group gear from previous expansions."])

	local lowerInit = Filter("lowerLevel", L["Lower Level"], L["Group gear below the item-level threshold below."])
	local _, ilvlInit = builder:Slider(category, self, "minItemLevel", L["Lower Level Threshold"], L["Gear under this item level is grouped as Lower Level."], 1, 800, 1)
	builder:DependsOn(ilvlInit, lowerInit)
end
