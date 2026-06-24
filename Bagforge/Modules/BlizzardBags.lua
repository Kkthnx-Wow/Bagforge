--[[
	Bagforge - BlizzardBags (default bag suppression)
	-------------------------------------------------------------------------
	Reparents Blizzard's container frames to a hidden holder and hooks the stock
	open/close entry points to drive Bagforge instead. Mixed onto Backpack.
--]]

local _, ns = ...

local CreateFrame = CreateFrame
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

local BlizzardBags = {}
ns.BlizzardBags = BlizzardBags

function BlizzardBags.Apply(target)
	target.NeutralizeBlizzardBags = BlizzardBags.NeutralizeBlizzardBags
	target.SuppressBlizzardBags = BlizzardBags.SuppressBlizzardBags
	target.SetupKeybinds = BlizzardBags.SetupKeybinds
end

function BlizzardBags:NeutralizeBlizzardBags()
	if not self.hiddenBagHolder then
		local holder = CreateFrame("Frame", "BagforgeHiddenBagHolder", UIParent)
		holder:Hide()
		self.hiddenBagHolder = holder
	end
	local holder = self.hiddenBagHolder

	local combined = _G["ContainerFrameCombinedBags"]
	if combined and combined:GetParent() ~= holder then
		combined:SetParent(holder)
	end
	for i = 1, (NUM_TOTAL_BAG_FRAMES or 13) do
		local frame = _G["ContainerFrame" .. i]
		if frame and frame:GetParent() ~= holder then
			frame:SetParent(holder)
		end
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
		backpack:NeutralizeBlizzardBags()
		backpack:Toggle()
	end

	if hooksecurefunc then
		if _G["OpenAllBags"] then
			hooksecurefunc("OpenAllBags", openOurs)
		end
		if _G["CloseAllBags"] then
			hooksecurefunc("CloseAllBags", closeOurs)
		end
		if _G["ToggleAllBags"] then
			hooksecurefunc("ToggleAllBags", toggleOurs)
		end
		if _G["OpenBag"] then
			hooksecurefunc("OpenBag", openOurs)
		end
		if _G["OpenBackpack"] then
			hooksecurefunc("OpenBackpack", openOurs)
		end
		if _G["CloseBackpack"] then
			hooksecurefunc("CloseBackpack", closeOurs)
		end
		if _G["ToggleBag"] then
			hooksecurefunc("ToggleBag", toggleOurs)
		end
		if _G["ToggleBackpack"] then
			hooksecurefunc("ToggleBackpack", toggleOurs)
		end
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
