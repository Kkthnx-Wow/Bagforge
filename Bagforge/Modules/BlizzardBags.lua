--[[
	Bagforge - BlizzardBags (default bag suppression)
	-------------------------------------------------------------------------
	Reparents Blizzard's container frames to a hidden holder and replaces the
	stock open/toggle entry points to drive Bagforge instead. Mixed onto Backpack.

	Important: hooksecurefunc on ToggleBag runs *after* Blizzard has already
	shown ContainerFrame6 (reagent bag). cargBags/NDui replace the globals;
	Baganator/BetterBags reparent frames and hook bag-bar buttons. We replace
	the globals and hide/reparent frames on every open path.
--]]

local _, ns = ...

local CreateFrame = CreateFrame
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local ipairs = ipairs
local hooksecurefunc = hooksecurefunc

local ClearOverrideBindings = ClearOverrideBindings
local GetBindingKey = GetBindingKey
local SetOverrideBindingClick = SetOverrideBindingClick

local BAG_BINDINGS = {
	"TOGGLEBACKPACK",
	"OPENALLBAGS",
	"TOGGLEBAG1",
	"TOGGLEBAG2",
	"TOGGLEBAG3",
	"TOGGLEBAG4",
	"TOGGLEREAGENTBAG",
}

-- Retail: ContainerFrame1–5 = backpack + bags, ContainerFrame6 = reagent bag.
local HELD_CONTAINER_FRAMES = 6

local BlizzardBags = {}
ns.BlizzardBags = BlizzardBags

local lastToggleTime = 0
local TOGGLE_DEBOUNCE = 0.05

function BlizzardBags.Apply(target)
	target.NeutralizeBlizzardBags = BlizzardBags.NeutralizeBlizzardBags
	target.SuppressBlizzardBags = BlizzardBags.SuppressBlizzardBags
	target.SetupKeybinds = BlizzardBags.SetupKeybinds
end

local function HideContainerFrame(frame, holder)
	if not frame then
		return
	end
	frame:Hide()
	if frame:GetParent() ~= holder then
		frame:SetParent(holder)
	end
end

function BlizzardBags:NeutralizeBlizzardBags()
	if not self.hiddenBagHolder then
		local holder = CreateFrame("Frame", "BagforgeHiddenBagHolder", UIParent)
		holder:Hide()
		self.hiddenBagHolder = holder
	end
	local holder = self.hiddenBagHolder

	HideContainerFrame(_G["ContainerFrameCombinedBags"], holder)

	local maxIndex = NUM_TOTAL_BAG_FRAMES or HELD_CONTAINER_FRAMES
	if maxIndex < HELD_CONTAINER_FRAMES then
		maxIndex = HELD_CONTAINER_FRAMES
	end
	for i = 1, maxIndex do
		HideContainerFrame(_G["ContainerFrame" .. i], holder)
	end
end

function BlizzardBags:SuppressBlizzardBags()
	if self.defaultBagsSuppressed then
		return
	end
	self.defaultBagsSuppressed = true

	self:NeutralizeBlizzardBags()

	local backpack = self
	local openOurs = function()
		backpack:NeutralizeBlizzardBags()
		backpack:Open()
	end
	local closeOurs = function()
		backpack:NeutralizeBlizzardBags()
		backpack:Close()
	end
	local toggleOurs = function()
		local now = GetTime()
		if now - lastToggleTime < TOGGLE_DEBOUNCE then
			return
		end
		lastToggleTime = now
		backpack:NeutralizeBlizzardBags()
		backpack:Toggle()
	end

	-- Replace globals so Blizzard never shows ContainerFrame6 (reagent) etc.
	-- Post-hooks alone run too late (frame is already visible).
	_G.ToggleAllBags = toggleOurs
	_G.ToggleBackpack = toggleOurs
	_G.ToggleBag = toggleOurs
	_G.OpenAllBags = openOurs
	_G.OpenBackpack = openOurs
	_G.OpenBag = openOurs

	if hooksecurefunc then
		if _G["CloseAllBags"] then
			hooksecurefunc("CloseAllBags", closeOurs)
		end
		if _G["CloseBackpack"] then
			hooksecurefunc("CloseBackpack", closeOurs)
		end
	end

	if EventRegistry then
		EventRegistry:RegisterCallback("ContainerFrame.OpenBag", function()
			backpack:NeutralizeBlizzardBags()
		end, backpack)
	end
end

function BlizzardBags:SetupKeybinds()
	if InCombatLockdown() then
		self.bindingFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
		return
	end

	ClearOverrideBindings(self.bindingFrame)
	for _, binding in ipairs(BAG_BINDINGS) do
		local key1, key2 = GetBindingKey(binding)
		if key1 then
			SetOverrideBindingClick(self.bindingFrame, true, key1, "BagforgeToggleButton")
		end
		if key2 then
			SetOverrideBindingClick(self.bindingFrame, true, key2, "BagforgeToggleButton")
		end
	end
end
