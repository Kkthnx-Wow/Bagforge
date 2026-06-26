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

	Midnight note: item stack counts in *bags* are readable (Blizzard's own bag
	UI does raw arithmetic on them), so counts are not secret-guarded here. Money
	- which IS secret in combat - is the footer's problem, not the scanner's.
--]]

local _, ns = ...
local L, F = ns.L, ns.F

local C_Container = C_Container
local C_Item = C_Item
local GetContainerItemEquipmentSetInfo = C_Container.GetContainerItemEquipmentSetInfo
local GetContainerItemID = C_Container.GetContainerItemID
local GetItemInventoryTypeByID = C_Item.GetItemInventoryTypeByID
local IsItemDataCachedByID = C_Item.IsItemDataCachedByID
local GetItemInfo = C_Item.GetItemInfo
local ipairs = ipairs
local select = select
local tsort = table.sort
local wipe = wipe
local type = type
local pcall = pcall

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
local function GetBasics(itemID)
	if not itemID then
		return nil, nil, nil
	end
	local maxStack = maxStackCache[itemID]
	if maxStack ~= nil then
		return maxStack, nameCache[itemID], expacCache[itemID]
	end
	local name, _, _, _, _, _, _, stack, _, _, _, _, _, _, expacID = GetItemInfo(itemID)
	if stack then
		maxStackCache[itemID] = stack
	end
	if name then
		nameCache[itemID] = name
	end
	if expacID then
		expacCache[itemID] = expacID
	end
	return stack, name, expacID
end

--- Stack-merge key for an entry: only stackable items merge, and only by a key
--- that means "truly the same item" - the full hyperlink (encodes bonus IDs /
--- enchants) when readable, else the itemID. Returns nil for anything that
--- should never merge (unique gear, secret values, uncached max stack).
local function MergeKey(entry)
	local maxStack = entry.maxStack
	if not (maxStack and maxStack > 1) then
		return nil
	end
	local link = entry.hyperlink
	if link and F.NotSecret(link) then
		return link
	end
	local id = entry.itemID
	if id and F.NotSecret(id) then
		return id
	end
	return nil
end

-- Midnight clients ship both of these; gated so a flavour without them simply
-- falls back to the synchronous build (callers still fire their redraw). Bracket
-- access dodges stale type-stub "undefined field" warnings.
local ContinuableContainer = _G["ContinuableContainer"]
local ItemMixinClass = _G["Item"]
local HasAsyncLoad = (ContinuableContainer and ItemMixinClass and ItemMixinClass.CreateFromBagAndSlot and IsItemDataCachedByID) and true or false
ns.ScanHasAsyncLoad = HasAsyncLoad

local Scan = {}
ns.Scan = Scan

function Scan.ClearItemCaches()
	wipe(maxStackCache)
	wipe(nameCache)
	wipe(expacCache)
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
	local classID, subClassID = entry.classID, entry.subClassID
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
	return entry.classID == ITEM_CLASS_WEAPON or entry.classID == ITEM_CLASS_ARMOR
end

local function SortValue(entry, key)
	if key == "quality" then
		return entry.quality or 0
	elseif key == "invertedQuality" then
		return -(entry.quality or 0)
	elseif key == "sortedClassID" then
		return SortedLookup(SORTED_CLASS, entry.classID)
	elseif key == "sortedInvSlotID" then
		return SortedLookup(SORTED_INV_SLOT, entry.invSlotID)
	elseif key == "sortedSubClassID" then
		return SortedSubClassID(entry)
	elseif key == "itemLevelRaw" then
		return entry.ilvl or -1
	elseif key == "invertedItemLevelRaw" then
		return -(entry.ilvl or -1)
	elseif key == "invertedItemLevelEquipment" then
		if IsEquipment(entry) then
			return -(entry.ilvl or -1)
		end
		return 0
	elseif key == "invertedExpansion" then
		return -(entry.expacID or 0)
	elseif key == "itemName" then
		return entry.name or ""
	elseif key == "invertedItemID" then
		return -(entry.itemID or 0)
	elseif key == "invertedItemCount" then
		return -(entry.count or 1)
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

