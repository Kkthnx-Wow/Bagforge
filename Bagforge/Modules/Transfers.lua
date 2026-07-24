--[[
	Bagforge - Transfers
	-------------------------------------------------------------------------
	A small Baganator-inspired action engine for context moves from visible bag
	categories:

	  * vendor a visible backpack category while a merchant is open
	  * deposit a visible backpack category into the currently open bank view
	  * withdraw a bank category into backpack bags
	  * attach a backpack category to open mail (AddToMail.lua)
	  * put a backpack category onto the trade window (AddToTrade.lua)

	Each operation performs one cursor/container action per tick and then waits
	for the client/server to catch up (Baganator-style status-driven pacing).
	Guild bank transfers stay out until we own a live guild UI without Syndicator.
--]]

local _, ns = ...
local C, F, L = ns.C, ns.F, ns.L

local C_Bank = C_Bank
local C_Container = C_Container
local C_Item = C_Item
local GetItemMaxStackSizeByID = C_Item.GetItemMaxStackSizeByID
local C_Timer_After = C_Timer.After
local ClearCursor = ClearCursor
local CreateFrame = CreateFrame
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local ItemLocation = ItemLocation
local MerchantFrame = _G["MerchantFrame"]
local MailFrame = _G["MailFrame"]
local TradeFrame = _G["TradeFrame"]
local UIErrorsFrame = UIErrorsFrame
local GetSendMailItem = _G["GetSendMailItem"]
local SetSendMailShowing = _G["SetSendMailShowing"]
local ClickTradeButton = _G["ClickTradeButton"]
local GetTradePlayerItemInfo = _G["GetTradePlayerItemInfo"]
local ATTACHMENTS_MAX_SEND = _G["ATTACHMENTS_MAX_SEND"] or 12
local FlagsUtil = _G["FlagsUtil"]
local LE_EXPANSION_LEVEL_CURRENT = _G["LE_EXPANSION_LEVEL_CURRENT"]
local pairs = pairs
local select = select
local wipe = wipe
local format = string.format
local floor = math.floor

local BagSlotFlags = Enum.BagSlotFlags
local BagIndex = Enum.BagIndex
local ItemClass = Enum.ItemClass
local BANK_TYPE_ACCOUNT = Enum.BankType and Enum.BankType.Account

local STEP_DELAY = 0.15
local MAX_DEPOSIT_RETRIES = 20
local VENDOR_BATCH_SIZE = 6
local WARBAND_BATCH_SIZE = 5
local IS_BACKPACK_BAG = C.IS_BACKPACK_BAG

local bit_band = bit.band

local transferQueue = {}
local depositRetryCounts = {}
local allocatedSlots = {}
local queueEventFrame
local depositDraining = false
local lastNoBankSlotErrorAt = 0

local STATUS = {
	Complete = 0,
	WaitingMove = 1,
	WaitingUnlock = 2,
	WaitingItemData = 3,
}

local Transfers = ns:NewModule("Transfers")
ns.Transfers = Transfers
Transfers.Status = STATUS

local running

local function MerchantOpen()
	return MerchantFrame and MerchantFrame:IsShown()
end

local function MailOpen()
	return MailFrame and MailFrame:IsShown()
end

local function TradeOpen()
	return TradeFrame and TradeFrame:IsShown()
end

local function SlotLocation(bag, slot)
	return ItemLocation and ItemLocation:CreateFromBagAndSlot(bag, slot)
end

local function IsLocked(bag, slot)
	local location = SlotLocation(bag, slot)
	return location and C_Item.DoesItemExist(location) and C_Item.IsLocked(location)
end

local function SlotKey(bag, slot)
	return F.SlotKey(bag, slot)
end

local function StackLimit(itemID)
	if GetItemMaxStackSizeByID then
		local limit = GetItemMaxStackSizeByID(itemID)
		if limit then
			return limit
		end
	end
	local info = F.GetItemInfoRecord(itemID)
	local stack = info and info.itemStackCount
	return stack or 1
end

local function NeedsItemData(itemID)
	if not itemID then
		return false
	end
	if GetItemMaxStackSizeByID then
		local limit = GetItemMaxStackSizeByID(itemID)
		if limit then
			return false
		end
	end
	local info = F.GetItemInfoRecord(itemID)
	if info and info.itemStackCount then
		return false
	end
	if C_Item and C_Item.RequestLoadItemDataByID then
		C_Item.RequestLoadItemDataByID(itemID)
		return true
	end
	return false
