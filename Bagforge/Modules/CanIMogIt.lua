--[[
	Bagforge - CanIMogIt integration
	-------------------------------------------------------------------------
	When CanIMogIt is installed, show its learnable/transmog overlay on bag and
	bank item buttons. Mirrors NDui's UpdateCanIMogIt: ask the addon for tooltip
	text per slot and paint its icon texture when present.
--]]

local _, ns = ...
local L = ns.L

ns:RegisterDefaults({
	canimogit = {
		enable = true,
	},
})

local CanIMogItMod = ns:NewModule("CanIMogIt", "canimogit")
CanIMogItMod.title = L["CanIMogIt"]
CanIMogItMod.order = 41
CanIMogItMod.group = "display"

local function AddonAvailable()
	return type(_G["CanIMogIt"]) == "table" and type(_G["CanIMogIt"].GetTooltipText) == "function"
end

local function EnsureOverlay(button)
	local tex = button.bfCanIMogIt
	if not tex then
		tex = button:CreateTexture(nil, "OVERLAY", nil, 3)
		tex:SetSize(14, 14)
		tex:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
		button.bfCanIMogIt = tex
	end
	return tex
end

local function UpdateOverlay(button, entry)
	local tex = button.bfCanIMogIt
	if not entry then
		if tex then
			tex:Hide()
		end
		return
	end
	local CIMI = _G["CanIMogIt"]
	if not (CIMI and ns.db.canimogit.enable) then
		if tex then
			tex:Hide()
		end
		return
	end
	local bag, slot = entry.bag, entry.slot
	if not (bag and slot) then
		if tex then
			tex:Hide()
		end
		return
	end
	local ok, text, unmodified = pcall(CIMI.GetTooltipText, CIMI, nil, bag, slot)
	if not ok or not text or text == "" then
		if tex then
			tex:Hide()
		end
		return
	end
	local icons = CIMI.tooltipOverlayIcons
	local icon = icons and unmodified and icons[unmodified]
	if not icon then
		if tex then
			tex:Hide()
		end
		return
	end
	tex = EnsureOverlay(button)
	tex:SetTexture(icon)
	tex:Show()
end

local function InstallCallback()
	if CanIMogItMod._callbackInstalled or not (ns.API and ns.API.RegisterItemButtonCallback) then
		return
	end
	CanIMogItMod._callbackInstalled = ns.API:RegisterItemButtonCallback("canimogit", function(button, _, _, entry)
		UpdateOverlay(button, entry)
	end)
end

function CanIMogItMod:Apply()
	if AddonAvailable() and ns.db.canimogit.enable then
		InstallCallback()
	else
		if ns.API and ns.API.UnregisterItemButtonCallback then
			ns.API:UnregisterItemButtonCallback("canimogit")
			CanIMogItMod._callbackInstalled = false
		end
		ns:RefreshBags(false)
	end
end

function CanIMogItMod:OnEnable()
	if not AddonAvailable() then
		return
	end
	InstallCallback()
	self:Apply()
end

function CanIMogItMod:OnDisable()
	if ns.API and ns.API.UnregisterItemButtonCallback then
		ns.API:UnregisterItemButtonCallback("canimogit")
		CanIMogItMod._callbackInstalled = false
	end
	ns:RefreshBags(false)
end

function CanIMogItMod:OnSettingChanged(key)
	if key == "enable" then
		self:Apply()
	end
end

function CanIMogItMod:RegisterOptions(category, builder)
	builder:Checkbox(category, self, "enable", L["CanIMogIt"], L["Show CanIMogIt's learnable overlay on bag items. Requires the CanIMogIt addon."])
end