local function MakeKeyChainComparator(keys)
	return function(a, b)
		for i = 1, #keys do
			local cmp = CompareKey(a, b, keys[i])
			if cmp ~= nil then
				return cmp
			end
		end
		return a.itemID < b.itemID
	end
end

-- Baganator Order.lua chains, adapted: quality mode keeps higher quality first
-- (invertedQuality) to match Bagforge's historical behaviour.
local KEY_CHAINS = {
	quality = { "invertedQuality", "sortedClassID", "sortedInvSlotID", "sortedSubClassID", "itemLevelRaw", "invertedExpansion", "itemName", "invertedItemID", "invertedItemCount" },
	name = { "sortedClassID", "sortedInvSlotID", "sortedSubClassID", "invertedExpansion", "itemName", "invertedItemLevelRaw", "invertedQuality", "invertedItemID", "invertedItemCount" },
	ilvl = { "invertedItemLevelEquipment", "sortedClassID", "sortedInvSlotID", "sortedSubClassID", "invertedExpansion", "invertedQuality", "invertedItemLevelRaw", "itemName", "invertedItemID", "invertedItemCount" },
	expansion = { "invertedExpansion", "sortedClassID", "sortedInvSlotID", "sortedSubClassID", "invertedItemLevelRaw", "invertedQuality", "itemName", "invertedItemID", "invertedItemCount" },
}

local WITHIN = {
	quality = MakeKeyChainComparator(KEY_CHAINS.quality),
	name = MakeKeyChainComparator(KEY_CHAINS.name),
	ilvl = MakeKeyChainComparator(KEY_CHAINS.ilvl),
	expansion = MakeKeyChainComparator(KEY_CHAINS.expansion),
}

-- Swapped by Scan.SetSortMode; defaults to the historical quality-first chain.
local activeWithin = WITHIN.quality

-- Built-in modes; the rest of WITHIN is filled by plugins (Scan.RegisterWithin).
local BUILTIN_WITHIN = { quality = true, name = true, ilvl = true, expansion = true }

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
		return a.itemID < b.itemID
	end
	return true
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
	return a.itemID < b.itemID
end

local function SlotKey(bag, slot)
	return bag * 1000 + slot
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
	end
end

