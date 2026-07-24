--[[
	Bagforge - BagBar (equipped-bag flyout)
	-------------------------------------------------------------------------
	Toggleable row of bag-slot ItemButtons below the backpack window. Mixed onto
	the Backpack module via BagBar.Apply(Backpack).
--]]

local _, ns = ...
local C, L = ns.C, ns.L

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local C_Container = C_Container

local GetInventoryItemTexture = GetInventoryItemTexture
local GetInventoryItemQuality = GetInventoryItemQuality
local IsInventoryItemLocked = IsInventoryItemLocked
local PutItemInBag = PutItemInBag
local PickupBagFromSlot = PickupBagFromSlot
local SetItemButtonTexture = SetItemButtonTexture
local SetItemButtonQuality = SetItemButtonQuality
local SetItemButtonCount = SetItemButtonCount
local SetItemButtonDesaturated = SetItemButtonDesaturated
local GameTooltip = GameTooltip
local GameTooltip_Hide = _G["GameTooltip_Hide"]
local BAGSLOT = _G["BAGSLOT"]
local ERR_NOT_IN_COMBAT = _G["ERR_NOT_IN_COMBAT"]
local UIErrorsFrame = _G["UIErrorsFrame"]

local GetBindingKey = GetBindingKey
local GetBindingText = GetBindingText
local MenuUtil = _G["MenuUtil"]
local MenuResponse = _G["MenuResponse"]
local GameTooltip_SetTitle = _G["GameTooltip_SetTitle"]
local GameTooltip_AddNormalLine = _G["GameTooltip_AddNormalLine"]
local NORMAL_FONT_COLOR = _G["NORMAL_FONT_COLOR"]
local EQUIP_CONTAINER_REAGENT = _G["EQUIP_CONTAINER_REAGENT"]
local EQUIP_CONTAINER = _G["EQUIP_CONTAINER"]
local BAG_FILTER_ASSIGNED_TO = _G["BAG_FILTER_ASSIGNED_TO"]

local BagIndex = Enum.BagIndex
local BAG_SLOT_SIZE = 37
local BAG_SLOT_GAP = 6

-- NDui bagTypeColor: tint equipped specialty bag slots on the bar.
local SPECIAL_BAG_COLORS = {
	[2] = { 0, 0.5, 0, 0.35 }, -- herb
	[3] = { 0.8, 0, 0.8, 0.35 }, -- enchanting
	[4] = { 1, 0.8, 0, 0.35 }, -- engineering
	[5] = { 0, 0.8, 0.8, 0.35 }, -- gem
	[6] = { 0.5, 0.4, 0, 0.35 }, -- mining
	[7] = { 0.8, 0.5, 0.5, 0.35 }, -- leatherworking
	[8] = { 0.8, 0.8, 0.8, 0.35 }, -- inscription
	[9] = { 0.4, 0.6, 1, 0.35 }, -- tackle
	[10] = { 0.8, 0, 0, 0.35 }, -- cooking
	[11] = { 0.2, 0.8, 0.2, 0.35 }, -- reagent
}