end

local function EntrySellPrice(entry)
	if not entry then
		return nil
	end
	if entry.sellPrice then
		return entry.sellPrice
	end
	local id = entry.itemID
	if id and ns.Scan and ns.Scan.GetSellPrice then
		return ns.Scan.GetSellPrice(id, entry.hyperlink)
	end
	return nil
end

local function IsSellable(entry)
	if not entry or entry.noValue or entry.isLocked then
		return false
	end
	local price = EntrySellPrice(entry)
	return price and price > 0
end

-- Baganator Sorting/BagUsageChecks: prefer herb/engineering/reagent bags when routing.
local function BagInList(bagIDs, bagID)
	for i = 1, #bagIDs do
		if bagIDs[i] == bagID then
			return true
		end
	end
	return false
end

local function GetBagUsageChecks(bagIDs)
	local checks = {}
	local sortOrder = {}

	if BagIndex.ReagentBag and BagInList(bagIDs, BagIndex.ReagentBag) then
		checks[BagIndex.ReagentBag] = function(itemID)
			if not itemID then
				return false
			end
			local info = F.GetItemInfoRecord(itemID)
			local reagent = info and (info.isCraftingReagent or info.isReagent)
			return reagent and true or false
		end
		sortOrder[BagIndex.ReagentBag] = 10
	end

	for i = 1, #bagIDs do
		local bagID = bagIDs[i]
		local _, family = C_Container.GetContainerNumFreeSlots(bagID)
		if family and family ~= 0 then
			checks[bagID] = function(itemID)
				if not (itemID and C_Item.GetItemFamily) then
					return false
				end
				local itemFamily = C_Item.GetItemFamily(itemID)
				if not itemFamily then
					return false
				end
				local info = F.GetItemInfoRecord(itemID)
				local classID = info and info.classID
				if classID == ItemClass.Container or classID == ItemClass.Quiver then
					return false
				end
				return bit_band(itemFamily, family) ~= 0
			end
			if not sortOrder[bagID] then
				sortOrder[bagID] = 5
			end
		elseif not sortOrder[bagID] then
			sortOrder[bagID] = 250
		end
	end

	return { checks = checks, sortOrder = sortOrder }
end

local function SortBagIDs(bagIDs, sortOrder)
	local ordered = {}
	for i = 1, #bagIDs do
		ordered[i] = bagIDs[i]
	end
	table.sort(ordered, function(a, b)
		local ao = sortOrder[a] or 250
		local bo = sortOrder[b] or 250
		if ao == bo then
			return a < b
		end
		return ao < bo
	end)
	return ordered
end

local function CanPlaceInBag(bagChecks, bagID, itemID)
	if not (bagChecks and bagChecks.checks) then
		return true
	end
	local fn = bagChecks.checks[bagID]
	if not fn then
		return true
	end
	return fn(itemID)
end

local function CountByItemIDsInBags(bags)
	local result = {}
	for i = 1, #bags do
		local bag = bags[i]
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID then
				local count = info.stackCount or 1
				result[info.itemID] = (result[info.itemID] or 0) + count
			end
		end
	end
	return result
end

local function BankCountsEqual(a, b)
	if not a or not b then
		return false
	end
	for id, count in pairs(a) do
		if b[id] ~= count then
			return false
		end
	end
	for id, count in pairs(b) do
		if a[id] ~= count then
			return false
		end
	end
	return true
end

-- Right-click deposit queue (flat allocatedSlots keyed by SlotKey).
local function MarkQueueAllocated(bag, slot)
	allocatedSlots[SlotKey(bag, slot)] = true
end

local function ClearDepositQueue()
	wipe(transferQueue)
	wipe(allocatedSlots)
	wipe(depositRetryCounts)
	depositDraining = false
	if queueEventFrame then
		queueEventFrame:UnregisterEvent("BAG_UPDATE")
	end
end

local function ClearCompletedAllocations()
	for key in pairs(allocatedSlots) do
		local bag = floor(key / 1000)
		local slot = key % 1000
		if C_Container.GetContainerItemInfo(bag, slot) then
			allocatedSlots[key] = nil
		end
	end
end

local function GetOpenBankView()
	local bank = ns:GetModule("Bank")
	if not (bank and bank.IsBankOpen and bank:IsBankOpen()) then
		return nil
	end
	local view = bank.OpenView and bank:OpenView()
	if not (view and view.open and view.GetBankBags) then
		return nil
	end
	return view
end