--- Synchronous build: walk `bags`, classify each occupied slot through the
--- shared Categories module, sort, and build sections. Results land on the
--- instance. Sets self._incomplete when any occupied item's data isn't cached
--- yet (so ilvl/bind may be missing); Run() uses that to schedule an await.
function meta:_Build(bags)
	self._entryCount = 0
	self._incomplete = false
	wipe(self.slots)

	local categories = ns:GetModule("Categories")
	-- Clear per-scan saved-search winner cache so "new"/quest/other
	-- time-varying entry fields can't get stale across refreshes.
	if categories and categories.InvalidateSearchCache then
		categories:InvalidateSearchCache()
	end
	-- Hoisted: one module lookup per build instead of one per occupied slot.
	local itemInfo = ns:GetModule("ItemInfo")
	local free, total = 0, 0

	for _, bag in ipairs(bags) do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		total = total + numSlots

		for slot = 1, numSlots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID then
				-- Flag items whose full data (ilvl, bind, req level) isn't cached
				-- yet so Run() can await them precisely (the ContinuableContainer
				-- it stages does the actual loading) instead of polling.
				if IsItemDataCachedByID and not IsItemDataCachedByID(info.itemID) then
					self._incomplete = true
				end
				local questInfo = C_Container.GetContainerItemQuestInfo(bag, slot)
				local _, itemType, itemSubType, itemEquipLoc, _, classID, subClassID = C_Item.GetItemInfoInstant(info.itemID)
				local entry = self:_AcquireEntry()
				entry.bag = bag
				entry.slot = slot
				entry.key = SlotKey(bag, slot)
				entry.itemID = info.itemID
				entry.quality = info.quality or 0
				entry.icon = info.iconFileID
				entry.count = info.stackCount or 1
				-- One GetItemInfo call fills max stack (merge), name (search /
				-- name+expansion sort) and expansion id (sort) at once.
				local maxStack, name, expacID = GetBasics(info.itemID)
				entry.maxStack = maxStack
				entry.name = name
				entry.expacID = expacID
				entry.hyperlink = info.hyperlink
				entry.isLocked = info.isLocked and true or false
				entry.isBound = info.isBound and true or false
				entry.readable = info.isReadable and true or false
				entry.noValue = info.hasNoValue and true or false
				entry.isFiltered = info.isFiltered and true or false
				entry.itemGUID = ns.Recent and ns.Recent.GetSlotGUID and ns.Recent:GetSlotGUID(bag, slot) or nil
				entry.isNewItem = EntryIsNewItem(bag, slot, entry.itemGUID) and true or false
				entry.quest = questInfo and questInfo.isQuestItem
				entry.questID = questInfo and questInfo.questID
				entry.isActiveQuest = questInfo and questInfo.isActive
				-- Equipment-set membership (NDui's isInSet) feeds the EquipSet filter.
				entry.isInSet = GetContainerItemEquipmentSetInfo and GetContainerItemEquipmentSetInfo(bag, slot) or false
				entry.itemType = itemType
				entry.itemSubType = itemSubType
				entry.itemEquipLoc = itemEquipLoc
				entry.classID = classID
				entry.subClassID = subClassID
				entry.invSlotID = GetItemInventoryTypeByID and GetItemInventoryTypeByID(info.itemID) or 0
				-- Resolve bind label / item level before classifying so saved search
				-- categories can match on `ilvl` and `bind` (Categories.GetCategory
				-- reads the entry). Cheap - both are cached per item by ItemInfo.
				if itemInfo then
					entry.bindLabel = itemInfo:GetBindLabel(entry)
					entry.ilvl = itemInfo:GetItemLevel(entry)
				end
				entry.category = categories and categories:GetCategory(entry) or L["Other"]
				entry.categoryOrder = categories and categories:GetOrder(entry.category) or 100
				self.slots[#self.slots + 1] = entry
			else
				free = free + 1
			end
		end
	end

	-- Collapse identical stacks before sorting/sectioning when the toggle is on.
	if ns.db and ns.db.organize and ns.db.organize.stackMerge then
		self:_MergeStacks()
	end

	-- A plugin sort comparator could be inconsistent; never let that abort the
	-- whole scan. Fall back to a guaranteed stable order if table.sort throws.
	if not pcall(tsort, self.slots, CompareEntries) then
		tsort(self.slots, SafeCompare)
	end
	self:_BuildSections()

	self.freeSlots = free
	self.totalSlots = total

	-- Rebuild the O(1) lookup tables after merge+sort so per-slot and per-itemID
	-- refresh paths don't have to scan the entire slot list.
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

	return self
end

--- Collapse entries that share a MergeKey into one display entry whose count is
--- the group total. The largest individual stack is kept as the visible/clickable
--- root (so clicking grabs the biggest pile); the rest are dropped from the slot
--- list. Counts are reset fresh every _Build, so mutating entry.count is safe.
---
--- Caveat: only the root slot gets a button, so a lock/quest change on a merged
--- -away slot won't update in place (a full BAG_UPDATE rescan still re-merges).
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

	-- Pass 1: per key, accumulate the total count and remember the largest stack.
	for i = 1, n do
		local e = slots[i]
		local key = MergeKey(e)
		if key then
			local count = e.count or 1
			if not F.NotSecret(count) then
				count = 1
			end
			total[key] = (total[key] or 0) + count
			local b = best[key]
			local bCount = b and b.count or 1
			if not F.NotSecret(bCount) then
				bCount = 1
			end
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
			w = w + 1
			slots[w] = e
		elseif not emitted[key] then
			emitted[key] = true
			local b = best[key]
			b.count = total[key]
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
--- and rebuild exactly once when the data arrives - replacing the old debounced
--- GET_ITEM_INFO_RECEIVED poll with a precise, self-cancelling await. A
--- generation token drops a stale await if a newer Run() superseded it.
function meta:Run(bags, onComplete)
	self._scanGen = (self._scanGen or 0) + 1
	local gen = self._scanGen

	self:_Build(bags)
	if onComplete then
		onComplete(self)
	end

	if not (HasAsyncLoad and self._incomplete) then
		return self
	end

	-- Only stage slots whose item data is NOT yet cached. Staging every occupied
	-- slot (the original code) created one Item mixin object per slot — 600+
	-- allocations on a full warband bank — even when the data was already in the
	-- client cache and the ContinuableContainer would fire immediately anyway.
	local container = ContinuableContainer:Create()
	local staged = false
	for _, bag in ipairs(bags) do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local itemID = GetContainerItemID(bag, slot)
			if itemID and not IsItemDataCachedByID(itemID) then
				container:AddContinuable(ItemMixinClass:CreateFromBagAndSlot(bag, slot))
				staged = true
			end
		end
	end

	if not staged then
		return self
	end

	container:ContinueOnLoad(function()
		-- A newer scan already ran; let it own the result.
		if self._scanGen ~= gen then
			return
		end
		self:_Build(bags)
		if onComplete then
			onComplete(self)
		end
	end)

	return self
end

--- Refresh lock state on existing entries without reclassifying.
function meta:RefreshLocks()
	for i = 1, #self.slots do
		local entry = self.slots[i]
		local info = C_Container.GetContainerItemInfo(entry.bag, entry.slot)
		if info then
			entry.isLocked = info.isLocked and true or false
		end
	end
end

--- Refresh lock state for one existing entry. Returns true if the slot was in
--- this scanner, so callers can skip a full display repaint on lock spam.
--- O(1) via the slotsByKey hash built at the end of _Build.
function meta:RefreshLock(bag, slot)
	local entry = self.slotsByKey[SlotKey(bag, slot)]
	if not entry then
		return false
	end
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if info then
		entry.isLocked = info.isLocked and true or false
	end
	return true
end

--- Refresh quest overlay fields without reclassifying.
function meta:RefreshQuestState()
	for i = 1, #self.slots do
		local entry = self.slots[i]
		local questInfo = C_Container.GetContainerItemQuestInfo(entry.bag, entry.slot)
		entry.quest = questInfo and questInfo.isQuestItem
		entry.questID = questInfo and questInfo.questID
		entry.isActiveQuest = questInfo and questInfo.isActive
	end
end

--- Refresh cached item fields after GET_ITEM_INFO_RECEIVED without a full scan.
--- Returns true when category membership may have changed (caller should rescan).
--- O(k) where k = number of stacks of this itemID (via entriesByItemID), not O(n)
--- over all slots.
function meta:RefreshItemID(itemID)
	if not (itemID and F.NotSecret(itemID)) then
		return false
	end
	maxStackCache[itemID] = nil
	nameCache[itemID] = nil
	expacCache[itemID] = nil

	local entries = self.entriesByItemID[itemID]
	if not entries or #entries == 0 then
		return false
	end

	local categories = ns:GetModule("Categories")
	local itemInfo = ns:GetModule("ItemInfo")
	local categoryChanged = false
	local maxStack, name, expacID = GetBasics(itemID)

	for i = 1, #entries do
		local entry = entries[i]
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
			entry.bindLabel = itemInfo:GetBindLabel(entry)
			entry.ilvl = itemInfo:GetItemLevel(entry)
		end
		if categories then
			local cat = categories:GetCategory(entry)
			if cat ~= entry.category then
				entry.category = cat
				entry.categoryOrder = categories:GetOrder(cat)
				categoryChanged = true
			end
		end
	end
	return categoryChanged
end

--- Refresh search-filter state on the existing entries without reclassifying.
--- Blizzard's bag search desaturates non-matching items in place (it never
--- changes membership - sections are built unfiltered), so a search keystroke
--- only flips entry.isFiltered. Updating those flags on the current slot list is
--- both correct and far cheaper than a full _Build (no reclassify/sort/section
--- pass, no ContinuableContainer await). Returns true only if at least one flag
--- actually moved, so callers can skip the repaint when the result is identical.
function meta:RefreshFiltered()
	local changed = false
	for i = 1, #self.slots do
		local entry = self.slots[i]
		local info = C_Container.GetContainerItemInfo(entry.bag, entry.slot)
		local filtered = (info and info.isFiltered) and true or false
		if entry.isFiltered ~= filtered then
			entry.isFiltered = filtered
			changed = true
		end
	end
	return changed
end
