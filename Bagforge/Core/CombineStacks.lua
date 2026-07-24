--[[
	Bagforge - CombineStacks
	-------------------------------------------------------------------------
	Physical stack combine before Blizzard SortBags / SortBank (Baganator
	Sorting/CombineStacks.lua). Display merge in Scan is unrelated — this
	moves partial stacks onto each other with the cursor so Blizzard's sort
	sees fewer fragmented piles.

	One combine action per call; callers loop until Complete (WaitingMove /
	WaitingUnlock) then invoke SortBags. Live C_Container only — no Syndicator.
--]]

local _, ns = ...
local F = ns.F

local C_Container = C_Container
local C_Item = C_Item
local ClearCursor = ClearCursor
local InCombatLockdown = InCombatLockdown
local ItemLocation = ItemLocation
local pairs = pairs
local wipe = wipe
local tsort = table.sort
local floor = math.floor
local ceil = math.ceil

local GetItemMaxStackSizeByID = C_Item.GetItemMaxStackSizeByID

ns.CombineStacks = ns.CombineStacks or {}
local CombineStacks = ns.CombineStacks

local STATUS = {
	Complete = 0,
	WaitingMove = 1,
	WaitingUnlock = 2,
	WaitingItemData = 3,
}
CombineStacks.Status = STATUS

-- Reused across calls (hot path — no per-sort {} churn).
local stacksByItem = {}
local partialScratch = {}
local stackSizeCache = {}

local function StackLimit(itemID)
	if stackSizeCache[itemID] then
		return stackSizeCache[itemID]
	end
	local limit
	if GetItemMaxStackSizeByID then
		limit = GetItemMaxStackSizeByID(itemID)
	end
	if not limit then
		local info = F.GetItemInfoRecord and F.GetItemInfoRecord(itemID)
		limit = info and info.itemStackCount
	end
	limit = limit or 1
	stackSizeCache[itemID] = limit
	return limit
end

local function RequestStackData(itemID)
	if GetItemMaxStackSizeByID and GetItemMaxStackSizeByID(itemID) then
		return false
	end
	if C_Item.RequestLoadItemDataByID then
		C_Item.RequestLoadItemDataByID(itemID)
		return true
	end
	return false
end

local function WipeStacks()
	for itemID, list in pairs(stacksByItem) do
		wipe(list)
		stacksByItem[itemID] = nil
	end
end

--- Collect live stacks for `bags` into stacksByItem. Returns WaitingItemData if
--- any stack size is still loading.
local function CollectStacks(bags)
	WipeStacks()
	local waitingData = false
	for i = 1, #bags do
		local bag = bags[i]
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local itemID = info and info.itemID
			if itemID then
				if RequestStackData(itemID) then
					waitingData = true
				end
				local count = info.stackCount or 1
				local list = stacksByItem[itemID]
				if not list then
					list = {}
					stacksByItem[itemID] = list
				end
				list[#list + 1] = { bag = bag, slot = slot, count = count }
			end
		end
	end
	if waitingData then
		return STATUS.WaitingItemData
	end
	return STATUS.Complete
end

--- One cursor combine of the smallest partial onto the largest partial for the
--- first itemID that still needs merging. Baganator DoMovement shape.
local function DoOneCombine()
	if InCombatLockdown and InCombatLockdown() then
		return STATUS.Complete
	end
	local moved, locked = false, false
	for itemID, list in pairs(stacksByItem) do
		local stackSize = StackLimit(itemID)
		if stackSize > 1 and #list > 1 then
			local total, fullStacks = 0, 0
			for i = 1, #list do
				local c = list[i].count
				total = total + c
				if c == stackSize then
					fullStacks = fullStacks + 1
				end
			end
			local targetStacks = ceil(total / stackSize)
			local targetFull = floor(total / stackSize)
			if #list > targetStacks or fullStacks ~= targetFull then
				wipe(partialScratch)
				for i = 1, #list do
					local e = list[i]
					if e.count ~= stackSize then
						partialScratch[#partialScratch + 1] = e
					end
				end
				if #partialScratch >= 2 then
					tsort(partialScratch, function(a, b)
						return a.count < b.count
					end)
					local source = partialScratch[1]
					local target = partialScratch[#partialScratch]
					local srcLoc = ItemLocation:CreateFromBagAndSlot(source.bag, source.slot)
					local dstLoc = ItemLocation:CreateFromBagAndSlot(target.bag, target.slot)
					if C_Item.DoesItemExist(srcLoc) and C_Item.DoesItemExist(dstLoc) and not C_Item.IsLocked(srcLoc) and not C_Item.IsLocked(dstLoc) then
						ClearCursor()
						C_Container.PickupContainerItem(source.bag, source.slot)
						C_Container.PickupContainerItem(target.bag, target.slot)
						ClearCursor()
						moved = true
						break
					else
						locked = true
					end
				end
			end
		end
	end
	if moved then
		return STATUS.WaitingMove
	elseif locked then
		return STATUS.WaitingUnlock
	end
	return STATUS.Complete
end

--- Combine partial stacks across `bags`. Returns a STATUS code; callers should
--- re-call on WaitingMove / WaitingUnlock / WaitingItemData until Complete.
function CombineStacks.Run(bags)
	if not bags or #bags == 0 then
		return STATUS.Complete
	end
	if InCombatLockdown and InCombatLockdown() then
		return STATUS.Complete
	end
	local collect = CollectStacks(bags)
	if collect == STATUS.WaitingItemData then
		return STATUS.WaitingItemData
	end
	return DoOneCombine()
end

--- Drive combine-to-completion then `onComplete`. Uses C_Timer.After for pacing
--- (same delay spirit as Transfers STEP_DELAY).
function CombineStacks.RunThen(bags, onComplete)
	local delay = 0.15
	local After = C_Timer.After
	local function Step()
		local status = CombineStacks.Run(bags)
		if status == STATUS.Complete then
			if onComplete then
				onComplete()
			end
			return
		end
		After(delay, Step)
	end
	Step()
end