-- Defined after FindDepositTarget (needs ScanBags / depositFlags helpers).
local ProcessQueuedDeposit

local function DrainDepositQueue()
	if depositDraining then
		return
	end
	if #transferQueue == 0 then
		if not next(allocatedSlots) and queueEventFrame then
			queueEventFrame:UnregisterEvent("BAG_UPDATE")
		end
		return
	end
	depositDraining = true

	local function Step()
		ClearCompletedAllocations()
		if #transferQueue == 0 then
			depositDraining = false
			if not next(allocatedSlots) and queueEventFrame then
				queueEventFrame:UnregisterEvent("BAG_UPDATE")
			end
			return
		end
		local entry = transferQueue[1]
		local result = ProcessQueuedDeposit(entry[1], entry[2])
		if result == true or result == nil then
			table.remove(transferQueue, 1)
		end
		if #transferQueue == 0 and not next(allocatedSlots) then
			depositDraining = false
			if queueEventFrame then
				queueEventFrame:UnregisterEvent("BAG_UPDATE")
			end
			return
		end
		C_Timer_After(STEP_DELAY, Step)
	end

	Step()
end

local function EnsureQueueEvents()
	if not queueEventFrame then
		queueEventFrame = CreateFrame("Frame")
		queueEventFrame:SetScript("OnEvent", DrainDepositQueue)
	end
	queueEventFrame:RegisterEvent("BAG_UPDATE")
end

local function IsAllowedInBank(entry, bankType)
	if not (bankType and C_Bank and C_Bank.IsItemAllowedInBankType) then
		return true
	end
	local location = SlotLocation(entry.bag, entry.slot)
	if not location then
		return false
	end
	return C_Bank.IsItemAllowedInBankType(bankType, location) and true or false
end

local function SlotAllocated(allocated, bag, slot)
	return allocated[bag] and allocated[bag][slot]
end

local function MarkCategoryAllocated(allocated, bag, slot)
	allocated[bag] = allocated[bag] or {}
	allocated[bag][slot] = true
end

--- Baganator BankTransferManager: does this item belong on a tab with `depositFlags`?
local function MatchesDepositFlags(depositFlags, entry)
	if not depositFlags or not FlagsUtil or not BagSlotFlags then
		return true
	end
	if depositFlags == 0 or depositFlags == BagSlotFlags.DisableAutoSort then
		return false
	end

	local itemID = entry.itemID
	if not itemID then
		return false
	end

	local class, isReagent, xpac
	local info = F.GetItemInfoRecord(itemID)
	if not info then
		return false
	end
	class = info.classID
	local reagent = info.isCraftingReagent or info.isReagent
	isReagent = reagent and true or false
	xpac = info.expansionID

	if FlagsUtil.IsSet(depositFlags, BagSlotFlags.ExpansionCurrent) then
		if not (xpac and LE_EXPANSION_LEVEL_CURRENT and xpac == LE_EXPANSION_LEVEL_CURRENT) then
			return false
		end
	elseif FlagsUtil.IsSet(depositFlags, BagSlotFlags.ExpansionLegacy) then
		if not (xpac and LE_EXPANSION_LEVEL_CURRENT and xpac ~= LE_EXPANSION_LEVEL_CURRENT) then
			return false
		end
	end

	local typeFlags = {
		[BagSlotFlags.ClassEquipment] = class == Enum.ItemClass.Armor or class == Enum.ItemClass.Weapon,
		[BagSlotFlags.ClassConsumables] = class == Enum.ItemClass.Consumable,
		[BagSlotFlags.ClassProfessionGoods] = (class == Enum.ItemClass.Tradegoods or class == Enum.ItemClass.Container or class == Enum.ItemClass.Profession or class == Enum.ItemClass.Gem) and not isReagent,
		[BagSlotFlags.ClassReagents] = isReagent and true or false,
		[BagSlotFlags.ClassJunk] = entry.quality == 0,
	}
	local typesSet = false
	for flag, state in pairs(typeFlags) do
		if FlagsUtil.IsSet(depositFlags, flag) then
			typesSet = true
			if state then
				return true
			end
		end
	end
	return not typesSet
end

local function ScanBagSlot(source, bag, slot, allocated, stackOnly)
	if SlotAllocated(allocated, bag, slot) then
		return nil
	end
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if not info then
		if not stackOnly then
			return bag, slot
		end
		return nil
	end
	if not info.itemID then
		return nil
	end
	if info.isLocked or IsLocked(bag, slot) then
		return nil
	end
	local limit = StackLimit(source.itemID)
	local count = info.stackCount or 1
	local add = source.count or 1
	if info.itemID == source.itemID and count + add <= limit then
		return bag, slot
	end
	return nil
