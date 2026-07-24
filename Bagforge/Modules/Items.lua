--[[
	Bagforge - Items (data layer)
	-------------------------------------------------------------------------
	Walks the backpack bags via the shared ns.Scan scanner, then broadcasts
	"Items.Updated" so the view can redraw. This module knows nothing about
	frames - it's pure data. The view subscribes to the signal and never scans
	the bags itself. All the scan/sort/section logic lives in Core/Scan.lua so
	the backpack and the bank views share one implementation.
--]]

local _, ns = ...
local C, F, L = ns.C, ns.F, ns.L

local InCombatLockdown = InCombatLockdown
local C_Container = C_Container
local wipe = wipe

local Items = ns:NewModule("Items")

-- One scanner instance owns this module's slots/sections/free-slot results.
local scanner = ns.Scan.New()
Items.scanner = scanner
Items._dirtyBackpackBags = {}
Items._dirtySlotScratch = {}

-- ---------------------------------------------------------------------------
-- Scan
--   Run() fires this when the build is ready (immediately, and again once any
--   late item data has loaded). Module-level so we don't allocate a closure per
--   scan. The view redraws off "Items.Updated".
-- ---------------------------------------------------------------------------
local function onScanComplete(scanner)
	ns:TriggerCallback("Items.Updated", scanner and scanner.lastChangeset)
end

function Items:Scan(dirtyBags, dirtySlotKeys)
	self._scanDirty = false
	self._hasScanned = true
	local recent = ns.Recent
	if recent and recent.Scan then
		recent:Scan()
	end
	if ns.Search and ns.Search.InvalidateTooltips then
		ns.Search.InvalidateTooltips()
	end
	scanner:Run(C.BACKPACK_BAGS, onScanComplete, dirtyBags, dirtySlotKeys)
end

--- Lighter refresh after Blizzard bag sort: reuse cached item metadata when
--- possible; categories are always re-evaluated from live slot fields.
function Items:ScanAfterSort()
	self._scanDirty = false
	self._hasScanned = true
	local recent = ns.Recent
	if recent and recent.Scan then
		recent:Scan()
	end
	if ns.Search and ns.Search.InvalidateTooltips then
		ns.Search.InvalidateTooltips()
	end
	scanner:RefreshAfterSort(C.BACKPACK_BAGS, onScanComplete)
end

function Items:MarkScanDirty()
	self._scanDirty = true
end

-- ---------------------------------------------------------------------------
-- Public accessors used by the view
-- ---------------------------------------------------------------------------
function Items:GetSlots()
	return scanner.slots
end

function Items:GetSections()
	return scanner.sections
end

function Items:GetFreeSlots()
	return scanner.freeSlots
end

--- True when any Bagforge bag/bank window is on screen. Used to skip work (e.g.
--- the item-info-stream rescan) while every window is closed.
function Items:AnyWindowOpen()
	local backpack = ns:GetModule("Backpack")
	if backpack and backpack.IsShown and backpack:IsShown() then
		return true
	end
	local bank = ns:GetModule("Bank")
	if bank and bank.OpenView and bank:OpenView() then
		return true
	end
	return false
end

local function MarkAllBackpackBagsDirty(dirtyBags)
	for _, bag in ipairs(C.BACKPACK_BAGS) do
		dirtyBags[bag] = true
	end
end

local function CopyDirtyBags(dirtyBags, into)
	if not next(dirtyBags) then
		return nil
	end
	local copy = into
	if copy then
		wipe(copy)
	else
		copy = {}
	end
	for bag in pairs(dirtyBags) do
		copy[bag] = true
	end
	return copy
end

local function FlushBackpackRefresh(dirtyBackpackBags)
	if InCombatLockdown() then
		Items._pendingCombatRefresh = true
		return
	end
	Items._pendingCombatRefresh = false
	if not Items:AnyWindowOpen() then
		Items:MarkScanDirty()
		wipe(dirtyBackpackBags)
		return
	end
	local sortFlush = ns:IsSortFlush()
	if not next(dirtyBackpackBags) and not sortFlush then
		return
	end
	Items._dirtyBagCopy = Items._dirtyBagCopy or {}
	local dirtyCopy = (not sortFlush) and CopyDirtyBags(dirtyBackpackBags, Items._dirtyBagCopy) or nil
	local dirtySlots
	if dirtyCopy and ns.Scan and ns.Scan.CollectDirtySlotKeys then
		dirtySlots = ns.Scan.CollectDirtySlotKeys(scanner, C.BACKPACK_BAGS, dirtyCopy, Items._dirtySlotScratch)
		if not dirtySlots then
			wipe(dirtyBackpackBags)
			return
		end
	end
	wipe(dirtyBackpackBags)
	if sortFlush then
		Items:ScanAfterSort()
	else
		Items:Scan(dirtyCopy, dirtySlots)
	end
