--[[
	Bagforge - Scan (shared bag scanner)
	-------------------------------------------------------------------------
	One reusable scanner that walks a list of bag IDs, builds a flat sorted list
	of occupied slots plus a free-slot tally, and groups them into per-category
	sections. The backpack and every bank view each own one instance, so they
	never share scratch state, but the scan/sort/section logic lives in exactly
	one place instead of being copy-pasted across Items.lua and Bank.lua.

	A scanner is pure data: it knows nothing about frames, secure code or which
	window owns it. Callers pass the bag list to Run() and read the results off
	the instance (`slots`, `sections`, `freeSlots`, `totalSlots`).

	Incremental scan (default hot path)
	------------------------------------
	Loot and most settings changes never call Run() on the whole bag list:

	  BAG_UPDATE → dirty bags → CollectDirtySlotKeys → Run(..., dirtySlotKeys)
	    → _BuildSlotDiff → changeset on scanner.lastChangeset

	With stack merge off, add/remove patch section lists in place (no
	_FinalizeBuild); UI relayouts only dirtyCategories.

	Settings / overlays use targeted meta: methods below; wire through
	ns:ApplyScannerRefresh in Items.lua (backpack + bank, finalize fallback).

	Changeset fields (scanner.lastChangeset)
	  added, removed, updated     — entry refs that moved
	  dirtyCategories             — section names needing layout or patch
	  incremental                 — true when UI can PatchEntry in place
	  structureChanged            — category membership moved between panels
	  needsFinalize               — section patch failed; caller must full Run()

	Draw (ContainerWindow.DrawCategorized): incremental + not structureChanged
	→ PatchChangedEntries; else structural Layout on dirtyCategories.

	In-place refresh APIs (return changed, needsFinalize unless noted)
	RefreshCategories      — filter/plugin/custom/search toggle (frame-budgeted)
	  RefreshSortOrder       — within-category sort mode
	  RefreshStackMerge      — enable merge only (disable → needsFinalize)
	  RefreshCategoryOrders  — order pin / manager reorder
	  RefreshItemCategory    — one itemID assignment or junk flag
	  RenameCategorySection  — custom category rename
	  RefreshRecentFlags     — bulk recent/new-item reclassify
	  RefreshRecentSlot      — one slot after Recent:Clear or new-item signal
	  RefreshFiltered        — Blizzard search desaturate flag (returns changed)
	  RefreshItemID          — GET_ITEM_INFO (returns changed, junk, finalize)
	  RefreshDisplayFields   — Pawn/ItemInfo overlay paint
	  RefreshUnusable        — unusable tint paint
	  RefreshQuestState      — quest overlay + quest-driven category
	  RefreshLock            — single-slot lock overlay (PatchSlot)

	Full Run() reserved for: login, BAG_CONTAINER_UPDATE, stack-merge disable,
	needsFinalize fallback, _scanDirty open. See bagforge-conventions.mdc.

	Item and container metadata used by the scanner is plain data in the 12.0.7 API docs.
--]]

local _, ns = ...
local C, L, F = ns.C, ns.L, ns.F

local C_Container = C_Container
local C_Item = C_Item
local ItemLocation = ItemLocation
local GetContainerItemEquipmentSetInfo = C_Container.GetContainerItemEquipmentSetInfo
local GetContainerItemID = C_Container.GetContainerItemID
local GetItemInventoryTypeByID = C_Item.GetItemInventoryTypeByID
local IsItemDataCachedByID = C_Item and C_Item.IsItemDataCachedByID
local RequestLoadItemDataByID = C_Item and C_Item.RequestLoadItemDataByID
local ipairs = ipairs
local tsort = table.sort
local wipe = wipe
local type = type
local pcall = pcall
local C_Timer = C_Timer

local ITEM_CLASS_WEAPON = Enum.ItemClass.Weapon
local ITEM_CLASS_ARMOR = Enum.ItemClass.Armor
local ITEM_CLASS_TRADEGOODS = Enum.ItemClass.Tradegoods

-- Intrinsic per-itemID facts the scanner needs for merging, search and sorting:
-- max stack size, display name and expansion id. All come from one GetItemInfo
-- call (the slow API) so we never call it three times for the same item, and
-- they're cached because they can't change for an item type. Any field is nil
-- until GetItemInfo has the item cached; the ContinuableContainer await in Run()
-- guarantees a complete rebuild pass once the data arrives.
local maxStackCache = {}
local nameCache = {}
local expacCache = {}
local sellPriceCache = {}

local function GetBasics(itemID)
	if not itemID then
		return nil, nil, nil
	end
	local maxStack = maxStackCache[itemID]
	if maxStack ~= nil then
		return maxStack, nameCache[itemID], expacCache[itemID]
	end
	local info = F.GetItemInfoRecord(itemID)
	if info then
		local stack = info.itemStackCount
		local name = info.itemName
		local expacID = info.expansionID
		if stack then
			F.CacheSet(maxStackCache, itemID, stack, 800)
		end
		if name then
			F.CacheSet(nameCache, itemID, name, 800)
		end
		if expacID ~= nil then
			F.CacheSet(expacCache, itemID, expacID, 800)
		end
		return stack, name, expacID
	end
	return nil, nil, nil
end

local function GetSellPrice(itemID, hyperlink)
	if not itemID then
		return nil
	end
	local cached = sellPriceCache[itemID]
	if cached ~= nil then
		return cached or nil
	end
	local price
	local info = hyperlink and F.GetItemInfoRecord(hyperlink)
	if not info then
		info = F.GetItemInfoRecord(itemID)
	end
	if info then
		price = info.sellPrice
	end
	if price ~= nil then
		F.CacheSet(sellPriceCache, itemID, price, 800)
		return price
	end
	return nil
end

local function CacheUnusable(entry, itemInfo)
	entry.isUnusable = false
	if not itemInfo then
		return
	end
	local db = ns.db and ns.db.itemInfo
	if not (db and db.enable and db.unusable) then
		return
	end
	entry.isUnusable = itemInfo:IsUnusable(entry) and true or false
end

--- Pre-compute overlay fields the item button reads at paint time (BetterBags
--- Phase 5: presentation-only buttons). Refreshed on scan, item-ID refresh, and
--- when Pawn/ItemInfo toggles change.
local function ApplyDisplayFields(entry, itemInfo)
	if itemInfo then
		entry.bindLabel = itemInfo:GetBindLabel(entry)
		entry.ilvl = itemInfo:GetItemLevel(entry)
		CacheUnusable(entry, itemInfo)
	else
		entry.bindLabel = nil
		entry.ilvl = nil
		entry.isUnusable = false
	end

	local db = ns.db and ns.db.itemInfo
	entry.showIlvl = false
	if db and db.enable and db.itemLevel then
		local level = entry.ilvl
		entry.showIlvl = level and level > 0
	end

	entry.showBindLabel = nil
	if db and db.enable and db.bindText and entry.bindLabel then
		entry.showBindLabel = entry.bindLabel
	end

	entry.isUpgrade = false
	if ns.db and ns.db.pawn and ns.db.pawn.enable then
		local pawn = ns:GetModule("Pawn")
		if pawn and pawn.IsUpgrade and entry.hyperlink then
			entry.isUpgrade = pawn:IsUpgrade(entry.hyperlink) and true or false
		end
	end
end

local ContinuableContainer = _G["ContinuableContainer"]
local ItemMixinClass = _G["Item"]
local ItemLoader = ns.ItemLoader
local HasAsyncLoad = (ContinuableContainer and ItemMixinClass and ItemMixinClass.CreateFromBagAndSlot and IsItemDataCachedByID and ItemLoader) and true or false
ns.ScanHasAsyncLoad = HasAsyncLoad

local function ResolveHyperlink(bag, slot, info, record)
	local hyperlink = info and info.hyperlink
	if not hyperlink and record and record.itemLink then
		hyperlink = record.itemLink
	elseif not hyperlink then
		hyperlink = ItemLoader.GetItemLink(bag, slot)
	end
	return hyperlink
end

-- Instance quality (bonus IDs / upgrades), not base itemID quality.
-- GetItemQualityByID(itemID) alone returns the template — often Uncommon/green
-- while the bag slot is Epic/purple. Baganator live buttons use cache/container
-- quality; only bank *bag* chrome re-paints with GetItemQualityByID(itemID).
local function ResolveItemQuality(bag, slot, info, record, itemID, hyperlink)
	local quality = info and info.quality
	if quality == nil and bag and slot and ItemLocation and C_Item.GetItemQuality then
		local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
		if loc and C_Item.DoesItemExist and C_Item.DoesItemExist(loc) then
			quality = C_Item.GetItemQuality(loc)
		end
	end
	if quality == nil then
		quality = record and record.itemQuality
	end
	if quality == nil and hyperlink and C_Item.GetItemQualityByID then
		-- ItemInfo accepts a full link — keeps bonus-ID quality.
		quality = C_Item.GetItemQualityByID(hyperlink)
	end
	if quality == nil and itemID and C_Item.GetItemQualityByID then
		quality = C_Item.GetItemQualityByID(itemID)
	end
	return quality