end

local function ScanBags(source, bags, allocated, stackOnly, bagChecks)
	local ordered = bagChecks and SortBagIDs(bags, bagChecks.sortOrder) or bags
	for i = 1, #ordered do
		local bag = ordered[i]
		if CanPlaceInBag(bagChecks, bag, source.itemID) then
			local numSlots = C_Container.GetContainerNumSlots(bag) or 0
			for slot = 1, numSlots do
				local targetBag, targetSlot = ScanBagSlot(source, bag, slot, allocated, stackOnly)
				if targetBag then
					return targetBag, targetSlot
				end
			end
		end
	end
	return nil, nil
end

local function ScanBagsEmpty(source, bags, allocated, bagChecks)
	local ordered = bagChecks and SortBagIDs(bags, bagChecks.sortOrder) or bags
	for i = 1, #ordered do
		local bag = ordered[i]
		if CanPlaceInBag(bagChecks, bag, source.itemID) then
			local numSlots = C_Container.GetContainerNumSlots(bag) or 0
			for slot = 1, numSlots do
				if not SlotAllocated(allocated, bag, slot) then
					local info = C_Container.GetContainerItemInfo(bag, slot)
					if not info or not info.itemID then
						return bag, slot
					end
				end
			end
		end
	end
	return nil, nil
end

--- Prefer stacking anywhere, then tabs whose deposit flags match, then any open bank bag.
local function FindDepositTarget(source, view, allocated)
	local bags = view:GetBankBags()
	local bagChecks = GetBagUsageChecks(bags)
	local targetBag, targetSlot = ScanBags(source, bags, allocated, true, bagChecks)
	if targetBag then
		return targetBag, targetSlot
	end

	local bankType = view.bankType
	if bankType and C_Bank and C_Bank.FetchPurchasedBankTabData and C_Bank.FetchPurchasedBankTabIDs then
		local tabData = C_Bank.FetchPurchasedBankTabData(bankType)
		local tabBags = C_Bank.FetchPurchasedBankTabIDs(bankType)
		if tabData and tabBags then
			for i = 1, #tabData do
				local tab = tabData[i]
				local bag = tabBags[i]
				if bag and tab and MatchesDepositFlags(tab.depositFlags, source) then
					targetBag, targetSlot = ScanBags(source, { bag }, allocated, false, bagChecks)
					if targetBag then
						return targetBag, targetSlot
					end
				end
			end
		end
	end

	targetBag, targetSlot = ScanBagsEmpty(source, bags, allocated, bagChecks)
	if targetBag then
		return targetBag, targetSlot
	end

	return ScanBags(source, bags, allocated, false, bagChecks)
end

--- Flat queue allocations → nested map for FindDepositTarget / ScanBags.
local function QueueAllocatedNested()
	local nested = {}
	for key in pairs(allocatedSlots) do
		local bag = floor(key / 1000)
		local slot = key % 1000
		nested[bag] = nested[bag] or {}
		nested[bag][slot] = true
	end
	return nested
end

--- Right-click deposit: prefer the tab picker, then Baganator-style depositFlags
--- across purchased tabs, then any free bank slot (Desktop BankTransferManager).
local function FindQueuedDepositTarget(view, itemID, count, quality)
	local source = { itemID = itemID, count = count or 1, quality = quality }
	local allocated = QueueAllocatedNested()
	local bags = view:GetBankBags()
	local bagChecks = GetBagUsageChecks(bags)
	local preferred = view.GetDepositTargetBag and view:GetDepositTargetBag()

	if preferred then
		local targetBag, targetSlot = ScanBags(source, { preferred }, allocated, true, bagChecks)
		if targetBag then
			return targetBag, targetSlot
		end
		targetBag, targetSlot = ScanBagsEmpty(source, { preferred }, allocated, bagChecks)
		if targetBag then
			return targetBag, targetSlot
		end
	end

	return FindDepositTarget(source, view, allocated)
end

