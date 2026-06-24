--[[
	Bagforge - Transfers
	-------------------------------------------------------------------------
	A small Baganator-inspired action engine for context moves from visible bag
	categories. It deliberately starts narrow:

	  * vendor a visible backpack category while a merchant is open
	  * deposit a visible backpack category into the currently open bank view

	Each operation performs one cursor/container action per tick and then waits
	for the client/server to catch up. That mirrors Baganator's status-driven
	transfer model without importing its full Syndicator/cache stack.
--]]

local _, ns = ...
local C, F, L = ns.C, ns.F, ns.L

local C_Bank = C_Bank
local C_Container = C_Container
local C_Item = C_Item
local GetItemMaxStackSizeByID = C_Item.GetItemMaxStackSizeByID
local C_Timer_After = C_Timer.After
local ClearCursor = ClearCursor
local InCombatLockdown = InCombatLockdown
local ItemLocation = ItemLocation
local MerchantFrame = _G["MerchantFrame"]
local UIErrorsFrame = UIErrorsFrame
local FlagsUtil = _G["FlagsUtil"]
local LE_EXPANSION_LEVEL_CURRENT = _G["LE_EXPANSION_LEVEL_CURRENT"]
local ipairs = ipairs
local pairs = pairs
local select = select
local wipe = wipe
local format = string.format

local BagSlotFlags = Enum.BagSlotFlags

local STEP_DELAY = 0.15

local STATUS = {
	Complete = 0,
	WaitingMove = 1,
	WaitingUnlock = 2,
}

local Transfers = ns:NewModule("Transfers")
ns.Transfers = Transfers
Transfers.Status = STATUS

local running

local function MerchantOpen()
	return MerchantFrame and MerchantFrame:IsShown()
end

local function SlotLocation(bag, slot)
	return ItemLocation and ItemLocation:CreateFromBagAndSlot(bag, slot)
end

local function IsLocked(bag, slot)
	local location = SlotLocation(bag, slot)
	return location and C_Item.DoesItemExist(location) and C_Item.IsLocked(location)
end

local function IsSellable(entry)
	if not entry or entry.noValue or entry.isLocked then
		return false
	end
	local id = entry.itemID
	if not (id and F.NotSecret(id)) then
		return false
	end
	local price = select(11, C_Item.GetItemInfo(id))
	return price and F.NotSecret(price) and price > 0
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

local function StackLimit(itemID)
	if GetItemMaxStackSizeByID then
		local limit = GetItemMaxStackSizeByID(itemID)
		if limit then
			return limit
		end
	end
	return select(8, C_Item.GetItemInfo(itemID)) or 1
end

local function SlotAllocated(allocated, bag, slot)
	return allocated[bag] and allocated[bag][slot]
end

local function MarkAllocated(allocated, bag, slot)
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
	if not (itemID and F.NotSecret(itemID)) then
		return false
	end

	local class, isReagent, xpac
	local info = C_Item.GetItemInfo(itemID)
	if not info then
		return false
	end
	class = info.classID
	isReagent = info.isReagent
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
		[BagSlotFlags.ClassJunk] = F.NotSecret(entry.quality) and entry.quality == 0,
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
	if not (info.itemID and F.NotSecret(info.itemID)) then
		if not stackOnly then
			return bag, slot
		end
		return nil
	end
	if info.isLocked or IsLocked(bag, slot) then
		return nil
	end
	local limit = StackLimit(source.itemID)
	local count = info.stackCount or 1
	local add = source.count or 1
	if info.itemID == source.itemID and F.NotSecret(count) and F.NotSecret(add) and count + add <= limit then
		return bag, slot
	end
	return nil
end

local function ScanBags(source, bags, allocated, stackOnly)
	for _, bag in ipairs(bags) do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local targetBag, targetSlot = ScanBagSlot(source, bag, slot, allocated, stackOnly)
			if targetBag then
				return targetBag, targetSlot
			end
		end
	end
	return nil, nil
end

local function ScanBagsEmpty(source, bags, allocated)
	for _, bag in ipairs(bags) do
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
	return nil, nil
end

--- Prefer stacking anywhere, then tabs whose deposit flags match, then any open bank bag.
local function FindDepositTarget(source, view, allocated)
	local bags = view:GetBankBags()
	local targetBag, targetSlot = ScanBags(source, bags, allocated, true)
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
					targetBag, targetSlot = ScanBags(source, { bag }, allocated, false)
					if targetBag then
						return targetBag, targetSlot
					end
				end
			end
		end
	end

	targetBag, targetSlot = ScanBagsEmpty(source, bags, allocated)
	if targetBag then
		return targetBag, targetSlot
	end

	return ScanBags(source, bags, allocated, false)
end

local function Snapshot(entries, predicate)
	local organize = ns:GetModule("Organize")
	local result = {}
	for i = 1, #entries do
		local entry = entries[i]
		if entry and entry.itemID and F.NotSecret(entry.itemID) and not entry.isLocked and not (organize and organize:IsSortLocked(entry.bag, entry.slot)) and predicate(entry) then
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
	if not (info and info.itemID and F.NotSecret(info.itemID)) or info.itemID ~= item.itemID then
		return nil
	end
	return info
end

local function Finish(message)
	running = nil
	if message then
		F.Print(message)
	end
	ns:RefreshBags(true)
end

local function StepVendor()
	if not running then
		return
	end
	if not MerchantOpen() then
		Finish()
		return
	end
	for i = running.index, #running.items do
		running.index = i + 1
		local item = running.items[i]
		local info = CurrentInfo(item)
		if info then
			if info.isLocked or IsLocked(item.bag, item.slot) then
				running.index = i
				C_Timer_After(STEP_DELAY, StepVendor)
				return STATUS.WaitingUnlock
			end
			C_Container.UseContainerItem(item.bag, item.slot)
			running.count = running.count + 1
			C_Timer_After(STEP_DELAY, StepVendor)
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
	for i = running.index, #running.items do
		running.index = i + 1
		local item = running.items[i]
		local info = CurrentInfo(item)
		if info then
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
				return STATUS.Complete
			end
			ClearCursor()
			C_Container.PickupContainerItem(item.bag, item.slot)
			C_Container.PickupContainerItem(targetBag, targetSlot)
			MarkAllocated(running.allocated, targetBag, targetSlot)
			ClearCursor()
			running.count = running.count + 1
			C_Timer_After(STEP_DELAY, StepDeposit)
			return STATUS.WaitingMove
		end
	end
	Finish(format(L["Transferred %d item(s)."], running.count))
	return STATUS.Complete
end

function Transfers:IsBusy()
	return running ~= nil
end

function Transfers:Cancel()
	running = nil
	if ClearCursor then
		ClearCursor()
	end
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

function Transfers:OnEnable()
	ns:RegisterEvent("MERCHANT_CLOSED", function()
		if running and running.kind == "vendor" then
			self:Cancel()
		end
	end)
	ns:RegisterEvent("BANKFRAME_CLOSED", function()
		if running and running.kind == "deposit" then
			self:Cancel()
		end
	end)
end