end

local function ApplyQuestFields(entry, questInfo)
	if not questInfo then
		entry.quest = false
		entry.questID = nil
		entry.isActiveQuest = false
		return
	end
	local quest = questInfo.isQuestItem
	entry.quest = quest and true or false
	entry.questID = questInfo.questID
	local active = questInfo.isActive
	entry.isActiveQuest = active and true or false
end

--- Stack-merge key for an entry: only stackable items merge, and only by a key
--- that means "truly the same item" - the full hyperlink (encodes bonus IDs /
--- enchants) when readable, else the itemID. Returns nil for anything that
--- should never merge (unique gear or uncached max stack).
local function MergeKey(entry)
	local maxStack = entry.maxStack
	if not (maxStack and maxStack > 1) then
		return nil
	end
	local organize = ns.db and ns.db.organize
	if organize and organize.dontMergePartial then
		local count = entry.count or 1
		if count < maxStack then
			return nil
		end
	end
	local link = entry.hyperlink
	if link then
		return link
	end
	local id = entry.itemID
	if id then
		return id
	end
	return nil
end

local Scan = {}
ns.Scan = Scan

function Scan.ClearItemCaches()
	wipe(maxStackCache)
	wipe(nameCache)
	wipe(expacCache)
	wipe(sellPriceCache)
	if ItemLoader and ItemLoader.Clear then
		ItemLoader.Clear()
	end
end

--- Cached vendor sell price per itemID (shared with Transfers / Delete Cheapest).
function Scan.GetSellPrice(itemID, hyperlink)
	return GetSellPrice(itemID, hyperlink)
end

function Scan.RefreshUnusableAll()
	local itemInfo = ns:GetModule("ItemInfo")
	if itemInfo and itemInfo.InvalidateUnusableCaches then
		itemInfo:InvalidateUnusableCaches()
	end
	if ns.ApplyScannerRefresh then
		ns:ApplyScannerRefresh(function(scanner)
			return scanner:RefreshUnusable()
		end)
	end
end