--- @return true moved or source gone; false retry later; nil permanent skip
ProcessQueuedDeposit = function(srcBag, srcSlot)
	if InCombatLockdown and InCombatLockdown() then
		return false
	end
	local view = GetOpenBankView()
	if not view then
		return false
	end
	local location = SlotLocation(srcBag, srcSlot)
	if not (location and C_Item.DoesItemExist(location)) then
		return true
	end
	if C_Item.IsLocked(location) then
		return false
	end
	local info = C_Container.GetContainerItemInfo(srcBag, srcSlot)
	if not (info and info.itemID) then
		return nil
	end
	local count = info.stackCount or 1
	local targetBag, targetSlot = FindQueuedDepositTarget(view, info.itemID, count, info.quality)
	if not (targetBag and targetSlot) then
		local retryKey = SlotKey(srcBag, srcSlot)
		local tries = (depositRetryCounts[retryKey] or 0) + 1
		depositRetryCounts[retryKey] = tries
		if tries >= MAX_DEPOSIT_RETRIES then
			depositRetryCounts[retryKey] = nil
			return nil
		end
		local now = GetTime()
		if now - lastNoBankSlotErrorAt > 2 and UIErrorsFrame then
			lastNoBankSlotErrorAt = now
			UIErrorsFrame:AddMessage(L["No empty bank slots available."], 1, 0.1, 0.1, 1)
		end
		return false
	end
	MarkQueueAllocated(targetBag, targetSlot)
	ClearCursor()
	C_Container.PickupContainerItem(srcBag, srcSlot)
	C_Container.PickupContainerItem(targetBag, targetSlot)
	ClearCursor()
	depositRetryCounts[SlotKey(srcBag, srcSlot)] = nil
	return true
end

local function FindWithdrawTarget(source, allocated)
	local bags = C.BACKPACK_BAGS
	local bagChecks = GetBagUsageChecks(bags)
	local targetBag, targetSlot = ScanBags(source, bags, allocated, true, bagChecks)
	if targetBag then
		return targetBag, targetSlot
	end
	return ScanBagsEmpty(source, bags, allocated, bagChecks)
end

local function Snapshot(entries, predicate)
	local organize = ns:GetModule("Organize")
	local result = {}
	for i = 1, #entries do
		local entry = entries[i]
		if entry and entry.itemID and not entry.isLocked and not (organize and organize:IsSortLocked(entry.bag, entry.slot)) and predicate(entry) then
			result[#result + 1] = {
				bag = entry.bag,
				slot = entry.slot,
				itemID = entry.itemID,
				count = entry.count or 1,
				quality = entry.quality,
				hyperlink = entry.hyperlink,
			}
		end
	end
	return result
end

local function CurrentInfo(item)
	local info = C_Container.GetContainerItemInfo(item.bag, item.slot)
	if not (info and info.itemID) or info.itemID ~= item.itemID then
		return nil
	end
	return info
end

local function Finish(message)
	running = nil
	if message then
		F.Print(message)
	end
	-- Vendor/mail moves fire BAG_UPDATE; open windows pick up via dirty-bag flush.
end

local function BagCachePending()
	return ns.IsBagCachePending and ns:IsBagCachePending()
end

local function StepWithdraw()
	if not running then
		return
	end
	if InCombatLockdown and InCombatLockdown() then
		Finish(L["Can't move items during combat."])
		return
	end
	local view = running.view
	if not (view and view.open and view.CanUse and view:CanUse()) then
		Finish()
		return
	end
	if BagCachePending() then
		C_Timer_After(STEP_DELAY, StepWithdraw)
		return STATUS.WaitingMove
	end
	for i = running.index, #running.items do
		running.index = i + 1
		local item = running.items[i]
		local info = CurrentInfo(item)
		if info then
			if NeedsItemData(item.itemID) then
				running.index = i
				C_Timer_After(STEP_DELAY, StepWithdraw)
				return STATUS.WaitingItemData
			end
			if info.isLocked or IsLocked(item.bag, item.slot) then
				running.index = i
				C_Timer_After(STEP_DELAY, StepWithdraw)
				return STATUS.WaitingUnlock
			end
			local targetBag, targetSlot = FindWithdrawTarget(item, running.allocated or {})
			if not targetBag then
				Finish(format(L["Transferred %d item(s)."], running.count))
				if UIErrorsFrame then
					UIErrorsFrame:AddMessage(L["No empty bag slots available."], 1, 0.1, 0.1, 1)
				end
				return STATUS.Complete
			end
			ClearCursor()
			C_Container.PickupContainerItem(item.bag, item.slot)
			C_Container.PickupContainerItem(targetBag, targetSlot)
			MarkCategoryAllocated(running.allocated, targetBag, targetSlot)
			ClearCursor()
			running.count = running.count + 1
			C_Timer_After(STEP_DELAY, StepWithdraw)
			return STATUS.WaitingMove
		end
	end
	Finish(format(L["Transferred %d item(s)."], running.count))
	return STATUS.Complete