end

--- Hand the sorting off to Blizzard's own bag sort. Physical CombineStacks
--- first (Baganator CombineStacksAndSort) so partial piles merge before SortBags.
function Items:Sort()
	if InCombatLockdown() then
		F.Print(L["Can't sort bags during combat."])
		return
	end
	if ns:IsBagSortActive() then
		return
	end
	local recent = ns.Recent
	if recent and recent.ClearBackpack then
		recent:ClearBackpack()
	end
	if not ns:BeginBagSort() then
		return
	end
	ns:ScheduleBagSortFlush("backpack", function()
		FlushBackpackRefresh(Items._dirtyBackpackBags)
	end)
	MarkAllBackpackBagsDirty(Items._dirtyBackpackBags)

	local function DoBlizzardSort()
		-- Combine may take longer than the initial flush window; re-arm so
		-- BAG_UPDATE during SortBags stays gated until the burst settles.
		ns:ScheduleBagSortFlush("backpack", function()
			FlushBackpackRefresh(Items._dirtyBackpackBags)
		end)
		C_Container.SortBags()
	end

	local combine = ns.CombineStacks
	if combine and combine.RunThen then
		combine.RunThen(C.BACKPACK_BAGS, DoBlizzardSort)
	else
		DoBlizzardSort()
	end
end

function Items:IsBackpackRefreshPending()
	return next(self._dirtyBackpackBags) ~= nil
end

--- True while backpack/bank dirty-bag flush or Blizzard sort flush is still pending.
function ns:IsBagCachePending()
	if ns:IsBagSortActive() then
		return true
	end
	local items = ns:GetModule("Items")
	if items and items.IsBackpackRefreshPending and items:IsBackpackRefreshPending() then
		return true
	end
	local bank = ns:GetModule("Bank")
	if bank and bank.IsBankRefreshPending and bank:IsBankRefreshPending() then
		return true
	end
	return false
end

--- Re-render every open bag window after a display-affecting change. One shared
--- coordinator so the Pawn/ItemInfo/Categories modules don't each re-roll the
--- "redraw backpack + nudge the bank" snippet (and don't hold a hard reference
--- to the Bank module - it subscribes to the "Bank.Refresh" signal instead).
---   rescan = true  : full scanner:Run() — only when membership/structure cannot
---                    be patched (finalize fallback, stack-merge disable, login,
---                    BAG_CONTAINER_UPDATE, GET_ITEM_INFO finalize).
---   rescan = false : display-only (header colours, counts, overlay epoch bump).
function ns:RefreshBags(rescan)
	if rescan then
		Items:Scan() -- fires "Items.Updated" (backpack redraw) itself
	else
		-- Display-only change: item membership is unchanged, so the per-section
		-- content signatures won't move on their own. Bump the global display
		-- epoch (folded into every signature) so the skip-unchanged-panels cache
		-- is invalidated and buttons repaint with the new overlay state.
		ns.DrawEpoch = (ns.DrawEpoch or 0) + 1
		ns:TriggerCallback("Items.Updated")
	end
	ns:TriggerCallback("Bank.Refresh", rescan)
end

local function FinishScannerRefresh(items, bank, backpackChanged, backpackFinalize, bankChanged, bankFinalize)
	if backpackFinalize or bankFinalize then
		if items and items.MarkScanDirty then
			items:MarkScanDirty()
		end
		if items and items.AnyWindowOpen and items:AnyWindowOpen() then
			ns:RefreshBags(true)
		end
		return
	end

	if not (items and items.AnyWindowOpen and items:AnyWindowOpen()) then
		-- Model mutated while closed — next Open must rescan/redraw from truth.
		if (backpackChanged or bankChanged) and items and items.MarkScanDirty then
			items:MarkScanDirty()
		end
		return
	end

	local scanner = items and items.scanner
	if backpackChanged and scanner and scanner.lastChangeset then
		ns:TriggerCallback("Items.Updated", scanner.lastChangeset)
	end
	if bankChanged and bank and bank.DrawPendingLayouts then
		bank:DrawPendingLayouts()
	end
