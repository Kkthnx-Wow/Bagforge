--[[
	Bagforge - Recent Items (GUID tracker)
	-------------------------------------------------------------------------
	Blizzard exposes `C_NewItems.IsNewItem(bag, slot)`; Baganator's
	NewItemsTracking keeps a `firstStart` window (~5s) where every bag-cache
	refresh re-baselines all current GUIDs as "seen" so existing inventory is
	never classified as new on login.

	  * During login startup, re-baseline on every debounced bag update.
	  * After startup, any unseen GUID becomes recent.
	  * Recent GUIDs follow their current bag/slot.
	  * Session timeout clears old markers.
	  * Clear Blizzard's C_NewItems flag on click and during startup baseline.

	Scan calls `Recent:IsEntryNew(bag, slot, guid)` for category routing; it does
	not read GetContainerItemInfo.isNewItem (stale during login bursts).
--]]

local _, ns = ...
local C, F = ns.C, ns.F

local C_Container = C_Container
local C_Item = C_Item
local C_NewItems = C_NewItems
local C_Timer = C_Timer
local GetTime = GetTime
local ItemLocation = ItemLocation
local ipairs = ipairs
local pairs = pairs
local wipe = wipe

local RECENT_TIMEOUT = 600 -- seconds; session-only, no saved data churn.
-- Baganator uses 5s; covers the login bag-cache burst before marking new GUIDs.
local STARTUP_BASELINE_SECONDS = 5

local Recent = ns:NewModule("Recent")
ns.Recent = Recent

local seenGUIDs = {}
local recentGUIDs = {} -- guid -> firstSeenTime
local slotGUIDs = {} -- SlotKey -> guid
local guidSlots = {} -- guid -> SlotKey
local firstStart = true
local currentSlots = {}

local function SlotKey(bag, slot)
	return bag * 1000 + slot
end

local function GUIDAccessible(guid)
	return guid and F.CanAccessValue(guid)
end

local function GUIDEqual(a, b)
	if a == b then
		return true
	end
	if not a or not b then
		return false
	end
	if F.IsSecret(a) or F.IsSecret(b) then
		return false
	end
	return a == b
end

local function GetSlotGUID(bag, slot)
	if not (ItemLocation and C_Item and C_Item.GetItemGUID) then
		return nil
	end
	local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
	if not (location and C_Item.DoesItemExist and C_Item.DoesItemExist(location)) then
		return nil
	end
	return C_Item.GetItemGUID(location)
end

local function ClearExpired(now)
	for guid, started in pairs(recentGUIDs) do
		if now - started >= RECENT_TIMEOUT then
			recentGUIDs[guid] = nil
			local key = guidSlots[guid]
			if key and slotGUIDs[key] == guid then
				slotGUIDs[key] = nil
			end
			guidSlots[guid] = nil
		end
	end
end

local function BlizzardIsNewItem(bag, slot)
	if not (C_NewItems and C_NewItems.IsNewItem) then
		return false
	end
	local isNew = C_NewItems.IsNewItem(bag, slot)
	return F.CanAccessValue(isNew) and isNew == true
end

local function RemoveBlizzardNewItem(bag, slot)
	if C_NewItems and C_NewItems.RemoveNewItem then
		C_NewItems.RemoveNewItem(bag, slot)
	end
end

function Recent:IsStartup()
	return firstStart
end

function Recent:Scan()
	local now = GetTime()
	ClearExpired(now)
	wipe(currentSlots)

	for _, bag in ipairs(C.BACKPACK_BAGS) do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local guid = GetSlotGUID(bag, slot)
			if GUIDAccessible(guid) then
				local key = SlotKey(bag, slot)
				local wasSeen = seenGUIDs[guid]
				currentSlots[key] = guid
				seenGUIDs[guid] = true

				-- Login startup: treat everything currently carried as seen and
				-- clear stale Blizzard new-item flags (Baganator firstStart).
				if firstStart then
					RemoveBlizzardNewItem(bag, slot)
				elseif not wasSeen then
					recentGUIDs[guid] = now
				end

				if recentGUIDs[guid] then
					slotGUIDs[key] = guid
					guidSlots[guid] = key
				end
			end
		end
	end

	-- Drop slot mappings for items that moved away or left the bags.
	for key, guid in pairs(slotGUIDs) do
		if not GUIDEqual(currentSlots[key], guid) then
			slotGUIDs[key] = nil
		end
	end
	for guid, key in pairs(guidSlots) do
		if not GUIDAccessible(guid) or not GUIDEqual(currentSlots[key], guid) then
			guidSlots[guid] = nil
		end
	end
end

function Recent:EndStartup()
	if not firstStart then
		return
	end
	firstStart = false
	self:Scan()
	ns:TriggerCallback("Recent.StartupComplete")
end

function Recent:GetSlotGUID(bag, slot)
	return GetSlotGUID(bag, slot)
end

function Recent:IsNewItem(bag, slot, guid)
	if firstStart then
		return false
	end
	if not guid then
		guid = GetSlotGUID(bag, slot)
	end
	if not GUIDAccessible(guid) then
		return false
	end
	return recentGUIDs[guid] ~= nil and GUIDEqual(slotGUIDs[SlotKey(bag, slot)], guid)
end

--- Category routing entry point: Blizzard C_NewItems + our GUID tracker.
function Recent:IsEntryNew(bag, slot, guid)
	if firstStart then
		return false
	end
	if BlizzardIsNewItem(bag, slot) then
		return true
	end
	return self:IsNewItem(bag, slot, guid)
end

function Recent:Clear(bag, slot)
	RemoveBlizzardNewItem(bag, slot)
	local key = SlotKey(bag, slot)
	local guid = slotGUIDs[key]
	if not GUIDAccessible(guid) then
		return
	end
	recentGUIDs[guid] = nil
	slotGUIDs[key] = nil
	guidSlots[guid] = nil
end

function Recent:ClearAll()
	wipe(recentGUIDs)
	wipe(slotGUIDs)
	wipe(guidSlots)
end

--- Drop every backpack item from Recent Items and clear Blizzard's new-item
--- flags. Sorting is an explicit "organize my bags" action, so recent loot
--- should reclassify into its normal category on the next scan.
function Recent:ClearBackpack()
	for _, bag in ipairs(C.BACKPACK_BAGS) do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.iconFileID then
				RemoveBlizzardNewItem(bag, slot)
			end
		end
	end
	self:ClearAll()
end

function Recent:OnEnable()
	local debouncedScan = F.DebounceNoArgs(0.05, function()
		Recent:Scan()
	end)

	self:RegisterEvent("PLAYER_LOGIN", debouncedScan)
	self:RegisterEvent("PLAYER_ENTERING_WORLD", debouncedScan)
	self:RegisterEvent("BAG_UPDATE_DELAYED", debouncedScan)
	self:RegisterEvent("BAG_NEW_ITEMS_UPDATED", debouncedScan)

	if C_Timer and C_Timer.After then
		C_Timer.After(STARTUP_BASELINE_SECONDS, function()
			Recent:EndStartup()
		end)
	end

	self:Scan()
end