end

local function StepVendor()
	if not running then
		return
	end
	if not MerchantOpen() then
		Finish()
		return
	end
	if BagCachePending() then
		C_Timer_After(STEP_DELAY, StepVendor)
		return STATUS.WaitingMove
	end
	local sold = 0
	while running.index <= #running.items and sold < VENDOR_BATCH_SIZE do
		local i = running.index
		running.index = i + 1
		local item = running.items[i]
		local info = CurrentInfo(item)
		if info then
			if NeedsItemData(item.itemID) then
				running.index = i
				C_Timer_After(STEP_DELAY, StepVendor)
				return STATUS.WaitingItemData
			end
			if info.isLocked or IsLocked(item.bag, item.slot) then
				running.index = i
				C_Timer_After(STEP_DELAY, StepVendor)
				return STATUS.WaitingUnlock
			end
			C_Container.UseContainerItem(item.bag, item.slot)
			running.count = running.count + 1
			sold = sold + 1
		end
	end
	if running.index <= #running.items then
		C_Timer_After(STEP_DELAY, StepVendor)
		return STATUS.WaitingMove
	end
	Finish(format(L["Transferred %d item(s)."], running.count))
	return STATUS.Complete
end

--- Baganator Transfers/AddToMail.lua — UseContainerItem into send-mail slots.
local function StepMail()
	if not running then
		return
	end
	if InCombatLockdown and InCombatLockdown() then
		Finish(L["Can't move items during combat."])
		return
	end
	if not MailOpen() then
		Finish()
		return
	end
	if BagCachePending() then
		C_Timer_After(STEP_DELAY, StepMail)
		return STATUS.WaitingMove
	end
	if SetSendMailShowing then
		SetSendMailShowing(true)
	end
	local attachmentIndex = running.mailSlot or 1
	for i = running.index, #running.items do
		running.index = i + 1
		local item = running.items[i]
		local info = CurrentInfo(item)
		if info then
			while GetSendMailItem and select(2, GetSendMailItem(attachmentIndex)) do
				attachmentIndex = attachmentIndex + 1
			end
			if attachmentIndex > ATTACHMENTS_MAX_SEND then
				Finish(format(L["Transferred %d item(s)."], running.count))
				return STATUS.Complete
			end
			if info.isLocked or IsLocked(item.bag, item.slot) then
				running.index = i
				running.mailSlot = attachmentIndex
				C_Timer_After(STEP_DELAY, StepMail)
				return STATUS.WaitingUnlock
			end
			C_Container.UseContainerItem(item.bag, item.slot)
			running.count = running.count + 1
			running.mailSlot = attachmentIndex + 1
			C_Timer_After(STEP_DELAY, StepMail)
			return STATUS.WaitingMove
		end
	end
	Finish(format(L["Transferred %d item(s)."], running.count))
	return STATUS.Complete
end

--- Baganator Transfers/AddToTrade.lua — PickupContainerItem + ClickTradeButton.
local function StepTrade()
	if not running then
		return
	end
	if InCombatLockdown and InCombatLockdown() then
		Finish(L["Can't move items during combat."])
		return
	end
	if not TradeOpen() then
		Finish()
		return
	end
	if BagCachePending() then
		C_Timer_After(STEP_DELAY, StepTrade)
		return STATUS.WaitingMove
	end
	local tradeSlot = running.tradeSlot or 1
	for i = running.index, #running.items do
		running.index = i + 1
		local item = running.items[i]
		local info = CurrentInfo(item)
		if info then
			while GetTradePlayerItemInfo and select(2, GetTradePlayerItemInfo(tradeSlot)) do
				tradeSlot = tradeSlot + 1
			end
			if tradeSlot > 6 then
				if running.count == 0 and UIErrorsFrame then
					UIErrorsFrame:AddMessage(L["Cannot add any more items to this trade."], 1, 0.1, 0.1, 1)
				end
				Finish(format(L["Transferred %d item(s)."], running.count))
				return STATUS.Complete
			end
			if info.isLocked or IsLocked(item.bag, item.slot) then
				running.index = i
				running.tradeSlot = tradeSlot
				C_Timer_After(STEP_DELAY, StepTrade)
				return STATUS.WaitingUnlock
			end
			ClearCursor()
			C_Container.PickupContainerItem(item.bag, item.slot)
			if ClickTradeButton then
				ClickTradeButton(tradeSlot)
			end
			ClearCursor()
			running.count = running.count + 1
			running.tradeSlot = tradeSlot + 1
			C_Timer_After(STEP_DELAY, StepTrade)
			return STATUS.WaitingMove
		end
	end
	Finish(format(L["Transferred %d item(s)."], running.count))
	return STATUS.Complete
