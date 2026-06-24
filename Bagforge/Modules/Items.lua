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

local Items = ns:NewModule("Items")

-- One scanner instance owns this module's slots/sections/free-slot results.
local scanner = ns.Scan.New()
Items.scanner = scanner

-- ---------------------------------------------------------------------------
-- Scan
--   Run() fires this when the build is ready (immediately, and again once any
--   late item data has loaded). Module-level so we don't allocate a closure per
--   scan. The view redraws off "Items.Updated".
-- ---------------------------------------------------------------------------
local function onScanComplete()
	ns:TriggerCallback("Items.Updated")
end

function Items:Scan()
	self._scanDirty = false
	if ns.Search and ns.Search.InvalidateTooltips then
		ns.Search.InvalidateTooltips()
	end
	scanner:Run(C.BACKPACK_BAGS, onScanComplete)
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

--- Hand the sorting off to Blizzard's own bag sort. It stacks, merges and
--- reorders far better than we'd manage by hand, and it's protected-safe out
--- of combat. The follow-up BAG_UPDATE_DELAYED triggers our rescan.
function Items:Sort()
	if InCombatLockdown() then
		F.Print(L["Can't sort bags during combat."])
		return
	end
	local recent = ns.Recent
	if recent and recent.ClearBackpack then
		recent:ClearBackpack()
	end
	C_Container.SortBags()
end

--- Re-render every open bag window after a display-affecting change. One shared
--- coordinator so the Pawn/ItemInfo/Categories modules don't each re-roll the
--- "redraw backpack + nudge the bank" snippet (and don't hold a hard reference
--- to the Bank module - it subscribes to the "Bank.Refresh" signal instead).
---   rescan = true  : item *membership* changed (a filter toggled) - rebuild the
---                    backpack data, which fires "Items.Updated" for the view.
---   rescan = false : only display flags changed (upgrade arrows, item level,
---                    bind labels) - repaint from the current data, no rescan.
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
	ns:TriggerCallback("Bank.Refresh")
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function Items:OnEnable()
	local refresh = F.DebounceNoArgs(0.05, function()
		if not Items:AnyWindowOpen() then
			Items:MarkScanDirty()
			return
		end
		Items:Scan()
	end)

	ns:RegisterEvent("BAG_UPDATE_DELAYED", refresh)
	ns:RegisterEvent("PLAYER_LOGIN", refresh)
	ns:RegisterEvent("BAG_NEW_ITEMS_UPDATED", refresh)

	-- A search keystroke only desaturates non-matching items - membership, order
	-- and sections are unchanged. So skip the full rescan: re-read isFiltered on
	-- the current slots in place and fire "Items.Updated" WITHOUT bumping the draw
	-- epoch, so only the panels whose filter state actually moved repaint (their
	-- per-section signature folds in isFiltered) while the rest are skipped.
	local refreshSearch = F.DebounceNoArgs(0.05, function()
		if not Items:AnyWindowOpen() then
			return
		end
		if scanner:RefreshFiltered() then
			ns:TriggerCallback("Items.Updated")
		end
	end)
	ns:RegisterEvent("INVENTORY_SEARCH_UPDATE", refreshSearch)

	ns:RegisterCallback("Recent.StartupComplete", function()
		ns:RefreshBags(true)
	end)

	local refreshDisplay = F.DebounceNoArgs(0.05, function()
		if not Items:AnyWindowOpen() then
			return
		end
		scanner:RefreshLocks()
		ns:RefreshBags(false)
	end)
	ns:RegisterEvent("ITEM_LOCK_CHANGED", function(_, bag, slot)
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
		scanner:RefreshQuestState()
		ns:RefreshBags(false)
	end)
	ns:RegisterEvent("QUEST_LOG_UPDATE", refreshQuest)

	ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
		if ns.Scan and ns.Scan.ClearItemCaches then
			ns.Scan.ClearItemCaches()
		end
	end)

	-- On Midnight the scanner awaits late item data itself (ContinuableContainer),
	-- but GET_ITEM_INFO_RECEIVED still lets us refresh ilvl/name/bind on visible
	-- slots without a full rescan when item data arrives after the first build.
	local pendingItemIDs = {}
	local flushItemInfo = F.DebounceNoArgs(0.05, function()
		if not Items:AnyWindowOpen() then
			wipe(pendingItemIDs)
			return
		end
		local itemButton = ns:GetModule("ItemButton")
		local bank = ns:GetModule("Bank")
		local needRescan = false
		for itemID in pairs(pendingItemIDs) do
			if scanner:RefreshItemID(itemID) then
				needRescan = true
			end
			if bank and bank.RefreshItemID then
				bank:RefreshItemID(itemID)
			end
			if itemButton and itemButton.RefreshItemID then
				itemButton:RefreshItemID(itemID)
			end
		end
		wipe(pendingItemIDs)
		if needRescan then
			ns:RefreshBags(true)
		else
			ns:RefreshBags(false)
		end
	end)
	ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID)
		if itemID and F.NotSecret(itemID) then
			pendingItemIDs[itemID] = true
			flushItemInfo()
		end
	end)

	Items:Scan()
end