local HELD_BAG_SLOTS = {}
if BagIndex.ReagentBag then
	HELD_BAG_SLOTS[#HELD_BAG_SLOTS + 1] = BagIndex.ReagentBag
end
HELD_BAG_SLOTS[#HELD_BAG_SLOTS + 1] = BagIndex.Bag_4
HELD_BAG_SLOTS[#HELD_BAG_SLOTS + 1] = BagIndex.Bag_3
HELD_BAG_SLOTS[#HELD_BAG_SLOTS + 1] = BagIndex.Bag_2
HELD_BAG_SLOTS[#HELD_BAG_SLOTS + 1] = BagIndex.Bag_1

local BagBar = {}
ns.BagBar = BagBar

local function OpenBagFilterMenu(button)
	local bagID = button.bagID
	if not bagID then
		return
	end

	local ContainerFrame_CanContainerUseFilterMenu = _G["ContainerFrame_CanContainerUseFilterMenu"]
	local ContainerFrameUtil_EnumerateBagGearFilters = _G["ContainerFrameUtil_EnumerateBagGearFilters"]
	local BAG_FILTER_LABELS = _G["BAG_FILTER_LABELS"]
	local BAG_FILTER_ASSIGN_TO = _G["BAG_FILTER_ASSIGN_TO"]
	local BAG_FILTER_IGNORE = _G["BAG_FILTER_IGNORE"]
	local BAG_FILTER_CLEANUP = _G["BAG_FILTER_CLEANUP"]
	local SELL_ALL_JUNK_ITEMS_EXCLUDE_FLAG = _G["SELL_ALL_JUNK_ITEMS_EXCLUDE_FLAG"]

	if not MenuUtil then
		return
	end

	MenuUtil.CreateContextMenu(button, function(_, root)
		root:SetTag("MENU_BAGFORGE_BAG_BAR_BAG")

		-- 1. Filters (if allowed)
		if ContainerFrame_CanContainerUseFilterMenu and ContainerFrame_CanContainerUseFilterMenu(bagID) then
			root:CreateTitle(BAG_FILTER_ASSIGN_TO or "Assign To")
			if ContainerFrameUtil_EnumerateBagGearFilters then
				for _, flag in ContainerFrameUtil_EnumerateBagGearFilters() do
					local label = BAG_FILTER_LABELS and BAG_FILTER_LABELS[flag] or ("Filter " .. flag)
					local checkbox = root:CreateCheckbox(label, function()
						return C_Container.GetBagSlotFlag(bagID, flag)
					end, function()
						local value = not C_Container.GetBagSlotFlag(bagID, flag)
						C_Container.SetBagSlotFlag(bagID, flag, value)
						if ContainerFrameSettingsManager and ContainerFrameSettingsManager.SetFilterFlag then
							ContainerFrameSettingsManager:SetFilterFlag(bagID, flag, value)
						end
					end)
					if MenuResponse then
						checkbox:SetResponse(MenuResponse.Close)
					end
				end
			end
		end

		-- 2. Cleanup settings
		root:CreateTitle(BAG_FILTER_IGNORE or "Ignore")

		-- Disable Auto Sort / Ignore Cleanup
		local function IsCleanupIgnored()
			if bagID == 0 then
				return C_Container.GetBackpackAutosortDisabled()
			end
			return C_Container.GetBagSlotFlag(bagID, Enum.BagSlotFlags.DisableAutoSort)
		end
		local function SetCleanupIgnored()
			local value = not IsCleanupIgnored()
			if bagID == 0 then
				C_Container.SetBackpackAutosortDisabled(value)
			else
				C_Container.SetBagSlotFlag(bagID, Enum.BagSlotFlags.DisableAutoSort, value)
			end
		end
		local checkboxCleanup = root:CreateCheckbox(BAG_FILTER_CLEANUP or "Ignore Clean Up", IsCleanupIgnored, SetCleanupIgnored)
		if MenuResponse then
			checkboxCleanup:SetResponse(MenuResponse.Close)
		end

		-- Exclude Sell Junk
		if bagID >= 0 and bagID <= 4 then
			local function IsJunkExcluded()
				if bagID == 0 then
					return C_Container.GetBackpackSellJunkDisabled()
				end
				return C_Container.GetBagSlotFlag(bagID, Enum.BagSlotFlags.ExcludeJunkSell)
			end
			local function SetJunkExcluded()
				local value = not IsJunkExcluded()
				if bagID == 0 then
					C_Container.SetBackpackSellJunkDisabled(value)
				else
					C_Container.SetBagSlotFlag(bagID, Enum.BagSlotFlags.ExcludeJunkSell, value)
				end
			end
			local checkboxJunk = root:CreateCheckbox(SELL_ALL_JUNK_ITEMS_EXCLUDE_FLAG or "Ignore Junk Selling", IsJunkExcluded, SetJunkExcluded)
			if MenuResponse then
				checkboxJunk:SetResponse(MenuResponse.Close)
			end
		end
	end)
end

local function BagSlot_OnEnter(button)
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	local ok, hasItem = pcall(GameTooltip.SetInventoryItem, GameTooltip, "player", button.invID)
	if not ok or not hasItem then
		local ContainerFrame_IsReagentBag = _G["ContainerFrame_IsReagentBag"]
		local title = (ContainerFrame_IsReagentBag and ContainerFrame_IsReagentBag(button.bagID)) and EQUIP_CONTAINER_REAGENT or EQUIP_CONTAINER
		if GameTooltip_SetTitle then
			GameTooltip_SetTitle(GameTooltip, title or BAGSLOT or L["Bag Slot"])
		else
			GameTooltip:SetText(title or BAGSLOT or L["Bag Slot"])
		end
	else
		-- Keybind key
		local bindingKey = GetBindingKey(button.commandName or ("TOGGLEBAG" .. button.bagID))
		if bindingKey then
			bindingKey = GetBindingText(bindingKey)
			if NORMAL_FONT_COLOR then
				GameTooltip:AppendText(NORMAL_FONT_COLOR:WrapTextInColorCode(" (" .. bindingKey .. ")"))
			end
		end

		-- Filters list
		local ContainerFrame_CanContainerUseFilterMenu = _G["ContainerFrame_CanContainerUseFilterMenu"]
		if button.bagID and ContainerFrame_CanContainerUseFilterMenu and ContainerFrame_CanContainerUseFilterMenu(button.bagID) then
			if ContainerFrameSettingsManager and ContainerFrameSettingsManager.GenerateFilterList then
				local filterList = ContainerFrameSettingsManager:GenerateFilterList(button.bagID)
				if filterList and GameTooltip_AddNormalLine and BAG_FILTER_ASSIGNED_TO then
					GameTooltip_AddNormalLine(GameTooltip, BAG_FILTER_ASSIGNED_TO:format(filterList), true)
				end
			end
		end
	end
	GameTooltip:Show()

	if button.bagID then
		local backpack = ns:GetModule("Backpack")
		if not (backpack and backpack.frame and backpack.frame:IsShown()) then
			return
		end
		local ItemButton = ns:GetModule("ItemButton")
		if ItemButton and ItemButton.SetBagHighlight then
			ItemButton:SetBagHighlight(button.bagID, true)
		end
	end
end

local function BagSlot_OnLeave(button)
	GameTooltip_Hide()

	if button.bagID then
		local backpack = ns:GetModule("Backpack")
		if not (backpack and backpack.frame and backpack.frame:IsShown()) then
			return
		end
		local ItemButton = ns:GetModule("ItemButton")
		if ItemButton and ItemButton.SetBagHighlight then
			ItemButton:SetBagHighlight(button.bagID, false)
		end
	end
end

local function BagSlot_OnClick(button, mouseButton)
	if InCombatLockdown() then
		if UIErrorsFrame and ERR_NOT_IN_COMBAT then
			UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, 1, 0.3, 0.3)
		end
		return
	end

	if mouseButton == "RightButton" then
		OpenBagFilterMenu(button)
		return
	end

	PutItemInBag(button.invID)
end

local function BagSlot_OnDragStart(button)
	if InCombatLockdown() then
		return
	end
	PickupBagFromSlot(button.invID)
end

function BagBar.Apply(target)
	target.BuildBagBar = BagBar.BuildBagBar
	target.CreateBagSlotButton = BagBar.CreateBagSlotButton
	target.UpdateBagBar = BagBar.UpdateBagBar
	target.ApplyBagBarState = BagBar.ApplyBagBarState
	target.ToggleBagBar = BagBar.ToggleBagBar
end

function BagBar:BuildBagBar()
	if self.bagBar then
		return
	end

	local frame = self.frame
	local panel = ns.Container.New(frame)
	local bar = panel:GetFrame()
	panel.header:SetText(ns.L["Equipped Bags"])
	panel.header:Show()
	self.bagBarPanel = panel
	self.bagBar = bar
	self.bagButtons = {}

	local size = BAG_SLOT_SIZE
	local gap = BAG_SLOT_GAP
	local leftX = C.Layout.PANEL_PADDING_X + C.Layout.PANEL_BIAS_X
	local topInset = C.Layout.PANEL_PADDING + C.Layout.PANEL_HEADER_HEIGHT

	local n = #HELD_BAG_SLOTS
	local col = 0
	for i = 1, n do
		local button = self:CreateBagSlotButton(bar, HELD_BAG_SLOTS[i])
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", bar, "TOPLEFT", leftX + col * (size + gap), -topInset)
		col = col + 1
		self.bagButtons[#self.bagButtons + 1] = button
	end

	local width = C.Layout.PANEL_PADDING_X * 2 + n * size + (n - 1) * gap
	local height = C.Layout.PANEL_PADDING * 2 + C.Layout.PANEL_HEADER_HEIGHT + size
	bar:SetSize(width, height)
	bar:ClearAllPoints()
	bar:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, -C.Layout.PANEL_GAP)

	bar:SetShown(ns.db.backpack.showBagBar)
	self:UpdateBagBar()
end

function BagBar:CreateBagSlotButton(parent, bagID)
	local name = "BagforgeBagSlot" .. bagID
	local button = CreateFrame("ItemButton", name, parent)
	button:SetSize(BAG_SLOT_SIZE, BAG_SLOT_SIZE)
	button.bagID = bagID
	button.invID = C_Container.ContainerIDToInventoryID(bagID)
	button:SetID(button.invID)
	if bagID == Enum.BagIndex.ReagentBag then
		button.commandName = "TOGGLEREAGENTBAG"
	else
		button.commandName = "TOGGLEBAG" .. bagID
	end

	local slotBG = button:CreateTexture(nil, "BACKGROUND", "ItemSlotBackgroundCombinedBagsTemplate", -6)
	slotBG:SetAllPoints(button)
	slotBG:Hide()
	button.slotBG = slotBG

	local typeTint = button:CreateTexture(nil, "BACKGROUND", nil, -5)
	typeTint:SetAllPoints(button)
	typeTint:Hide()
	button.typeTint = typeTint

	button.icon = _G[name .. "IconTexture"]

	button:RegisterForDrag("LeftButton")
	button:RegisterForClicks("AnyUp")
	button:SetScript("OnClick", BagSlot_OnClick)
	button:SetScript("OnReceiveDrag", BagSlot_OnClick)
	button:SetScript("OnDragStart", BagSlot_OnDragStart)
	button:SetScript("OnEnter", BagSlot_OnEnter)
	button:SetScript("OnLeave", BagSlot_OnLeave)

	return button
end

function BagBar:UpdateBagBar()
	if not self.bagButtons then
		return
	end
	if self.bagBar and not self.bagBar:IsShown() then
		return
	end
	local useColors = ns.db and ns.db.backpack and ns.db.backpack.specialBagColors
	for i = 1, #self.bagButtons do
		local button = self.bagButtons[i]
		local icon = GetInventoryItemTexture("player", button.invID)
		local typeTint = button.typeTint
		if icon then
			button.slotBG:Hide()
			if useColors and typeTint and C_Container.GetBagType then
				local bagType = C_Container.GetBagType(button.bagID)
				local color = bagType and SPECIAL_BAG_COLORS[bagType]
				if color then
					typeTint:SetColorTexture(color[1], color[2], color[3], color[4])
					typeTint:Show()
				elseif typeTint then
					typeTint:Hide()
				end
			elseif typeTint then
				typeTint:Hide()
			end
		else
			if typeTint then
				typeTint:Hide()
			end
			button.slotBG:Show()
		end
		SetItemButtonTexture(button, icon)
		local quality = GetInventoryItemQuality("player", button.invID)
		SetItemButtonQuality(button, quality)
		SetItemButtonCount(button, 1)
		local locked = IsInventoryItemLocked(button.invID)
		SetItemButtonDesaturated(button, locked == true)
	end
end

function BagBar:ApplyBagBarState()
	if self.bagBar then
		self.bagBar:SetShown(ns.db.backpack.showBagBar)
		self:UpdateBagBar()
	end
end

function BagBar:ToggleBagBar()
	ns.db.backpack.showBagBar = not ns.db.backpack.showBagBar
	self:ApplyBagBarState()
end