end

local function StepDeposit()
	if not running then
		return
	end
	if InCombatLockdown and InCombatLockdown() then
		Finish(L["Can't move items during combat."])
		return
	end
	local view = running.view
	if not (view and view.open and view.CanUse and view:CanUse()) then
		Finish()
		return
	end
	if BagCachePending() then
		C_Timer_After(STEP_DELAY, StepDeposit)
		return STATUS.WaitingMove
	end

	local isWarband = view.bankType == BANK_TYPE_ACCOUNT
	if isWarband then
		local bankBags = view:GetBankBags()
		local counts = CountByItemIDsInBags(bankBags)
		if running.warbandPrevCounts and BankCountsEqual(counts, running.warbandPrevCounts) then
			C_Timer_After(STEP_DELAY, StepDeposit)
			return STATUS.WaitingMove
		end
		running.warbandPrevCounts = counts
	end

	local moved = 0
	local batchLimit = isWarband and WARBAND_BATCH_SIZE or 1
	while running.index <= #running.items and moved < batchLimit do
		local i = running.index
		running.index = i + 1
		local item = running.items[i]
		local info = CurrentInfo(item)
		if info then
			if NeedsItemData(item.itemID) then
				running.index = i
				C_Timer_After(STEP_DELAY, StepDeposit)
				return STATUS.WaitingItemData
			end
			if info.isLocked or IsLocked(item.bag, item.slot) then
				running.index = i
				C_Timer_After(STEP_DELAY, StepDeposit)
				return STATUS.WaitingUnlock
			end
			local targetBag, targetSlot = FindDepositTarget(item, view, running.allocated or {})
			if not targetBag then
				Finish(format(L["Transferred %d item(s)."], running.count))
				if UIErrorsFrame then
					UIErrorsFrame:AddMessage(L["No empty bank slots available."], 1, 0.1, 0.1, 1)
				end
				running.warbandPrevCounts = nil
				return STATUS.Complete
			end
			ClearCursor()
			C_Container.PickupContainerItem(item.bag, item.slot)
			C_Container.PickupContainerItem(targetBag, targetSlot)
			MarkCategoryAllocated(running.allocated, targetBag, targetSlot)
			ClearCursor()
			running.count = running.count + 1
			moved = moved + 1
		end
	end

	if running.index <= #running.items then
		C_Timer_After(STEP_DELAY, StepDeposit)
		return STATUS.WaitingMove
	end
	running.warbandPrevCounts = nil
	Finish(format(L["Transferred %d item(s)."], running.count))
	return STATUS.Complete
end

function Transfers:IsBusy()
	return running ~= nil
end

function Transfers:Cancel()
	running = nil
	ClearDepositQueue()
	if ClearCursor then
		ClearCursor()
	end
end