function Scan.RefreshDisplayFieldsAll()
	if ns.ApplyScannerRefresh then
		ns:ApplyScannerRefresh(function(scanner)
			return scanner:RefreshDisplayFields()
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Sorting (Baganator-style key chains)
--   Category order first (so panels draw in a stable order), then category
--   NAME (so two categories that share an order stay contiguous). Within a
--   category the player's "Item Sort" choice selects a key chain (class, slot,
--   subclass, ilvl, expansion, quality, name, itemID) rather than a single-field
--   comparator. Custom class/subclass/slot order tables come from Baganator's
--   ItemFields.lua (Phraxik's ordering). Plugin sort modes still register a
--   bespoke comparator via Scan.RegisterWithin.
-- ---------------------------------------------------------------------------
local function BuildSortMap(list)
	local map = {}
	for index, id in ipairs(list) do
		map[id] = index
	end
	return map
end

local SORTED_CLASS = BuildSortMap({
	18,
	0,
	5,
	6,
	2,
	4,
	11,
	3,
	8,
	16,
	1,
	7,
	19,
	9,
	10,
	12,
	13,
	14,
	15,
	17,
})
local SORTED_WEAPON_SUB = BuildSortMap({
	0,
	4,
	7,
	9,
	15,
	13,
	11,
	12,
	19,
	1,
	5,
	8,
	6,
	10,
	2,
	18,
	3,
	16,
	17,
	14,
	20,
})
local SORTED_ARMOR_SUB = BuildSortMap({
	6,
	7,
	8,
	9,
	10,
	11,
	4,
	3,
	2,
	1,
	0,
	5,
})
local SORTED_TRADEGOOD_SUB = BuildSortMap({
	18,
	1,
	4,
	7,
	6,
	5,
	12,
	16,
	10,
	9,
	8,
	11,
	0,
	2,
	3,
	13,
	14,
	15,
	17,
})
local SORTED_INV_SLOT = BuildSortMap({
	17,
	13,
	21,
	14,
	23,
	26,
	22,
	15,
	25,
	24,
	27,
	28,
	1,
	3,
	16,
	5,
	20,
	9,
	10,
	6,
	7,
	8,
	2,
	11,
	12,
	4,
	19,
	29,
	30,
	18,
	31,
	32,
	33,
	34,
	0,
})

local function SortedLookup(map, id)
	return map[id] or ((id or 0) + 200)
end

local function SortedSubClassID(entry)
	local classID = entry.classID
	local subClassID = entry.subClassID
	if classID == ITEM_CLASS_WEAPON then
		return SortedLookup(SORTED_WEAPON_SUB, subClassID)
	elseif classID == ITEM_CLASS_ARMOR then
		return SortedLookup(SORTED_ARMOR_SUB, subClassID)
	elseif classID == ITEM_CLASS_TRADEGOODS then
		return SortedLookup(SORTED_TRADEGOOD_SUB, subClassID)
	end
	return subClassID or 200
end

local function IsEquipment(entry)
	local classID = entry.classID
	return classID == ITEM_CLASS_WEAPON or classID == ITEM_CLASS_ARMOR
end

local function SafeSortNumber(value, fallback)
	if value == nil then
		return fallback
	end
	return value
end

local function SortValue(entry, key)
	if key == "quality" then
		return SafeSortNumber(entry.quality, 0)
	elseif key == "invertedQuality" then
		return -SafeSortNumber(entry.quality, 0)
	elseif key == "sortedClassID" then
		return SortedLookup(SORTED_CLASS, entry.classID)
	elseif key == "sortedInvSlotID" then
		return SortedLookup(SORTED_INV_SLOT, entry.invSlotID)
	elseif key == "sortedSubClassID" then
		return SortedSubClassID(entry)
	elseif key == "itemLevelRaw" then
		return SafeSortNumber(entry.ilvl, -1)
	elseif key == "invertedItemLevelRaw" then
		return -SafeSortNumber(entry.ilvl, -1)
	elseif key == "invertedItemLevelEquipment" then
		if IsEquipment(entry) then
			return -SafeSortNumber(entry.ilvl, -1)
		end
		return 0
	elseif key == "invertedExpansion" then
		return -SafeSortNumber(entry.expacID, 0)
	elseif key == "itemName" then
		local name = entry.name
		return name or ""
	elseif key == "invertedItemID" then
		return -SafeSortNumber(entry.itemID, 0)
	elseif key == "invertedItemCount" then
		return -SafeSortNumber(entry.count, 1)
	elseif key == "invertedVendorValue" then
		local price = entry.sellPrice
		if price then
			return -price
		end
		return 0
	end
	return 0
end

local function CompareKey(a, b, key)
	local ka, kb = SortValue(a, key), SortValue(b, key)
	if type(ka) == "string" and type(kb) == "string" then
		if ka ~= kb then
			return ka < kb
		end
		return nil
	end
	if ka ~= kb then
		return ka < kb
	end
	return nil
end

local function CompareItemID(a, b)
	local aid, bid = a.itemID, b.itemID
	if aid and bid then
		return aid < bid
	end
	return F.SlotKey(a.bag, a.slot) < F.SlotKey(b.bag, b.slot)
end

local function MakeKeyChainComparator(keys)
	return function(a, b)
		for i = 1, #keys do
			local cmp = CompareKey(a, b, keys[i])
			if cmp ~= nil then
				return cmp
			end
		end
		return CompareItemID(a, b)
	end
end

-- Baganator Order.lua chains, adapted: quality mode keeps higher quality first
-- (invertedQuality) to match Bagforge's historical behaviour.
local KEY_CHAINS = {
	quality = { "invertedQuality", "sortedClassID", "sortedInvSlotID", "sortedSubClassID", "itemLevelRaw", "invertedExpansion", "itemName", "invertedItemID", "invertedItemCount" },
	name = { "sortedClassID", "sortedInvSlotID", "sortedSubClassID", "invertedExpansion", "itemName", "invertedItemLevelRaw", "invertedQuality", "invertedItemID", "invertedItemCount" },
	ilvl = { "invertedItemLevelEquipment", "sortedClassID", "sortedInvSlotID", "sortedSubClassID", "invertedExpansion", "invertedQuality", "invertedItemLevelRaw", "itemName", "invertedItemID", "invertedItemCount" },
	expansion = { "invertedExpansion", "sortedClassID", "sortedInvSlotID", "sortedSubClassID", "invertedItemLevelRaw", "invertedQuality", "itemName", "invertedItemID", "invertedItemCount" },
	vendor = { "invertedVendorValue", "invertedQuality", "sortedClassID", "sortedInvSlotID", "sortedSubClassID", "itemLevelRaw", "invertedExpansion", "itemName", "invertedItemID", "invertedItemCount" },
}

local WITHIN = {
	quality = MakeKeyChainComparator(KEY_CHAINS.quality),
	name = MakeKeyChainComparator(KEY_CHAINS.name),
	ilvl = MakeKeyChainComparator(KEY_CHAINS.ilvl),
	expansion = MakeKeyChainComparator(KEY_CHAINS.expansion),
	vendor = MakeKeyChainComparator(KEY_CHAINS.vendor),
}

-- Swapped by Scan.SetSortMode; defaults to the historical quality-first chain.
local activeWithin = WITHIN.quality

-- Built-in modes; the rest of WITHIN is filled by plugins (Scan.RegisterWithin).
local BUILTIN_WITHIN = { quality = true, name = true, ilvl = true, expansion = true, vendor = true }

--- Set the within-category item sort ("quality" | "name" | "ilvl" |
--- "expansion", plus any plugin-registered key). Unknown values fall back to
--- quality. Callers rescan after.
function Scan.SetSortMode(mode)
	activeWithin = WITHIN[mode] or WITHIN.quality
end

--- Register a plugin within-category comparator (Bagforge.API:RegisterSortMode).
--- The closure is wrapped so a non-boolean or erroring result degrades to the
--- stable itemID tiebreak rather than corrupting the sort.
function Scan.RegisterWithin(key, comparator)
	if type(key) ~= "string" or type(comparator) ~= "function" then
		return false
	end
	WITHIN[key] = function(a, b)
		local ok, res = pcall(comparator, a, b)
		if ok and type(res) == "boolean" then
			return res
		end
		-- A broken plugin comparator still falls back to stable item ordering.
		return CompareItemID(a, b)
	end
	return true
end

--- For plugin sort comparators: use instead of raw numeric compare on scan fields.
function Scan.SafeSortNumber(value, fallback)
	return SafeSortNumber(value, fallback)
end

function Scan.HasBuiltinWithin(key)
	return BUILTIN_WITHIN[key] == true
end

local function CompareEntries(a, b)
	if a.categoryOrder ~= b.categoryOrder then
		return a.categoryOrder < b.categoryOrder
	end
	if a.category ~= b.category then
		return a.category < b.category
	end
	return activeWithin(a, b)
end

-- Guaranteed strict-weak fallback used if a plugin's within-comparator yields an
-- inconsistent order (Lua's table.sort raises "invalid order function" then).
local function SafeCompare(a, b)
	if a.categoryOrder ~= b.categoryOrder then
		return a.categoryOrder < b.categoryOrder
	end
	if a.category ~= b.category then
		return a.category < b.category
	end
	local aid, bid = a.itemID, b.itemID
	if aid and bid then
		return aid < bid
	end
	return SlotKey(a.bag, a.slot) < SlotKey(b.bag, b.slot)
end

local function SlotKey(bag, slot)
	return F.SlotKey(bag, slot)
end

local function EntryIsNewItem(bag, slot, guid)
	local recent = ns.Recent
	if recent and recent.IsEntryNew then
		return recent:IsEntryNew(bag, slot, guid)
	end
	return false
end

local meta = {}
meta.__index = meta

--- Create a scanner with its own entry/section free-lists and result tables.
function Scan.New()
	return setmetatable({
		slots = {},
		sections = {},
		freeSlots = 0,
		totalSlots = 0,
		-- Reused free-lists so a refresh storm doesn't churn the GC.
		_entryPool = {},
		_entryCount = 0,
		_sectionPool = {},
		_sectionCount = 0,
		sectionsByName = {},
		-- O(1) bag/slot lookup: keyed by SlotKey(bag, slot). Rebuilt in _Build.
		slotsByKey = {},
		-- O(1) itemID lookup: itemID -> array of entry refs. Rebuilt in _Build.
		-- Multiple entries can share an itemID (different stacks of the same type).
		entriesByItemID = {},
	}, meta)
end

function meta:_AcquireEntry()
	self._entryCount = self._entryCount + 1
	local entry = self._entryPool[self._entryCount]
	if not entry then
		entry = {}
		self._entryPool[self._entryCount] = entry
	end
	return entry
end

function meta:_AcquireSection()
	self._sectionCount = self._sectionCount + 1
	local section = self._sectionPool[self._sectionCount]
	if not section then
		section = { items = {} }
		self._sectionPool[self._sectionCount] = section
	end
	wipe(section.items)
	section.junkValue = nil
	return section
end

--- Group the (already sorted) slot list into contiguous per-category sections.
--- Search no longer filters here: Blizzard's bag search desaturates non-matching
--- items in place (via entry.isFiltered), so every item stays in its section.
function meta:_BuildSections()
	self._sectionCount = 0
	wipe(self.sections)
	wipe(self.sectionsByName)

	local lastCategory
	local currentSection
	local junkCategory = L["Junk"]
	for i = 1, #self.slots do
		local entry = self.slots[i]
		if entry.category ~= lastCategory then
			currentSection = self:_AcquireSection()
			currentSection.name = entry.category
			currentSection.order = entry.categoryOrder
			self.sections[#self.sections + 1] = currentSection
			self.sectionsByName[entry.category] = currentSection
			lastCategory = entry.category
		end
		currentSection.items[#currentSection.items + 1] = entry
		if entry.category == junkCategory then
			local sellPrice = entry.sellPrice
			if sellPrice and sellPrice > 0 then
				local count = entry.count or 1
				currentSection.junkValue = (currentSection.junkValue or 0) + (sellPrice * count)
			end
		end
	end
end

--- Build per-itemID classification metadata for post-sort fast refresh.
local function BuildFastMetaPool(slots)
	local pool = {}
	for i = 1, #slots do
		local e = slots[i]
		local id = e.itemID
		if id then
			pool[id] = {
				name = e.name,
				expacID = e.expacID,
				maxStack = e.maxStack,
				classID = e.classID,
				subClassID = e.subClassID,
				itemType = e.itemType,
				itemSubType = e.itemSubType,
				itemEquipLoc = e.itemEquipLoc,
				invSlotID = e.invSlotID,
				sellPrice = e.sellPrice,
			}
		end
	end
	return pool
end

local function GetFastMeta(pool, itemID)
	return pool[itemID]
end

local function ApplyFastMeta(entry, meta)
	if meta.name then
		entry.name = meta.name
	end
	if meta.expacID then
		entry.expacID = meta.expacID
	end
	if meta.maxStack then
		entry.maxStack = meta.maxStack
	end
	if meta.classID then
		entry.classID = meta.classID
	end
	if meta.subClassID then
		entry.subClassID = meta.subClassID
	end
	if meta.itemType then
		entry.itemType = meta.itemType
	end
	if meta.itemSubType then
		entry.itemSubType = meta.itemSubType
	end
	if meta.itemEquipLoc then
		entry.itemEquipLoc = meta.itemEquipLoc
	end
	if meta.invSlotID then
		entry.invSlotID = meta.invSlotID
	end
	if meta.sellPrice then
		entry.sellPrice = meta.sellPrice
	end
end

--- Populate one entry from a live bag slot. When `fastMeta` is set, reuse prior
--- classification when an itemID match is available (post-Blizzard-sort path).
local function PopulateEntryFromSlot(self, entry, bag, slot, ctx)
	local info = C_Container.GetContainerItemInfo(bag, slot)
	local itemID = info and info.itemID
	if not itemID then
		itemID = GetContainerItemID(bag, slot)
	end
	if not itemID then
		return false
	end

	if IsItemDataCachedByID and not IsItemDataCachedByID(itemID) then
		self._incomplete = true
		if RequestLoadItemDataByID then
			local requested = self._loadRequested
			if not requested then
				requested = {}
				self._loadRequested = requested
			end
			if not requested[itemID] then
				requested[itemID] = true
				RequestLoadItemDataByID(itemID)
			end
		end
	end

	local questInfo = C_Container.GetContainerItemQuestInfo(bag, slot)
	local instant = F.GetItemInfoInstantRecord(itemID)
	local record = F.GetItemInfoRecord(itemID)
	local classID = instant and instant.classID
	local subClassID = instant and (instant.subclassID or instant.subClassID)
	local itemType = instant and instant.itemType
	local itemSubType = instant and instant.itemSubType
	local itemEquipLoc = instant and instant.itemEquipLoc
	if not classID and record then
		classID = record.classID
	end
	if not subClassID and record then
		subClassID = record.subclassID or record.subClassID
	end
	if not itemType and record then
		itemType = record.itemType
	end
	if not itemSubType and record then
		itemSubType = record.itemSubType
	end
	if not itemEquipLoc and record then
		itemEquipLoc = record.itemEquipLoc
	end
	local hyperlink = ResolveHyperlink(bag, slot, info, record)
	-- Container / link / ItemLocation first — never prefer bare itemID quality
	-- (bonus-ID epics look Uncommon via GetItemQualityByID(itemID)).
	local quality = ResolveItemQuality(bag, slot, info, record, itemID, hyperlink)

	entry.bag = bag
	entry.slot = slot
	entry.key = SlotKey(bag, slot)
	entry.itemID = itemID
	entry.quality = quality or 0
	entry.icon = info and info.iconFileID
	if not entry.icon and instant and instant.itemTexture then
		entry.icon = instant.itemTexture
	end
	entry.count = info and info.stackCount or 1
	local maxStack, name, expacID = GetBasics(itemID)
	entry.maxStack = maxStack
	entry.name = name
	entry.expacID = expacID
	entry.hyperlink = hyperlink
	entry.isLocked = info and info.isLocked == true
	entry.isBound = info and info.isBound == true
	entry.readable = info and info.isReadable == true
	entry.noValue = info and info.hasNoValue == true
	entry.isFiltered = info and info.isFiltered == true
	entry.itemGUID = ns.Recent and ns.Recent.GetSlotGUID and ns.Recent:GetSlotGUID(bag, slot) or nil
	entry.isNewItem = EntryIsNewItem(bag, slot, entry.itemGUID) and true or false
	ApplyQuestFields(entry, questInfo)
	-- inSet is a bool (ContainerDocumentation); normalize like isLocked/isBound.
	local inSet = GetContainerItemEquipmentSetInfo and GetContainerItemEquipmentSetInfo(bag, slot)
	entry.isInSet = inSet == true
	entry.itemType = itemType
	entry.itemSubType = itemSubType
	entry.itemEquipLoc = itemEquipLoc
	entry.classID = classID
	entry.subClassID = subClassID
	local inv = GetItemInventoryTypeByID and GetItemInventoryTypeByID(itemID)
	entry.invSlotID = inv or 0

	entry.sellPrice = GetSellPrice(itemID, hyperlink)
	ApplyDisplayFields(entry, ctx.itemInfo)

	local fastMeta = ctx.fastMeta and GetFastMeta(ctx.fastMeta, itemID)
	if fastMeta then
		ApplyFastMeta(entry, fastMeta)
	elseif ctx.fastMeta then
		ctx.fastMisses = (ctx.fastMisses or 0) + 1
	end
	local categories = ns:GetModule("Categories")
	entry.category = categories and categories:GetCategory(entry) or L["Other"]
	entry.categoryOrder = categories and categories:GetOrder(entry.category) or 100
	if ns.Search and ns.Search.IndexEntry then
		ns.Search.IndexEntry(entry)
	end
	return true
end

--- Synchronous build: walk `bags`, classify each occupied slot through the
--- shared Categories module, sort, and build sections. Results land on the
--- instance. Sets self._incomplete when any occupied item's data isn't cached
--- yet (so ilvl/bind may be missing); Run() uses that to schedule an await.
local function CountBagFreeAndTotal(bags)
	local free, total = 0, 0
	for _, bag in ipairs(bags) do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		total = total + numSlots
		for slot = 1, numSlots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local itemID = info and info.itemID
			if not itemID then
				itemID = GetContainerItemID(bag, slot)
			end
			if not itemID then
				if not info or not info.iconFileID then
					free = free + 1
				end
			end
		end
	end
	return free, total
end

local function PrepareBuildCtx(self, invalidateSearch)
	self._incomplete = false
	if self._loadRequested then
		wipe(self._loadRequested)
	end
	local categories = ns:GetModule("Categories")
	if invalidateSearch and categories and categories.InvalidateSearchCache then
		categories:InvalidateSearchCache()
	end
	return {
		categories = categories,
		itemInfo = ns:GetModule("ItemInfo"),
	}
end

local function ScanBagIntoSlots(self, bag, buildCtx)
	local numSlots = C_Container.GetContainerNumSlots(bag) or 0
	for slot = 1, numSlots do
		local info = C_Container.GetContainerItemInfo(bag, slot)
		local itemID = info and info.itemID
		if not itemID then
			itemID = GetContainerItemID(bag, slot)
		end
		if itemID then
			local entry = self:_AcquireEntry()
			if PopulateEntryFromSlot(self, entry, bag, slot, buildCtx) then
				self.slots[#self.slots + 1] = entry
			end
		end
	end
end

--- Debounced onComplete: ContinuableContainer's second pass coalesces with the
--- immediate build into one Items.Updated / bank DrawLayout (BetterBags-style).
function meta:_ScheduleScanComplete(onComplete)
	if not onComplete then
		return
	end
	if not self._scanCompleteDebounce then
		self._scanCompleteDebounce = F.DebounceNoArgs(0.05, function()
			local cb = self._scanCompletePending
			self._scanCompletePending = nil
			if cb then
				cb(self)
			end
		end)
	end
	self._scanCompletePending = onComplete
	self._scanCompleteDebounce()
end

function meta:_Build(bags)
	self._entryCount = 0
	wipe(self.slots)
	self:_ResetChangeset()
	local buildCtx = PrepareBuildCtx(self, true)
	for _, bag in ipairs(bags) do
		ScanBagIntoSlots(self, bag, buildCtx)
	end
	local free, total = CountBagFreeAndTotal(bags)
	self:_FinalizeBuild(free, total)
	return self
end

local function RemoveEntryFromSlots(slots, entry)
	for i = 1, #slots do
		if slots[i] == entry then
			local last = #slots
			if i < last then
				slots[i] = slots[last]
			end
			slots[last] = nil
			return true
		end
	end
	return false
end

local function SectionRemoveEntry(section, entry)
	local items = section.items
	for i = 1, #items do
		if items[i] == entry then
			local last = #items
			if i < last then
				items[i] = items[last]
			end
			items[last] = nil
			return true
		end
	end
	return false
end

--- Insert one entry into a section using the active within-category sort.
local function SectionInsertSorted(section, entry)
	local items = section.items
	local n = #items
	for i = 1, n do
		if activeWithin(entry, items[i]) then
			for j = n, i, -1 do
				items[j + 1] = items[j]
			end
			items[i] = entry
			return
		end
	end
	items[n + 1] = entry
end

--- Move an entry between existing sections without a full sort/merge pass.
local function EnsureSection(self, categoryName, categoryOrder)
	local sec = self.sectionsByName[categoryName]
	if sec then
		return sec
	end
	sec = self:_AcquireSection()
	sec.name = categoryName
	sec.order = categoryOrder
	local sections = self.sections
	local insertAt = #sections + 1
	for i = 1, #sections do
		local order = sections[i].order
		if order and categoryOrder and order > categoryOrder then
			insertAt = i
			break
		end
	end
	table.insert(sections, insertAt, sec)
	self.sectionsByName[categoryName] = sec
	return sec
end

local function MoveEntryBetweenSections(self, entry, fromCat, toCat, junkCategory)
	if not (fromCat and toCat and fromCat ~= toCat) then
		return false
	end
	local fromSec = self.sectionsByName[fromCat]
	if not fromSec then
		return false
	end
	local toSec = self.sectionsByName[toCat]
	if not toSec then
		toSec = EnsureSection(self, toCat, entry.categoryOrder)
	end
	if not SectionRemoveEntry(fromSec, entry) then
		return false
	end
	SectionInsertSorted(toSec, entry)
	if junkCategory and (fromCat == junkCategory or toCat == junkCategory) then
		self:RecomputeJunkSectionValue()
	end
	return true
end

local function SnapshotEntryPaint(entry)
	return {
		name = entry.name,
		icon = entry.icon,
		quality = entry.quality,
		showIlvl = entry.showIlvl,
		showBindLabel = entry.showBindLabel,
		isUpgrade = entry.isUpgrade,
		isUnusable = entry.isUnusable,
		classID = entry.classID,
		subClassID = entry.subClassID,
	}
end

local function EntryPaintChanged(snap, entry)
	return entry.name ~= snap.name
		or entry.icon ~= snap.icon
		or entry.quality ~= snap.quality
		or entry.showIlvl ~= snap.showIlvl
		or entry.showBindLabel ~= snap.showBindLabel
		or entry.isUpgrade ~= snap.isUpgrade
		or entry.isUnusable ~= snap.isUnusable
		or entry.classID ~= snap.classID
		or entry.subClassID ~= snap.subClassID
end

--- Apply a category change on a live entry; move section lists when possible.
local function TryApplyCategoryChange(self, entry, newCat, changeset, junkCategory)
	local oldCat = entry.category
	if not newCat or oldCat == newCat then
		return false, false
	end
	local categories = ns:GetModule("Categories")
	entry.category = newCat
	entry.categoryOrder = categories and categories:GetOrder(newCat) or entry.categoryOrder
	if MoveEntryBetweenSections(self, entry, oldCat, newCat, junkCategory) then
		changeset.dirtyCategories[oldCat] = true
		changeset.dirtyCategories[newCat] = true
		changeset.structureChanged = true
		return true, false
	end
	changeset.needsFinalize = true
	return true, true
end

local function MarkEntryOverlayUpdate(changeset, entry)
	changeset.updated[#changeset.updated + 1] = entry
	changeset.dirtyCategories[entry.category] = true
	if ns.Search and ns.Search.IndexEntry then
		ns.Search.IndexEntry(entry)
	end
end

local function FinalizeOverlayChangeset(changeset, opts)
	if changeset.needsFinalize or changeset.structureChanged then
		changeset.incremental = false
	elseif #changeset.updated > 0 then
		if opts and opts.searchFilter then
			local hide = ns.db and ns.db.organize and ns.db.organize.searchHideNonMatches
			changeset.incremental = not hide
		else
			changeset.incremental = true
		end
	end
end

local function RebuildLookupTables(self)
	wipe(self.slotsByKey)
	wipe(self.entriesByItemID)
	for i = 1, #self.slots do
		local e = self.slots[i]
		self.slotsByKey[e.key] = e
		local id = e.itemID
		if id then
			local list = self.entriesByItemID[id]
			if not list then
				list = {}
				self.entriesByItemID[id] = list
			end
			list[#list + 1] = e
		end
	end
end

function meta:_ResetChangeset()
	local cs = self._changeset
	if not cs then
		cs = {
			added = {},
			removed = {},
			updated = {},
			dirtyCategories = {},
		}
		self._changeset = cs
	else
		wipe(cs.added)
		wipe(cs.removed)
		wipe(cs.updated)
		wipe(cs.dirtyCategories)
	end
	cs.needsFinalize = false
	cs.incremental = false
	cs.structureChanged = false
	self.lastChangeset = cs
	return cs
end

local function SlotHasItem(bag, slot)
	local info = C_Container.GetContainerItemInfo(bag, slot)
	local itemID = info and info.itemID
	if not itemID then
		itemID = GetContainerItemID(bag, slot)
	end
	return itemID
end

local function SlotSnapshotChanged(bag, slot, old)
	local itemID = SlotHasItem(bag, slot)
	if not itemID then
		return old ~= nil
	end
	if not old then
		return true
	end
	if old.itemID ~= itemID then
		return true
	end
	local info = C_Container.GetContainerItemInfo(bag, slot)
	local rawCount = info and info.stackCount
	local count = rawCount or 1
	return count ~= old.count
end

--- Before scan: compare dirty bags to the live scanner and return only slot
--- keys that actually moved (skips no-op BAG_UPDATE storms).
function Scan.CollectDirtySlotKeys(scanner, bags, dirtyBags, outKeys)
	if not (scanner and dirtyBags and next(dirtyBags)) then
		return nil
	end
	local keys = outKeys or {}
	wipe(keys)
	local any = false
	for i = 1, #bags do
		local bag = bags[i]
		if dirtyBags[bag] then
			local numSlots = C_Container.GetContainerNumSlots(bag) or 0
			for slot = 1, numSlots do
				local key = SlotKey(bag, slot)
				if SlotSnapshotChanged(bag, slot, scanner.slotsByKey[key]) then
					keys[key] = true
					any = true
				end
			end
		end
	end
	return any and keys or nil
end

local function ProcessSlotDiff(self, bag, slot, buildCtx, changeset, stackMerge, junkCategory)
	local key = SlotKey(bag, slot)
	local old = self.slotsByKey[key]
	local itemID = SlotHasItem(bag, slot)

	if not itemID then
		if old then
			RemoveEntryFromSlots(self.slots, old)
			self.slotsByKey[key] = nil
			local sec = self.sectionsByName[old.category]
			if sec and not SectionRemoveEntry(sec, old) then
				changeset.needsFinalize = true
			end
			changeset.removed[#changeset.removed + 1] = old
			changeset.dirtyCategories[old.category] = true
			changeset.structureChanged = true
			if stackMerge then
				changeset.needsFinalize = true
			end
		end
		return
	end

	if not old then
		local entry = self:_AcquireEntry()
		if PopulateEntryFromSlot(self, entry, bag, slot, buildCtx) then
			self.slots[#self.slots + 1] = entry
			self.slotsByKey[key] = entry
			changeset.added[#changeset.added + 1] = entry
			changeset.dirtyCategories[entry.category] = true
			changeset.structureChanged = true
			if stackMerge then
				changeset.needsFinalize = true
			else
				local sec = EnsureSection(self, entry.category, entry.categoryOrder)
				if sec then
					SectionInsertSorted(sec, entry)
				else
					changeset.needsFinalize = true
				end
			end
		end
		return
	end

	local oldID = old.itemID
	local oldCat = old.category
	local oldCount = old.count
	local paintSnap = SnapshotEntryPaint(old)
	if PopulateEntryFromSlot(self, old, bag, slot, buildCtx) then
		local paintChanged = EntryPaintChanged(paintSnap, old)
		local structureLocal = old.itemID ~= oldID or old.category ~= oldCat or (stackMerge and old.count ~= oldCount)
		if paintChanged or structureLocal then
			changeset.updated[#changeset.updated + 1] = old
			changeset.dirtyCategories[old.category] = true
		end
		if structureLocal then
			changeset.structureChanged = true
			if oldCat ~= old.category then
				if not MoveEntryBetweenSections(self, old, oldCat, old.category, junkCategory) then
					changeset.needsFinalize = true
				else
					changeset.dirtyCategories[oldCat] = true
				end
			elseif stackMerge then
				changeset.needsFinalize = true
			else
				local sec = self.sectionsByName[old.category]
				if sec and SectionRemoveEntry(sec, old) then
					SectionInsertSorted(sec, old)
				else
					changeset.needsFinalize = true
				end
			end
		end
		if stackMerge and old.count ~= oldCount then
			changeset.needsFinalize = true
		end
	else
		RemoveEntryFromSlots(self.slots, old)
		self.slotsByKey[key] = nil
		local sec = self.sectionsByName[old.category]
		if sec then
			SectionRemoveEntry(sec, old)
		end
		changeset.removed[#changeset.removed + 1] = old
		changeset.dirtyCategories[old.category] = true
		changeset.structureChanged = true
		if stackMerge then
			changeset.needsFinalize = true
		end
	end
end

--- Per-slot diff on dirty bags or explicit slot keys. Fast path skips sort/
--- sections when only display fields on existing entries changed.
function meta:_BuildSlotDiff(bags, dirtyBags, dirtySlotKeys)
	local changeset = self:_ResetChangeset()
	local buildCtx = PrepareBuildCtx(self, false)
	local stackMerge = ns.db and ns.db.organize and ns.db.organize.stackMerge
	local junkCategory = L["Junk"]

	if dirtySlotKeys and next(dirtySlotKeys) then
		for key in pairs(dirtySlotKeys) do
			local bag = F.SlotBag(key)
			local slot = F.SlotIndex(key)
			ProcessSlotDiff(self, bag, slot, buildCtx, changeset, stackMerge, junkCategory)
		end
	else
		for _, bag in ipairs(bags) do
			if dirtyBags[bag] then
				local numSlots = C_Container.GetContainerNumSlots(bag) or 0
				for slot = 1, numSlots do
					ProcessSlotDiff(self, bag, slot, buildCtx, changeset, stackMerge, junkCategory)
				end
			end
		end
	end

	local free, total = CountBagFreeAndTotal(bags)
	self.freeSlots = free
	self.totalSlots = total

	if changeset.needsFinalize then
		self:_FinalizeBuild(free, total)
		changeset.incremental = false
	else
		RebuildLookupTables(self)
		if changeset.dirtyCategories[junkCategory] then
			self:RecomputeJunkSectionValue()
		end
		changeset.incremental = #changeset.updated > 0 and not changeset.structureChanged
	end
	return self
end

--- Patch one bag/slot without a full bag walk (lock/quest hot paths).
function meta:PatchSlot(bags, bag, slot)
	if not (bag and slot and #self.slots > 0) then
		return self.lastChangeset
	end
	local keys = self._patchSlotKeys or {}
	wipe(keys)
	keys[SlotKey(bag, slot)] = true
	self._patchSlotKeys = keys
	self:_BuildSlotDiff(bags, nil, keys)
	return self.lastChangeset
end

--- Sort, section, and rebuild lookup tables after the slot list is populated.
function meta:_FinalizeBuild(free, total)
	if ns.db and ns.db.organize and ns.db.organize.stackMerge then
		self:_MergeStacks()
	end

	if not pcall(tsort, self.slots, CompareEntries) then
		pcall(tsort, self.slots, SafeCompare)
	end
	self:_BuildSections()

	self.freeSlots = free
	self.totalSlots = total

	local byKey = self.slotsByKey
	wipe(byKey)
	local byID = self.entriesByItemID
	wipe(byID)
	for i = 1, #self.slots do
		local e = self.slots[i]
		byKey[e.key] = e
		local id = e.itemID
		if id then
			local list = byID[id]
			if not list then
				list = {}
				byID[id] = list
			end
			list[#list + 1] = e
		end
	end
end

--- Post-Blizzard-sort fast path: re-walk slots, reuse cached item metadata,
--- always reclassify from live fields. Falls back to Run() when no prior scan
--- exists or too many slots need re-classification.
function meta:RefreshAfterSort(bags, onComplete)
	if #self.slots == 0 then
		self:Run(bags, onComplete)
		return
	end

	local categories = ns:GetModule("Categories")
	if not categories then
		self:Run(bags, onComplete)
		return
	end

	local fastMeta = BuildFastMetaPool(self.slots)
	if categories.InvalidateSearchCache then
		categories:InvalidateSearchCache()
	end
	self._entryCount = 0
	self._incomplete = false
	if self._loadRequested then
		wipe(self._loadRequested)
	end
	wipe(self.slots)

	local itemInfo = ns:GetModule("ItemInfo")
	local ctx = {
		categories = categories,
		itemInfo = itemInfo,
		fastMeta = fastMeta,
		fastMisses = 0,
	}
	local free, total = 0, 0
	local occupied = 0

	for _, bag in ipairs(bags) do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		total = total + numSlots
		for slot = 1, numSlots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local itemID = info and info.itemID
			if not itemID then
				itemID = GetContainerItemID(bag, slot)
			end
			if itemID then
				occupied = occupied + 1
				local entry = self:_AcquireEntry()
				if PopulateEntryFromSlot(self, entry, bag, slot, ctx) then
					self.slots[#self.slots + 1] = entry
				end
			elseif not info or not info.iconFileID then
				free = free + 1
			end
		end
	end

	-- Too many unknown items (loot during sort, new stacks) — full rescan is safer.
	if ctx.fastMisses > 0 and ctx.fastMisses > occupied * 0.15 then
		self:Run(bags, onComplete)
		return
	end

	self:_FinalizeBuild(free, total)
	self:_ScheduleScanComplete(onComplete)

	if not (HasAsyncLoad and self._incomplete) then
		return
	end

	self._scanGen = (self._scanGen or 0) + 1
	local gen = self._scanGen
	local container = ContinuableContainer:Create()
	if not ItemLoader.StageUncachedSlots(bags, container) then
		return
	end

	container:ContinueOnLoad(function()
		if self._scanGen ~= gen then
			return
		end
		local infoMod = ns:GetModule("ItemInfo")
		if infoMod and infoMod.InvalidateUnusableCaches then
			infoMod:InvalidateUnusableCaches()
		end
		self:_Build(bags)
		self:_ScheduleScanComplete(onComplete)
	end)
end

function meta:RefreshDisplayFields()
	local itemInfo = ns:GetModule("ItemInfo")
	local changeset = self:_ResetChangeset()
	local anyChanged = false
	local slots = self.slots
	for i = 1, #slots do
		local entry = slots[i]
		local snap = SnapshotEntryPaint(entry)
		ApplyDisplayFields(entry, itemInfo)
		if EntryPaintChanged(snap, entry) then
			MarkEntryOverlayUpdate(changeset, entry)
			anyChanged = true
		end
	end
	if anyChanged then
		FinalizeOverlayChangeset(changeset)
	end
	return anyChanged, false
end

--- Collapse entries that share a MergeKey into one display entry whose count is
--- the group total. The largest individual stack is kept as the visible/clickable
--- root (so clicking grabs the biggest pile); the rest are dropped from the slot
--- list. Counts are reset fresh every _Build, so mutating entry.count is safe.
---
--- Merged-away slots are tracked on `root._mergedSlots` so lock/quest updates on
--- any pile in the group refresh the visible button without a full rescan.
function meta:_MergeStacks()
	local slots = self.slots
	local n = #slots
	if n < 2 then
		return
	end

	-- Scratch tables reused across builds to avoid churning the GC.
	local best = self._mergeBest or {}
	self._mergeBest = best
	wipe(best)
	local total = self._mergeTotal or {}
	self._mergeTotal = total
	wipe(total)
	local members = self._mergeMembers or {}
	self._mergeMembers = members
	wipe(members)

	-- Pass 1: per key, accumulate the total count and remember the largest stack.
	for i = 1, n do
		local e = slots[i]
		local key = MergeKey(e)
		if key then
			local list = members[key]
			if not list then
				list = {}
				members[key] = list
			end
			list[#list + 1] = e
			local count = e.count or 1
			total[key] = (total[key] or 0) + count
			local b = best[key]
			local bCount = b and b.count or 1
			if not b or count > bCount then
				best[key] = e
			end
		end
	end

	-- Pass 2: keep non-mergeable entries verbatim and one (largest) entry per
	-- key, rewriting its count to the group total. Emitted at the first
	-- occurrence of the key so relative order is roughly stable (we sort after).
	local emitted = self._mergeEmitted or {}
	self._mergeEmitted = emitted
	wipe(emitted)
	local w = 0
	for i = 1, n do
		local e = slots[i]
		local key = MergeKey(e)
		if not key then
			e._mergedSlots = nil
			w = w + 1
			slots[w] = e
		elseif not emitted[key] then
			emitted[key] = true
			local b = best[key]
			b.count = total[key]
			b._mergedSlots = members[key]
			w = w + 1
			slots[w] = b
		end
	end

	for i = n, w + 1, -1 do
		slots[i] = nil
	end
end

--- Scan `bags` and (re)build results, then invoke `onComplete(self)`.
---
--- The build runs immediately so the window is never blank. If any item's data
--- wasn't cached at build time, we stage those slots into a ContinuableContainer
--- and rebuild exactly once when the data arrives. Pass `dirtyBags` (bagID -> true)
--- to rescan only changed bags when a prior build exists (incremental path).
--- Optional `dirtySlotKeys` limits the diff to explicit slot keys (from
--- CollectDirtySlotKeys or PatchSlot).
function meta:Run(bags, onComplete, dirtyBags, dirtySlotKeys)
	self._scanGen = (self._scanGen or 0) + 1
	local gen = self._scanGen
	-- A full/partial rebuild owns the slot list; abandon any mid-flight reclassify.
	if self.CancelCategoryRefresh then
		self:CancelCategoryRefresh()
	end

	local usePartial = (dirtySlotKeys and next(dirtySlotKeys) or dirtyBags and next(dirtyBags)) and #self.slots > 0
	if usePartial then
		self:_BuildSlotDiff(bags, dirtyBags, dirtySlotKeys)
	else
		self:_Build(bags)
	end
	self:_ScheduleScanComplete(onComplete)

	if not (HasAsyncLoad and self._incomplete) then
		return self
	end

	-- Stage uncached slots via the static per-slot Item mixin cache (ItemLoader).
	local container = ContinuableContainer:Create()
	local staged = ItemLoader and ItemLoader.StageUncachedSlots(bags, container)

	if not staged then
		return self
	end

	container:ContinueOnLoad(function()
		-- A newer scan already ran; let it own the result.
		if self._scanGen ~= gen then
			return
		end
		local itemInfo = ns:GetModule("ItemInfo")
		if itemInfo and itemInfo.InvalidateUnusableCaches then
			itemInfo:InvalidateUnusableCaches()
		end
		if usePartial then
			self:_BuildSlotDiff(bags, dirtyBags, dirtySlotKeys)
		else
			self:_Build(bags)
		end
		self:_ScheduleScanComplete(onComplete)
	end)

	return self
end

--- Refresh lock/quest on one entry, including merged-away stacks on the root.
local function RefreshEntryLiveFields(entry)
	local merged = entry._mergedSlots
	if merged and #merged > 0 then
		local locked = false
		local questInfo
		for i = 1, #merged do
			local m = merged[i]
			local info = C_Container.GetContainerItemInfo(m.bag, m.slot)
			if info and info.isLocked then
				locked = true
			end
			local qi = C_Container.GetContainerItemQuestInfo(m.bag, m.slot)
			if qi and (qi.isQuestItem or qi.questID) then
				questInfo = qi
			end
		end
		entry.isLocked = locked
		if questInfo then
			ApplyQuestFields(entry, questInfo)
		else
			ApplyQuestFields(entry, nil)
		end
		return
	end

	local info = C_Container.GetContainerItemInfo(entry.bag, entry.slot)
	if info then
		entry.isLocked = info.isLocked == true
	end
	local questInfo = C_Container.GetContainerItemQuestInfo(entry.bag, entry.slot)
	ApplyQuestFields(entry, questInfo)
end

--- Refresh lock state on existing entries without reclassifying.
function meta:RefreshLocks()
	for i = 1, #self.slots do
		RefreshEntryLiveFields(self.slots[i])
	end
end

--- Refresh lock state for one existing entry. Returns true if the slot was in
--- this scanner, so callers can skip a full display repaint on lock spam.
--- O(1) via the slotsByKey hash built at the end of _Build.
function meta:RefreshLock(bag, slot)
	local entry = self.slotsByKey[SlotKey(bag, slot)]
	if not entry then
		for i = 1, #self.slots do
			local root = self.slots[i]
			local merged = root._mergedSlots
			if merged then
				for j = 1, #merged do
					local m = merged[j]
					if m.bag == bag and m.slot == slot then
						entry = root
						break
					end
				end
			end
			if entry then
				break
			end
		end
	end
	if not entry then
		return false
	end
	RefreshEntryLiveFields(entry)
	return true
end

--- Refresh unusable tint cache on existing entries (toggle / level-up).
function meta:RefreshUnusable()
	local itemInfo = ns:GetModule("ItemInfo")
	local changeset = self:_ResetChangeset()
	local anyChanged = false
	for i = 1, #self.slots do
		local entry = self.slots[i]
		local snap = SnapshotEntryPaint(entry)
		CacheUnusable(entry, itemInfo)
		if EntryPaintChanged(snap, entry) then
			MarkEntryOverlayUpdate(changeset, entry)
			anyChanged = true
		end
	end
	if anyChanged then
		FinalizeOverlayChangeset(changeset)
	end
	return anyChanged, false
end

--- Refresh quest overlays and quest-driven category membership. Returns true
--- only when at least one entry's overlay or category actually moved.
function meta:RefreshQuestState()
	local changeset = self:_ResetChangeset()
	local categories = ns:GetModule("Categories")
	local junkCategory = L["Junk"]
	local changed = false
	for i = 1, #self.slots do
		local entry = self.slots[i]
		local snapQuest = entry.quest
		local snapQuestID = entry.questID
		local snapActive = entry.isActiveQuest
		local snapLocked = entry.isLocked
		local snapCat = entry.category
		RefreshEntryLiveFields(entry)
		local entryChanged = entry.quest ~= snapQuest
			or entry.questID ~= snapQuestID
			or entry.isActiveQuest ~= snapActive
			or entry.isLocked ~= snapLocked
		if categories then
			local cat = categories:GetCategory(entry)
			if cat ~= entry.category then
				local moved, needFinalize = TryApplyCategoryChange(self, entry, cat, changeset, junkCategory)
				if moved or needFinalize then
					entryChanged = true
				end
			end
		end
		if entryChanged then
			changed = true
			MarkEntryOverlayUpdate(changeset, entry)
			if snapCat ~= entry.category then
				changeset.dirtyCategories[snapCat] = true
			end
		end
	end
	if changed then
		FinalizeOverlayChangeset(changeset)
	end
	return changed
end

--- Re-sum vendor value for the Junk section after async sell prices arrive.
function meta:RecomputeJunkSectionValue()
	local junkCategory = L["Junk"]
	for i = 1, #self.sections do
		local section = self.sections[i]
		if section.name == junkCategory then
			local total = 0
			local items = section.items
			for j = 1, #items do
				local entry = items[j]
				local sellPrice = entry.sellPrice
				if sellPrice and sellPrice > 0 then
					local count = entry.count or 1
					total = total + (sellPrice * count)
				end
			end
			local newValue = total > 0 and total or nil
			if section.junkValue ~= newValue then
				section.junkValue = newValue
				return true
			end
			return false
		end
	end
	return false
end

--- Re-read static item metadata on a slot entry after GET_ITEM_INFO_RECEIVED.
local function RefreshEntryItemFields(entry, itemID)
	local instant = F.GetItemInfoInstantRecord(itemID)
	local record = F.GetItemInfoRecord(itemID)
	local classID = instant and instant.classID
	local subClassID = instant and (instant.subclassID or instant.subClassID)
	local itemType = instant and instant.itemType
	local itemSubType = instant and instant.itemSubType
	local itemEquipLoc = instant and instant.itemEquipLoc
	if not classID and record then
		classID = record.classID
	end
	if not subClassID and record then
		subClassID = record.subclassID or record.subClassID
	end
	if not itemType and record then
		itemType = record.itemType
	end
	if not itemSubType and record then
		itemSubType = record.itemSubType
	end
	if not itemEquipLoc and record then
		itemEquipLoc = record.itemEquipLoc
	end
	entry.itemType = itemType
	entry.itemSubType = itemSubType
	entry.itemEquipLoc = itemEquipLoc
	entry.classID = classID
	entry.subClassID = subClassID
	-- Prefer link / live slot over GetItemQualityByID(itemID) — base template
	-- quality is often lower than the bonus-ID instance in the bag.
	local q = ResolveItemQuality(entry.bag, entry.slot, nil, record, itemID, entry.hyperlink)
	if q ~= nil then
		entry.quality = q
	end
	if record and record.itemLink and not entry.hyperlink then
		entry.hyperlink = record.itemLink
	end
	if record and record.itemIcon and not entry.icon then
		entry.icon = record.itemIcon
	end
	local inv = GetItemInventoryTypeByID and GetItemInventoryTypeByID(itemID)
	if inv then
		entry.invSlotID = inv or entry.invSlotID
	end
end

--- Refresh cached item fields after GET_ITEM_INFO_RECEIVED without a full scan.
--- Returns changed, junkValueChanged, needsFinalize. Pass accumulate=true on
--- subsequent item IDs in one flush so changesets merge.
function meta:RefreshItemID(itemID, accumulate)
	if not itemID then
		return false, false, false
	end
	maxStackCache[itemID] = nil
	nameCache[itemID] = nil
	expacCache[itemID] = nil
	sellPriceCache[itemID] = nil

	local entries = self.entriesByItemID[itemID]
	if not entries or #entries == 0 then
		return false, false, false
	end

	local changeset
	if accumulate and self.lastChangeset then
		changeset = self.lastChangeset
	else
		changeset = self:_ResetChangeset()
	end

	local categories = ns:GetModule("Categories")
	local itemInfo = ns:GetModule("ItemInfo")
	local junkCategory = L["Junk"]
	local anyChanged = false
	local junkDirty = false
	local needsFinalize = changeset.needsFinalize and true or false
	local maxStack, name, expacID = GetBasics(itemID)

	for i = 1, #entries do
		local entry = entries[i]
		local paintSnap = SnapshotEntryPaint(entry)
		local oldPrice = entry.sellPrice
		RefreshEntryItemFields(entry, itemID)
		if maxStack then
			entry.maxStack = maxStack
		end
		if name then
			entry.name = name
		end
		if expacID then
			entry.expacID = expacID
		end
		if itemInfo then
			ApplyDisplayFields(entry, itemInfo)
		end
		entry.sellPrice = GetSellPrice(itemID, entry.hyperlink)
		if entry.category == junkCategory and oldPrice ~= entry.sellPrice then
			junkDirty = true
		end
		local entryChanged = EntryPaintChanged(paintSnap, entry)
		if categories then
			local cat = categories:GetCategory(entry)
			if cat ~= entry.category then
				local moved, needFin = TryApplyCategoryChange(self, entry, cat, changeset, junkCategory)
				if needFin then
					needsFinalize = true
				end
				if moved or needFin then
					entryChanged = true
				end
			end
		end
		if entryChanged then
			MarkEntryOverlayUpdate(changeset, entry)
			anyChanged = true
		end
	end

	local junkChanged = junkDirty and self:RecomputeJunkSectionValue() or false
	if junkChanged then
		changeset.dirtyCategories[junkCategory] = true
	end
	changeset.needsFinalize = needsFinalize
	FinalizeOverlayChangeset(changeset)
	return anyChanged or junkChanged, junkChanged, needsFinalize
end

--- Cancel an in-flight budgeted RefreshCategories (newer refresh or full Run).
--- Still fire onComplete(false, false) so ApplyScannerRefresh's pending count
--- cannot stick forever; false/false means "no UI mutation from this pass".
function meta:CancelCategoryRefresh()
	local wasPending = self._catRefreshPending
	local onComplete = self._catRefreshOnComplete
	self._catRefreshGen = (self._catRefreshGen or 0) + 1
	self._catRefreshPending = nil
	self._catRefreshOnComplete = nil
	if wasPending and onComplete then
		onComplete(false, false)
	end
end

--- Re-run category classification on existing entries without a full bag walk.
--- Returns changed, needsFinalize[, pending].
--- When the ~100ms frame budget is exceeded, work resumes next frame and
--- `pending` is true; `onComplete(changed, needsFinalize)` fires when done.
--- Pass accumulate=true to merge into the existing changeset.
function meta:RefreshCategories(accumulate, onComplete)
	local categories = ns:GetModule("Categories")
	if not categories or #self.slots == 0 then
		return false, true, false
	end

	self:CancelCategoryRefresh()
	local gen = self._catRefreshGen
	self._catRefreshOnComplete = onComplete

	local changeset
	if accumulate and self.lastChangeset then
		changeset = self.lastChangeset
	else
		changeset = self:_ResetChangeset()
	end

	local junkCategory = L["Junk"]
	local state = {
		index = 1,
		anyChanged = false,
		needsFinalize = changeset.needsFinalize and true or false,
		resumed = false,
	}

	local function finish()
		if self._catRefreshGen ~= gen then
			return
		end
		changeset.needsFinalize = state.needsFinalize
		FinalizeOverlayChangeset(changeset)
		self._catRefreshPending = nil
		self._catRefreshOnComplete = nil
		local changed, needsFinalize = state.anyChanged, state.needsFinalize
		-- Async resume path: caller already returned pending; notify via callback.
		if state.resumed and onComplete then
			onComplete(changed, needsFinalize)
		end
		return changed, needsFinalize, false
	end

	local function step()
		if self._catRefreshGen ~= gen then
			return
		end
		F.ReportFrameBudget()
		local slots = self.slots
		local n = #slots
		while state.index <= n do
			-- Full Run / newer refresh cancelled us mid-loop.
			if self._catRefreshGen ~= gen then
				return
			end
			if F.FrameBudgetExceeded(0.1) then
				state.resumed = true
				self._catRefreshPending = true
				C_Timer.After(0, step)
				return nil, nil, true
			end
			local entry = slots[state.index]
			state.index = state.index + 1
			local cat = categories:GetCategory(entry)
			if cat ~= entry.category then
				local moved, needFin = TryApplyCategoryChange(self, entry, cat, changeset, junkCategory)
				if needFin then
					state.needsFinalize = true
				end
				if moved or needFin then
					MarkEntryOverlayUpdate(changeset, entry)
					state.anyChanged = true
				end
			end
		end
		return finish()
	end

	return step()
end

local function FlattenSectionsToSlots(self)
	local w = 0
	local sections = self.sections
	for i = 1, #sections do
		local items = sections[i].items
		for j = 1, #items do
			w = w + 1
			self.slots[w] = items[j]
		end
	end
	for i = w + 1, #self.slots do
		self.slots[i] = nil
	end
	RebuildLookupTables(self)
end

local function MarkAllSectionsDirty(changeset, sections)
	for i = 1, #sections do
		changeset.dirtyCategories[sections[i].name] = true
	end
end

--- Re-sort items inside each category panel for the active itemSort mode.
--- Returns changed, needsFinalize.
function meta:RefreshSortOrder()
	if #self.slots == 0 or #self.sections == 0 then
		return false, true
	end
	local changeset = self:_ResetChangeset()
	local sections = self.sections
	for i = 1, #sections do
		local items = sections[i].items
		if #items > 1 then
			if not pcall(tsort, items, activeWithin) then
				pcall(tsort, items, SafeCompare)
			end
		end
	end
	FlattenSectionsToSlots(self)
	MarkAllSectionsDirty(changeset, sections)
	changeset.structureChanged = true
	FinalizeOverlayChangeset(changeset)
	return true, false
end

--- Apply or refresh stack merging on the current slot list (enable only).
--- Disabling merge requires a full rescan to restore split stacks.
function meta:RefreshStackMerge()
	local merge = ns.db and ns.db.organize and ns.db.organize.stackMerge
	if not merge then
		return false, true
	end
	if #self.slots < 2 then
		return false, false
	end
	local changeset = self:_ResetChangeset()
	self:_MergeStacks()
	if not pcall(tsort, self.slots, CompareEntries) then
		pcall(tsort, self.slots, SafeCompare)
	end
	self:_BuildSections()
	RebuildLookupTables(self)
	MarkAllSectionsDirty(changeset, self.sections)
	changeset.structureChanged = true
	FinalizeOverlayChangeset(changeset)
	return true, false
end

--- Reclassify stacks of one itemID (custom assignment / unassign).
function meta:RefreshItemCategory(itemID)
	if not itemID then
		return false, true
	end
	local entries = self.entriesByItemID[itemID]
	if not entries or #entries == 0 then
		return false, false
	end
	local categories = ns:GetModule("Categories")
	if not categories then
		return false, true
	end
	local changeset = self:_ResetChangeset()
	local junkCategory = L["Junk"]
	local anyChanged = false
	local needsFinalize = false
	for i = 1, #entries do
		local entry = entries[i]
		local cat = categories:GetCategory(entry)
		if cat ~= entry.category then
			local moved, needFin = TryApplyCategoryChange(self, entry, cat, changeset, junkCategory)
			if needFin then
				needsFinalize = true
			end
			if moved or needFin then
				MarkEntryOverlayUpdate(changeset, entry)
				anyChanged = true
			end
		end
	end
	changeset.needsFinalize = needsFinalize
	FinalizeOverlayChangeset(changeset)
	return anyChanged, needsFinalize
end

--- Rebuild section order after a category order pin changes.
function meta:RefreshCategoryOrders()
	local categories = ns:GetModule("Categories")
	if not categories or #self.slots == 0 then
		return false, true
	end
	local changeset = self:_ResetChangeset()
	for i = 1, #self.slots do
		local entry = self.slots[i]
		entry.categoryOrder = categories:GetOrder(entry.category)
	end
	if not pcall(tsort, self.slots, CompareEntries) then
		pcall(tsort, self.slots, SafeCompare)
	end
	self:_BuildSections()
	RebuildLookupTables(self)
	MarkAllSectionsDirty(changeset, self.sections)
	changeset.structureChanged = true
	FinalizeOverlayChangeset(changeset)
	return true, false
end

--- Rename a category panel in place (custom category rename).
function meta:RenameCategorySection(oldName, newName)
	if not oldName or not newName or oldName == newName then
		return false, false
	end
	if self.sectionsByName[newName] then
		return false, true
	end
	local sec = self.sectionsByName[oldName]
	local changeset = self:_ResetChangeset()
	local anyEntry = false
	for i = 1, #self.slots do
		local entry = self.slots[i]
		if entry.category == oldName then
			entry.category = newName
			anyEntry = true
		end
	end
	if not sec and not anyEntry then
		return false, false
	end
	if sec then
		sec.name = newName
		self.sectionsByName[newName] = sec
		self.sectionsByName[oldName] = nil
	end
	changeset.dirtyCategories[oldName] = true
	changeset.dirtyCategories[newName] = true
	changeset.structureChanged = true
	FinalizeOverlayChangeset(changeset)
	return true, false
end

local function ApplyRecentEntryUpdate(self, entry, changeset, junkCategory, categories, recent)
	local wasNew = entry.isNewItem
	local isNew = recent:IsEntryNew(entry.bag, entry.slot, entry.itemGUID) and true or false
	if isNew == wasNew then
		return false, false
	end
	entry.isNewItem = isNew
	local needsFinalize = false
	if categories then
		local cat = categories:GetCategory(entry)
		if cat ~= entry.category then
			local moved, needFin = TryApplyCategoryChange(self, entry, cat, changeset, junkCategory)
			if needFin then
				needsFinalize = true
			end
			if moved or needFin then
				MarkEntryOverlayUpdate(changeset, entry)
				return true, needsFinalize
			end
		end
	end
	MarkEntryOverlayUpdate(changeset, entry)
	return true, needsFinalize
end

--- Update one backpack slot after Recent:Clear or a new-item signal.
function meta:RefreshRecentSlot(bag, slot)
	if not (bag and slot) or not C.IS_BACKPACK_BAG[bag] then
		return false, false
	end
	local entry = self.slotsByKey[SlotKey(bag, slot)]
	if not entry then
		return false, false
	end
	local recent = ns.Recent
	if not recent then
		return false, false
	end
	local changeset = self:_ResetChangeset()
	local categories = ns:GetModule("Categories")
	local changed, needsFinalize = ApplyRecentEntryUpdate(self, entry, changeset, L["Junk"], categories, recent)
	if not changed then
		return false, false
	end
	changeset.needsFinalize = needsFinalize
	FinalizeOverlayChangeset(changeset)
	return true, needsFinalize
end

--- Refresh Recent Items flags after startup baseline or new-item events.
function meta:RefreshRecentFlags()
	local recent = ns.Recent
	if not recent or #self.slots == 0 then
		return false, false
	end
	local categories = ns:GetModule("Categories")
	local changeset = self:_ResetChangeset()
	local junkCategory = L["Junk"]
	local anyChanged = false
	local needsFinalize = false
	local isBackpackBag = C.IS_BACKPACK_BAG
	for i = 1, #self.slots do
		local entry = self.slots[i]
		if isBackpackBag[entry.bag] then
			local changed, needFin = ApplyRecentEntryUpdate(self, entry, changeset, junkCategory, categories, recent)
			if needFin then
				needsFinalize = true
			end
			if changed then
				anyChanged = true
			end
		end
	end
	if not anyChanged then
		return false, false
	end
	changeset.needsFinalize = needsFinalize
	FinalizeOverlayChangeset(changeset)
	return true, needsFinalize
end

--- Refresh search-filter state on the existing entries without reclassifying.
--- Blizzard's bag search desaturates non-matching items in place (it never
--- changes membership - sections are built unfiltered), so a search keystroke
--- only flips entry.isFiltered. Updating those flags on the current slot list is
--- both correct and far cheaper than a full _Build (no reclassify/sort/section
--- pass, no ContinuableContainer await). Returns true only if at least one flag
--- actually moved, so callers can skip the repaint when the result is identical.
function meta:RefreshFiltered()
	local changeset = self:_ResetChangeset()
	local changed = false
	for i = 1, #self.slots do
		local entry = self.slots[i]
		local info = C_Container.GetContainerItemInfo(entry.bag, entry.slot)
		local filtered = info and info.isFiltered == true
		if entry.isFiltered ~= filtered then
			entry.isFiltered = filtered
			changed = true
			changeset.updated[#changeset.updated + 1] = entry
			changeset.dirtyCategories[entry.category] = true
		end
	end
	if changed and #changeset.updated > 0 then
		FinalizeOverlayChangeset(changeset, { searchFilter = true })
	end
	return changed
end