end

--- Reclassify existing scan data after a filter/plugin toggle. Falls back to a
--- full rescan only when section lists cannot be patched in place.
--- refreshFn(scanner[, onComplete]) → changed, needsFinalize[, pending].
--- Budgeted RefreshCategories may return pending=true and call onComplete later;
--- we wait for backpack + bank before drawing so neither side is dropped.
function ns:ApplyScannerRefresh(refreshFn)
	local items = ns:GetModule("Items")
	local scanner = items and items.scanner
	local bank = ns:GetModule("Bank")

	local job = {
		backpackChanged = false,
		backpackFinalize = false,
		bankChanged = false,
		bankFinalize = false,
		pending = 0,
	}

	local function tryFinish()
		if job.pending > 0 then
			return
		end
		FinishScannerRefresh(items, bank, job.backpackChanged, job.backpackFinalize, job.bankChanged, job.bankFinalize)
	end

	if scanner and refreshFn and #scanner.slots > 0 then
		job.pending = job.pending + 1
		local changed, finalize, pending = refreshFn(scanner, function(asyncChanged, asyncFinalize)
			job.backpackChanged = asyncChanged and true or false
			job.backpackFinalize = asyncFinalize and true or false
			job.pending = job.pending - 1
			tryFinish()
		end)
		if not pending then
			job.backpackChanged = changed and true or false
			job.backpackFinalize = finalize and true or false
			job.pending = job.pending - 1
		end
	elseif not scanner or #scanner.slots == 0 then
		job.backpackFinalize = true
	end

	if bank and bank.ApplyViewScannerRefresh then
		job.pending = job.pending + 1
		local bankChanged, bankFinalize, bankPending = bank:ApplyViewScannerRefresh(refreshFn, function(asyncChanged, asyncFinalize)
			job.bankChanged = asyncChanged and true or false
			job.bankFinalize = asyncFinalize and true or false
			job.pending = job.pending - 1
			tryFinish()
		end)
		if not bankPending then
			job.bankChanged = bankChanged and true or false
			job.bankFinalize = bankFinalize and true or false
			job.pending = job.pending - 1
		end
	end

	tryFinish()
end

function ns:ReclassifyBags()
	ns:ApplyScannerRefresh(function(scanner, onComplete)
		return scanner:RefreshCategories(nil, onComplete)
	end)
end

function ns:ResortBags()
	ns:ApplyScannerRefresh(function(scanner)
		return scanner:RefreshSortOrder()
	end)
end

function ns:ApplyStackMerge()
	ns:ApplyScannerRefresh(function(scanner)
		return scanner:RefreshStackMerge()
	end)
end

function ns:RefreshCategoryOrders()
	ns:ApplyScannerRefresh(function(scanner)
		return scanner:RefreshCategoryOrders()
	end)
end

function ns:RefreshItemCategory(itemID)
	ns:ApplyScannerRefresh(function(scanner)
		return scanner:RefreshItemCategory(itemID)
	end)
end

function ns:RenameCategoryInScanners(oldName, newName)
	ns:ApplyScannerRefresh(function(scanner, onComplete)
		local renamed, finalize = scanner:RenameCategorySection(oldName, newName)
		if finalize then
			return false, true
		end
		if renamed then
			return true, false
		end
		return scanner:RefreshCategories(nil, onComplete)
	end)
end

function ns:RefreshRecentFlags()
	ns:ApplyScannerRefresh(function(scanner)
		if scanner.RefreshRecentFlags then
			return scanner:RefreshRecentFlags()
		end
		return false, false
	end)
end

