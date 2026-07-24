--[[
	Bagforge - Tabs (bottom tab strip widget)
	-------------------------------------------------------------------------
	A small row of Blizzard-style tabs that tucks under the bottom edge of a
	window, like the tabs along the bottom of the character sheet or the bank.
	The bank window uses it to switch between the character bank and the warband
	bank without a separate toggle button.

	This is our own minimal re-code of the idea BetterBags ships in frames/tabs.lua:
	we keep its PanelTabButtonTemplate styling (toggling the *Active textures for
	the selected tab, nudging the label down a few px) but drop everything we
	don't need yet - themes, drag-to-reorder, icon tabs and secure purchase tabs.
	A Tab strip is a plain Lua object wrapping a container frame; tabs are keyed
	by an opaque id the caller chooses (we use the bank view's enabledKey).
--]]

local _, ns = ...

local CreateFrame = CreateFrame
local PanelTemplates_TabResize = PanelTemplates_TabResize

local Tabs = {}
ns.Tabs = Tabs

local TAB_SPACING = 4 -- gap between adjacent tabs
local START_X = 6 -- left inset of the first tab

-- Selected/deselected look. PanelTabButtonTemplate ships two texture sets: the
-- plain Left/Middle/Right (deselected) and LeftActive/MiddleActive/RightActive
-- (selected). We swap between them and nudge the label, matching Blizzard.
local function StyleSelected(tab, selected)
	if not tab.Left then
		return
	end
	tab.Left:SetShown(not selected)
	tab.Middle:SetShown(not selected)
	tab.Right:SetShown(not selected)
	if tab.LeftActive then
		tab.LeftActive:SetShown(selected)
		tab.MiddleActive:SetShown(selected)
		tab.RightActive:SetShown(selected)
	end
	if tab.Text then
		local x = selected and (tab.selectedTextX or 0) or (tab.deselectedTextX or 0)
		local y = selected and (tab.selectedTextY or -3) or (tab.deselectedTextY or 2)
		tab.Text:SetPoint("CENTER", tab, "CENTER", x, y)
	end
end

local proto = {}
proto.__index = proto

--- Build a tab strip tucked under `parent`'s bottom edge.
function Tabs.Create(parent)
	local self = setmetatable({
		parent = parent,
		tabs = {}, -- ordered list of tab buttons
		byId = {}, -- id -> tab button
		selectedId = nil,
		onClick = nil,
	}, proto)

	local frame = CreateFrame("Frame", nil, parent)
	frame:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", 0, 2)
	frame:SetPoint("TOPRIGHT", parent, "BOTTOMRIGHT", 0, 2)
	frame:SetHeight(32)
	-- Sit a level below the parent so each tab's top edge tucks under the window
	-- border (the classic Blizzard tab look).
	local level = parent:GetFrameLevel()
	frame:SetFrameLevel(level > 0 and level - 1 or 0)
	self.frame = frame

	return self
end

--- The handler invoked with the clicked tab's id (caller decides what to do).
function proto:SetClickHandler(fn)
	self.onClick = fn
end

--- Add a tab. `id` is any value the caller uses to identify it; `text` is the
--- visible label.
function proto:AddTab(id, text)
	local tab = CreateFrame("Button", nil, self.frame, "PanelTabButtonTemplate")
	tab.bfId = id
	tab:SetText(text)
	PanelTemplates_TabResize(tab, 0)
	tab:SetScript("OnClick", function()
		if self.onClick then
			self.onClick(id)
		end
	end)
	StyleSelected(tab, false)

	self.tabs[#self.tabs + 1] = tab
	self.byId[id] = tab
	self:Reanchor()
	return tab
end

--- Re-lay every shown tab left-to-right. Anchoring each tab directly to the
--- container (not to its neighbour) keeps positions independent.
function proto:Reanchor()
	local x = START_X
	for i = 1, #self.tabs do
		local tab = self.tabs[i]
		if tab:IsShown() then
			tab:ClearAllPoints()
			tab:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x, 0)
			x = x + tab:GetWidth() + TAB_SPACING
		end
	end
end

--- Re-measure every tab and re-lay the row. Tabs created while their window is
--- hidden can mis-measure their label width, so callers run this once the window
--- is on screen (cheap: a handful of tabs).
function proto:Resize()
	for i = 1, #self.tabs do
		PanelTemplates_TabResize(self.tabs[i], 0)
	end
	self:Reanchor()
end

function proto:ShowTab(id)
	local tab = self.byId[id]
	if tab and not tab:IsShown() then
		tab:Show()
		self:Reanchor()
	end
end

function proto:HideTab(id)
	local tab = self.byId[id]
	if tab and tab:IsShown() then
		tab:Hide()
		self:Reanchor()
	end
end

--- Mark `id`'s tab selected (and the rest deselected).
function proto:Select(id)
	self.selectedId = id
	for i = 1, #self.tabs do
		local tab = self.tabs[i]
		StyleSelected(tab, tab.bfId == id)
	end
end

--- Show or hide the whole strip (used to hide it when there's nothing to switch).
function proto:SetShown(shown)
	self.frame:SetShown(shown and true or false)
end