--- Queue a backpack right-click deposit. Prefers the bank tab picker, then
--- depositFlags-matched tabs, then any free bank slot (Baganator BankTransferManager).
--- Returns true when this addon handled routing (caller should cancel default).
function Transfers:QueueDeposit(srcBag, srcSlot)
	if not self._hooksInstalled then
		return false
	end
	if not (IS_BACKPACK_BAG and IS_BACKPACK_BAG[srcBag]) then
		return false
	end
	if InCombatLockdown and InCombatLockdown() then
		return false
	end
	if not GetOpenBankView() then
		return false
	end
	if self:IsBusy() then
		return false
	end
	EnsureQueueEvents()
	local result = ProcessQueuedDeposit(srcBag, srcSlot)
	if result == false then
		transferQueue[#transferQueue + 1] = { srcBag, srcSlot }
		return true
	end
	return result == true
end

function Transfers:VendorCategory(categoryName, entries)
	if running then
		F.Print(L["A transfer is already running."])
		return false
	end
	if not MerchantOpen() then
		F.Print(L["Open a merchant first."])
		return false
	end
	local items = Snapshot(entries or {}, IsSellable)
	if #items == 0 then
		F.Print(L["No sellable items found in this category."])
		return false
	end
	running = { kind = "vendor", label = categoryName, items = items, index = 1, count = 0 }
	StepVendor()
	return true
end

function Transfers:DepositCategory(categoryName, entries)
	if running then
		F.Print(L["A transfer is already running."])
		return false
	end
	if InCombatLockdown and InCombatLockdown() then
		F.Print(L["Can't move items during combat."])
		return false
	end
	local bank = ns:GetModule("Bank")
	local view = bank and bank.OpenView and bank:OpenView()
	if not (view and view.open and view.CanUse and view:CanUse()) then
		F.Print(L["Open the bank first."])
		return false
	end
	local items = Snapshot(entries or {}, function(entry)
		return IsAllowedInBank(entry, view.bankType)
	end)
	if #items == 0 then
		F.Print(L["No movable items found in this category."])
		return false
	end
	running = { kind = "deposit", label = categoryName, items = items, index = 1, count = 0, view = view, allocated = {} }
	StepDeposit()
	return true
end

function Transfers:WithdrawCategory(categoryName, entries)
	if running then
		F.Print(L["A transfer is already running."])
		return false
	end
	if InCombatLockdown and InCombatLockdown() then
		F.Print(L["Can't move items during combat."])
		return false
	end
	local bank = ns:GetModule("Bank")
	local view = bank and bank.OpenView and bank:OpenView()
	if not (view and view.open and view.bankType and view.CanUse and view:CanUse()) then
		F.Print(L["Open the bank first."])
		return false
	end
	local items = Snapshot(entries or {}, function()
		return true
	end)
	if #items == 0 then
		F.Print(L["No movable items found in this category."])
		return false
	end
	running = { kind = "withdraw", label = categoryName, items = items, index = 1, count = 0, view = view, allocated = {} }
	StepWithdraw()
	return true
end

function Transfers:MailCategory(categoryName, entries)
	if running then
		F.Print(L["A transfer is already running."])
		return false
	end
	if InCombatLockdown and InCombatLockdown() then
		F.Print(L["Can't move items during combat."])
		return false
	end
	if not MailOpen() then
		F.Print(L["Open the mailbox first."])
		return false
	end
	local items = Snapshot(entries or {}, function()
		return true
	end)
	if #items == 0 then
		F.Print(L["No movable items found in this category."])
		return false
	end
	running = { kind = "mail", label = categoryName, items = items, index = 1, count = 0, mailSlot = 1 }
	StepMail()
	return true
end

function Transfers:TradeCategory(categoryName, entries)
	if running then
		F.Print(L["A transfer is already running."])
		return false
	end
	if InCombatLockdown and InCombatLockdown() then
		F.Print(L["Can't move items during combat."])
		return false
	end
	if not TradeOpen() then
		F.Print(L["Open a trade window first."])
		return false
	end
	local items = Snapshot(entries or {}, function()
		return true
	end)
	if #items == 0 then
		F.Print(L["No movable items found in this category."])
		return false
	end
	running = { kind = "trade", label = categoryName, items = items, index = 1, count = 0, tradeSlot = 1 }
	StepTrade()
	return true
end

function Transfers:OnEnable()
	if self._hooksInstalled then
		return
	end
	self._hooksInstalled = true
	self._eventHandles = self._eventHandles or {}
	local handles = self._eventHandles

	ns:TrackEvent(handles, "MERCHANT_CLOSED", function()
		if running and running.kind == "vendor" then
			Transfers:Cancel()
		end
	end)
	ns:TrackEvent(handles, "BANKFRAME_CLOSED", function()
		if running and (running.kind == "deposit" or running.kind == "withdraw") then
			Transfers:Cancel()
		else
			ClearDepositQueue()
		end
		ns:RefreshBags(false)
	end)
	ns:TrackEvent(handles, "MAIL_CLOSED", function()
		if running and running.kind == "mail" then
			Transfers:Cancel()
		end
	end)
	ns:TrackEvent(handles, "TRADE_CLOSED", function()
		if running and running.kind == "trade" then
			Transfers:Cancel()
		end
	end)
end

function Transfers:OnDisable()
	if not self._hooksInstalled then
		return
	end
	self._hooksInstalled = false
	self:Cancel()
	ClearDepositQueue()
	if queueEventFrame then
		queueEventFrame:UnregisterEvent("BAG_UPDATE")
		queueEventFrame:SetScript("OnEvent", nil)
	end
	ns:UnregisterModuleEventHandles(self._eventHandles)
end