function ns:RefreshRecentSlot(bag, slot)
	local items = ns:GetModule("Items")
	local scanner = items and items.scanner
	if not (scanner and scanner.RefreshRecentSlot) then
		return
	end
	local changed, finalize = scanner:RefreshRecentSlot(bag, slot)
	if not changed and not finalize then
		return
	end
	local windowsOpen = items.AnyWindowOpen and items:AnyWindowOpen()
	if finalize then
		if windowsOpen then
			ns:RefreshBags(true)
		elseif items.MarkScanDirty then
			items:MarkScanDirty()
		end
		return
	end
	if windowsOpen and scanner.lastChangeset then
		ns:TriggerCallback("Items.Updated", scanner.lastChangeset)
	elseif items.MarkScanDirty then
		items:MarkScanDirty()
	end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function Items:OnEnable()
	if self._hooksInstalled then
		return
	end
	self._hooksInstalled = true
	self._eventHandles = self._eventHandles or {}
	local handles = self._eventHandles

	local dirtyBackpackBags = Items._dirtyBackpackBags
	wipe(dirtyBackpackBags)

	ns:TrackEvent(handles, "BAG_UPDATE", function(_, bagID)
		if bagID and C.IS_BACKPACK_BAG[bagID] then
			dirtyBackpackBags[bagID] = true
		end
	end)

	local refresh = F.DebounceTrailingNoArgs(0.05, function()
		if ns:IsBagSortActive() then
			ns:ScheduleBagSortFlush("backpack", function()
				FlushBackpackRefresh(dirtyBackpackBags)
			end)
			return
		end
		FlushBackpackRefresh(dirtyBackpackBags)
	end)

	local function queueFullBackpackRefresh()
		MarkAllBackpackBagsDirty(dirtyBackpackBags)
		refresh()
	end

	-- BAG_UPDATE_DELAYED owns backpack flush; Recent GUID walk runs inside Items:Scan.
	ns:TrackEvent(handles, "BAG_UPDATE_DELAYED", refresh)
	ns:TrackEvent(handles, "BAG_CONTAINER_UPDATE", queueFullBackpackRefresh)
	-- Events.lua: EQUIPMENT_SETS_CHANGED — BetterBags wipes + full refresh; our
	-- equip-set category keys off GetContainerItemEquipmentSetInfo.
	ns:TrackEvent(handles, "EQUIPMENT_SETS_CHANGED", queueFullBackpackRefresh)
	-- Initial model build is Items:Scan() at end of OnEnable; PLAYER_LOGIN would
	-- double-scan on every login (Enable already runs from PLAYER_LOGIN).
	ns:TrackEvent(handles, "PLAYER_REGEN_ENABLED", function()
		if not Items._pendingCombatRefresh then
			return
		end
		MarkAllBackpackBagsDirty(dirtyBackpackBags)
		FlushBackpackRefresh(dirtyBackpackBags)
	end)

	-- A search keystroke only desaturates non-matching items - membership, order
	-- and sections are unchanged. So skip the full rescan: re-read isFiltered on
	-- the current slots in place and fire "Items.Updated" WITHOUT bumping the draw
	-- epoch, so only the panels whose filter state actually moved repaint (their
	-- per-section signature folds in isFiltered) while the rest are skipped.
	-- Events.lua: INVENTORY_SEARCH_UPDATE — Blizzard bag search (BagSearchBox).
	-- Keep the model in sync even while closed so Open() paints correct dim/hide.
	local refreshSearch = F.DebounceNoArgs(0.05, function()
		if not scanner:RefreshFiltered() then
			return
		end
		if not Items:AnyWindowOpen() then
			Items:MarkScanDirty()
			return
		end
		ns:TriggerCallback("Items.Updated", scanner.lastChangeset)
	end)
	ns:TrackEvent(handles, "INVENTORY_SEARCH_UPDATE", refreshSearch)

	ns:RegisterCallback("Recent.StartupComplete", function()
		if ns.RefreshRecentFlags then
			ns:RefreshRecentFlags()
		else
			ns:RefreshBags(true)
		end
	end, Items)

	local refreshDisplay = F.DebounceNoArgs(0.05, function()
		if not Items:AnyWindowOpen() then
			return
		end
		scanner:RefreshLocks()
		ns:RefreshBags(false)
	end)
	ns:TrackEvent(handles, "ITEM_LOCK_CHANGED", function(_, bag, slot)
		if not Items:AnyWindowOpen() then
			return
		end

		-- ITEM_LOCK_CHANGED is hot while dragging/splitting stacks. Keep it in the
		-- NDui/cargBags style: update the one visible slot instead of bumping the
		-- global draw epoch and repainting every open panel.
		if not (bag and slot) then
			refreshDisplay()
			return
		end

		scanner:RefreshLock(bag, slot)

		local bank = ns:GetModule("Bank")
		if bank and bank.RefreshSlotLock then
			bank:RefreshSlotLock(bag, slot)
		end

		local itemButton = ns:GetModule("ItemButton")
		if itemButton and itemButton.RefreshSlot then
			itemButton:RefreshSlot(bag, slot)
		end
	end)

	local refreshQuest = F.DebounceNoArgs(0.05, function()
		if not Items:AnyWindowOpen() then
			return
		end
		local changed = scanner:RefreshQuestState()
		local bank = ns:GetModule("Bank")
		if bank and bank.RefreshQuestState then
			changed = bank:RefreshQuestState() or changed
		end
		if not changed then
			return
		end
		if scanner.lastChangeset then
			ns:TriggerCallback("Items.Updated", scanner.lastChangeset)
		end
	end)
	ns:TrackEvent(handles, "QUEST_LOG_UPDATE", refreshQuest)

	-- Events.lua: PLAYER_ENTERING_WORLD — every load screen, not login-only.
	ns:TrackEvent(handles, "PLAYER_ENTERING_WORLD", function()
		if ns.Scan and ns.Scan.ClearItemCaches then
			ns.Scan.ClearItemCaches()
		end
		-- Cached ilvl/bind/name may be stale after zone/instance; dirty so next
		-- open rebuilds instead of painting from wiped cache leftovers.
		Items:MarkScanDirty()
	end)

	-- On Midnight the scanner awaits late item data itself (ContinuableContainer),
	-- but GET_ITEM_INFO_RECEIVED still lets us refresh ilvl/name/bind on visible
	-- slots without a full rescan when item data arrives after the first build.
	-- BAG_UPDATE_DELAYED is debounced (WoWUIBugs #650 — early BAG_UPDATE can fire
	-- before ItemLocation is valid; delayed + ContinuableContainer covers that).
	local pendingItemIDs = {}
	-- Events.lua: GET_ITEM_INFO_RECEIVED — late item cache after ContinuableContainer.
	local flushItemInfo = F.DebounceNoArgs(0.05, function()
		if not Items:AnyWindowOpen() then
			-- Don't drop IDs silently: mark dirty so Open rescans with full data.
			if next(pendingItemIDs) then
				Items:MarkScanDirty()
			end
			wipe(pendingItemIDs)
			return
		end
		local itemButton = ns:GetModule("ItemButton")
		local bank = ns:GetModule("Bank")
		local categories = ns:GetModule("Categories")
		local needRescan = false
		local backpackLayout = false
		local bankLayout = false
		local backpackAccum = false
		local bankAccum = false
		for itemID in pairs(pendingItemIDs) do
			if categories and categories.InvalidateItemProps then
				categories:InvalidateItemProps(itemID)
			end
			local changed, junk, finalize = scanner:RefreshItemID(itemID, backpackAccum)
			backpackAccum = true
			if finalize then
				needRescan = true
				break
			end
			if changed or junk then
				backpackLayout = true
			end
			if bank and bank.RefreshItemID then
				local bRescan, bJunk, bLayout = bank:RefreshItemID(itemID, bankAccum)
				bankAccum = true
				if bRescan then
					needRescan = true
					break
				end
				if bLayout or bJunk then
					bankLayout = true
				end
			end
			if itemButton and itemButton.RefreshItemID then
				itemButton:RefreshItemID(itemID)
			end
		end
		wipe(pendingItemIDs)
		if needRescan then
			ns:RefreshBags(true)
		elseif backpackLayout then
			ns:TriggerCallback("Items.Updated", scanner.lastChangeset)
			if bankLayout and bank and bank.DrawPendingLayouts then
				bank:DrawPendingLayouts()
			end
		elseif bankLayout and bank and bank.DrawPendingLayouts then
			bank:DrawPendingLayouts()
		end
	end)
	ns:TrackEvent(handles, "GET_ITEM_INFO_RECEIVED", function(_, itemID)
		if itemID then
			pendingItemIDs[itemID] = true
			flushItemInfo()
		end
	end)

	Items:Scan()
end

function Items:OnDisable()
	if not self._hooksInstalled then
		return
	end
	self._hooksInstalled = false
	ns:UnregisterModuleEventHandles(self._eventHandles)
	ns:UnregisterCallback("Recent.StartupComplete", Items)
	wipe(Items._dirtyBackpackBags)
	Items._pendingCombatRefresh = false
	Items._hasScanned = false
	Items._scanDirty = true
end
