--[[
	Bagforge - BagBar (equipped-bag flyout)
	-------------------------------------------------------------------------
	Toggleable row of bag-slot ItemButtons below the backpack window. Mixed onto
	the Backpack module via BagBar.Apply(Backpack).
--]]

local _, ns = ...
local C, F, L = ns.C, ns.F, ns.L

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local C_Container = C_Container
local ipairs = ipairs

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

local BagIndex = Enum.BagIndex
local BAG_SLOT_SIZE = 37
local BAG_SLOT_GAP = 6

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

local function BagSlot_OnEnter(button)
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	local hasItem = GameTooltip:SetInventoryItem("player", button.invID)
	if not hasItem then
		GameTooltip:SetText(BAGSLOT or L["Bag Slot"])
	end
	GameTooltip:Show()
end

local function BagSlot_OnClick(button)
	if InCombatLockdown() then
		if UIErrorsFrame and ERR_NOT_IN_COMBAT then
			UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, 1, 0.3, 0.3)
		end
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

	local slotBG = button:CreateTexture(nil, "BACKGROUND", "ItemSlotBackgroundCombinedBagsTemplate", -6)
	slotBG:SetAllPoints(button)
	slotBG:Hide()
	button.slotBG = slotBG

	button.icon = _G[name .. "IconTexture"]

	button:RegisterForDrag("LeftButton")
	button:RegisterForClicks("AnyUp")
	button:SetScript("OnClick", BagSlot_OnClick)
	button:SetScript("OnReceiveDrag", BagSlot_OnClick)
	button:SetScript("OnDragStart", BagSlot_OnDragStart)
	button:SetScript("OnEnter", BagSlot_OnEnter)
	button:SetScript("OnLeave", GameTooltip_Hide)

	return button
end

function BagBar:UpdateBagBar()
	if not self.bagButtons then
		return
	end
	if self.bagBar and not self.bagBar:IsShown() then
		return
	end
	for i = 1, #self.bagButtons do
		local button = self.bagButtons[i]
		local icon = GetInventoryItemTexture("player", button.invID)
		if icon then
			button.slotBG:Hide()
		else
			button.slotBG:Show()
		end
		SetItemButtonTexture(button, icon)
		local quality = GetInventoryItemQuality("player", button.invID)
		if F.NotSecret(quality) then
			SetItemButtonQuality(button, quality)
		end
		SetItemButtonCount(button, 1)
		SetItemButtonDesaturated(button, IsInventoryItemLocked(button.invID))
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
