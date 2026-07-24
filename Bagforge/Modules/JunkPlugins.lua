--[[
	Bagforge - Junk plugin bridges
	-------------------------------------------------------------------------
	Auto-registers popular junk addons through Bagforge.API:RegisterJunkDetector
	(mirrors Baganator/API/Junk.lua). Junk coin overlays refresh when the
	third-party list changes.
--]]

local _, ns = ...
local API = ns.API
if not API then
	return
end

local C_AddOns = C_AddOns
local hooksecurefunc = hooksecurefunc
local C_Timer_After = C_Timer.After
local CreateFrame = CreateFrame
local wipe = wipe

local JunkPlugins = ns:NewModule("JunkPlugins")

local function RefreshButtons()
	local mod = ns:GetModule("JunkPlugins")
	if mod and not mod._hooksInstalled then
		return
	end
	if API.RequestItemButtonsRefresh then
		API:RequestItemButtonsRefresh()
	end
end

--- Wait for a LOD addon, tracking the waiter frame for OnDisable teardown.
local function WhenLoaded(self, addon, fn)
	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(addon) then
		fn()
		return
	end
	local frame = CreateFrame("Frame")
	self._waiters = self._waiters or {}
	self._waiters[#self._waiters + 1] = frame
	frame:RegisterEvent("ADDON_LOADED")
	frame:SetScript("OnEvent", function(f, _, name)
		if name == addon then
			f:UnregisterEvent("ADDON_LOADED")
			f:SetScript("OnEvent", nil)
			if self._hooksInstalled then
				fn()
			end
		end
	end)
end

local function ClearWaiters(self)
	local waiters = self._waiters
	if not waiters then
		return
	end
	for i = 1, #waiters do
		local frame = waiters[i]
		if frame then
			frame:UnregisterEvent("ADDON_LOADED")
			frame:SetScript("OnEvent", nil)
		end
	end
	wipe(waiters)
end

local JUNK_KEYS = { "selljunk", "scrap", "dejunk", "vendor" }

function JunkPlugins:OnDisable()
	if not self._hooksInstalled then
		return
	end
	self._hooksInstalled = false
	ClearWaiters(self)
	-- Unregister detectors so IsItemJunk stops calling them. Keep `_installed`
	-- so re-enable re-registers without stacking another hooksecurefunc.
	for i = 1, #JUNK_KEYS do
		API:UnregisterJunkDetector(JUNK_KEYS[i])
	end
end

local function ReregisterIfInstalled(self)
	-- After disable we dropped detectors but left `_installed` + permanent hooks.
	-- Re-enable only needs RegisterJunkDetector again (hooks already wired).
	if self._installed.selljunk and SellJunk then
		API:RegisterJunkDetector({
			key = "selljunk",
			source = "SellJunk",
			isJunk = function(bag, slot, entry)
				local link = entry and entry.hyperlink
				if link and SellJunk.CheckItemIsJunk then
					return SellJunk:CheckItemIsJunk(link, bag, slot) and true or false
				end
				return false
			end,
		})
	end
	if self._installed.scrap and Scrap then
		API:RegisterJunkDetector({
			key = "scrap",
			source = "Scrap",
			isJunk = function(bag, slot, entry)
				local id = entry and entry.itemID
				if id and Scrap.IsJunk then
					return Scrap:IsJunk(id, bag, slot) and true or false
				end
				return false
			end,
		})
	end
	if self._installed.dejunk and DejunkApi then
		API:RegisterJunkDetector({
			key = "dejunk",
			source = "Dejunk",
			isJunk = function(bag, slot)
				if DejunkApi.IsJunk then
					return DejunkApi:IsJunk(bag, slot) and true or false
				end
				return false
			end,
		})
	end
	if self._installed.vendor and Vendor and Vendor.EvaluateItem then
		API:RegisterJunkDetector({
			key = "vendor",
			source = "Vendor",
			isJunk = function(bag, slot)
				return Vendor.EvaluateItem(bag, slot) ~= 0
			end,
		})
	end
end

function JunkPlugins:OnEnable()
	if self._hooksInstalled then
		return
	end
	self._hooksInstalled = true
	self._installed = self._installed or {}

	-- Module was disabled earlier this session: detectors were dropped, hooks remain.
	if self._installed.selljunk or self._installed.scrap or self._installed.dejunk or self._installed.vendor then
		ReregisterIfInstalled(self)
	end

	WhenLoaded(self, "SellJunk", function()
		if self._installed.selljunk or not SellJunk then
			return
		end
		self._installed.selljunk = true
		API:RegisterJunkDetector({
			key = "selljunk",
			source = "SellJunk",
			isJunk = function(bag, slot, entry)
				local link = entry and entry.hyperlink
				if link and SellJunk.CheckItemIsJunk then
					return SellJunk:CheckItemIsJunk(link, bag, slot) and true or false
				end
				return false
			end,
		})
		-- hooksecurefunc cannot be undone; one-shot so re-enable doesn't stack.
		if SellJunk.Add then
			hooksecurefunc(SellJunk, "Add", RefreshButtons)
		end
		if SellJunk.Rem then
			hooksecurefunc(SellJunk, "Rem", RefreshButtons)
		end
	end)

	WhenLoaded(self, "Scrap", function()
		if self._installed.scrap or not Scrap then
			return
		end
		self._installed.scrap = true
		API:RegisterJunkDetector({
			key = "scrap",
			source = "Scrap",
			isJunk = function(bag, slot, entry)
				local id = entry and entry.itemID
				if id and Scrap.IsJunk then
					return Scrap:IsJunk(id, bag, slot) and true or false
				end
				return false
			end,
		})
		if Scrap.ToggleJunk then
			hooksecurefunc(Scrap, "ToggleJunk", RefreshButtons)
		end
	end)

	WhenLoaded(self, "Dejunk", function()
		if self._installed.dejunk or not DejunkApi or not DejunkApi.Events then
			return
		end
		self._installed.dejunk = true
		API:RegisterJunkDetector({
			key = "dejunk",
			source = "Dejunk",
			isJunk = function(bag, slot)
				if DejunkApi.IsJunk then
					return DejunkApi:IsJunk(bag, slot) and true or false
				end
				return false
			end,
		})
		if DejunkApi.AddListener then
			DejunkApi:AddListener(function(event)
				if event ~= DejunkApi.Events.BagsUpdated then
					RefreshButtons()
				end
			end)
		end
	end)

	WhenLoaded(self, "Vendor", function()
		if self._installed.vendor or not Vendor or not Vendor.EvaluateItem then
			return
		end
		self._installed.vendor = true
		API:RegisterJunkDetector({
			key = "vendor",
			source = "Vendor",
			isJunk = function(bag, slot)
				return Vendor.EvaluateItem(bag, slot) ~= 0
			end,
		})
		C_Timer_After(0, function()
			if not self._hooksInstalled then
				return
			end
			if Vendor.RegisterExtension then
				Vendor.RegisterExtension({
					Addon = ns.title or "Bagforge",
					Source = ns.title or "Bagforge",
					Version = 1.0,
					OnRuleUpdate = RefreshButtons,
				})
			end
		end)
	end)
end
