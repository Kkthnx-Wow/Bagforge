--[[
	Bagforge - CategoryManager (manage custom + search categories)
	-------------------------------------------------------------------------
	A small native window listing every player-managed category - custom
	(assigned items) and saved searches - with inline controls to rename,
	recolour, reorder, enable/disable, edit the query, set group-by, and delete.
	Modelled on BetterBags' config/categorypane.lua, kept deliberately light: one
	SettingsFrameTemplate shell, a plain scroll list, and a pool of reused rows.

	All persistence lives in Modules/Organize (it owns ns.db.organize); this
	module is pure UI and calls Organize:* for every mutation. Built lazily on
	first open (Peterodox deferred-setup idiom) so it costs nothing until used.
--]]

local _, ns = ...
local L, F = ns.L, ns.F
local format = string.format
local tinsert = table.insert
local CreateFrame = CreateFrame
local C_AddOns = C_AddOns

local Manager = ns:NewModule("CategoryManager", nil)

-- SettingsFrameTemplate lives in the load-on-demand Blizzard_Settings_Shared
-- addon. Container.lua loads it before the bags use it; the manager can be
-- opened on its own (slash command) before the bags ever open, so it must
-- guarantee the template is present or CreateFrame builds a broken shell.
local SETTINGS_SHARED = "Blizzard_Settings_Shared"
local function EnsureSettingsTemplate()
	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.LoadAddOn and not C_AddOns.IsAddOnLoaded(SETTINGS_SHARED) then
		pcall(C_AddOns.LoadAddOn, SETTINGS_SHARED)
	end
end

local GROUP_CYCLE = { "none", "type", "subtype", "expansion", "quality", "slot" }
local GROUP_LABEL = {
	none = L["No Group"],
	type = L["Type"],
	subtype = L["Subtype"],
	expansion = L["Expansion"],
	quality = L["Quality"],
	slot = L["Slot"],
}

local ROW_HEIGHT = 30
local WINDOW_WIDTH = 460
local WINDOW_HEIGHT = 520

-- StaticPopup edit boxes are "EditBox" on modern clients, "editBox" on older.
local function PopupEdit(popup)
	return popup and (popup.EditBox or popup.editBox)
end

local function Org()
	return ns:GetModule("Organize")
end

-- ---------------------------------------------------------------------------
-- Dialogs (rename / new search / edit query)
-- ---------------------------------------------------------------------------
StaticPopupDialogs["BAGFORGE_RENAME_CATEGORY"] = {
	text = L["Rename category to:"],
	button1 = _G["ACCEPT"],
	button2 = _G["CANCEL"],
	hasEditBox = true,
	maxLetters = 64,
	OnShow = function(self, data)
		local edit = PopupEdit(self)
		if edit and data then
			edit:SetText(data.name or "")
			edit:HighlightText()
		end
	end,
	OnAccept = function(self, data)
		local edit = PopupEdit(self)
		if edit and data then
			Org():RenameCategory(data.name, edit:GetText(), data.kind)
			Manager:Refresh()
		end
	end,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		StaticPopup_OnClick(parent, 1)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

StaticPopupDialogs["BAGFORGE_EDIT_QUERY"] = {
	text = L["Search query (e.g. type:glyph or sub:herb | sub:cloth):"],
	button1 = _G["ACCEPT"],
	button2 = _G["CANCEL"],
	hasEditBox = true,
	editBoxWidth = 300,
	maxLetters = 255,
	OnShow = function(self, data)
		local edit = PopupEdit(self)
		if edit and data then
			edit:SetText(data.query or "")
			edit:HighlightText()
		end
	end,
	OnAccept = function(self, data)
		local edit = PopupEdit(self)
		if edit and data then
			Org():SetSearchQuery(data.name, edit:GetText())
			Manager:Refresh()
		end
	end,
	EditBoxOnEnterPressed = function(self)
		StaticPopup_OnClick(self:GetParent(), 1)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

StaticPopupDialogs["BAGFORGE_NEW_SEARCH"] = {
	text = L["Name the new search category:"],
	button1 = _G["ACCEPT"],
	button2 = _G["CANCEL"],
	hasEditBox = true,
	maxLetters = 64,
	OnAccept = function(self)
		local edit = PopupEdit(self)
		if not edit then
			return
		end
		local name = edit:GetText()
		if name and name:gsub("%s", "") ~= "" then
			Org():SetSearch(name, "")
			Manager:Refresh()
			-- Chain straight into the query editor for the freshly-made search.
			StaticPopup_Show("BAGFORGE_EDIT_QUERY", nil, nil, { name = name, query = "" })
		end
	end,
	EditBoxOnEnterPressed = function(self)
		StaticPopup_OnClick(self:GetParent(), 1)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

StaticPopupDialogs["BAGFORGE_EXPORT_CATEGORIES"] = {
	text = L["Copy this JSON to share your categories:"],
	button1 = _G["CLOSE"],
	hasEditBox = true,
	editBoxWidth = 380,
	maxLetters = 0,
	OnShow = function(self)
		local edit = PopupEdit(self)
		if edit then
			local json = Org():ExportCategories()
			if not json then
				json = L["JSON export is unavailable on this client."]
			end
			edit:SetText(json)
			edit:HighlightText()
			edit:SetFocus()
		end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

StaticPopupDialogs["BAGFORGE_IMPORT_CATEGORIES"] = {
	text = L["Paste category JSON to import:"],
	button1 = _G["ACCEPT"],
	button2 = _G["CANCEL"],
	hasEditBox = true,
	editBoxWidth = 380,
	maxLetters = 0,
	OnAccept = function(self)
		local edit = PopupEdit(self)
		if edit then
			local ok, msg = Org():ImportCategories(edit:GetText())
			F.Print(msg or (ok and L["Categories imported."] or L["Import failed."]))
			if ok then
				Manager:Refresh()
			end
		end
	end,
	EditBoxOnEnterPressed = function(self)
		StaticPopup_OnClick(self:GetParent(), 1)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

-- ---------------------------------------------------------------------------
-- Colour picker (modern SetupColorPickerAndShow, restores on cancel)
-- ---------------------------------------------------------------------------
local function OpenColorPicker(name, current)
	local r, g, b = 1, 0.82, 0
	if current then
		r, g, b = current[1], current[2], current[3]
	end
	local function apply()
		local nr, ng, nb = ColorPickerFrame:GetColorRGB()
		Org():SetColor(name, nr, ng, nb)
		Manager:Refresh()
	end
	-- swatchFunc applies live, so cancel must undo: restore the colour the panel
	-- had before opening, or clear it entirely if it had none (don't bake in the
	-- default yellow the picker seeded the swatch with).
	local hadColor = current ~= nil
	ColorPickerFrame:SetupColorPickerAndShow({
		r = r,
		g = g,
		b = b,
		hasOpacity = false,
		swatchFunc = apply,
		cancelFunc = function()
			if hadColor then
				Org():SetColor(name, r, g, b)
			else
				Org():ClearColor(name)
			end
			Manager:Refresh()
		end,
	})
end

-- ---------------------------------------------------------------------------
-- Row widgets
-- ---------------------------------------------------------------------------
local function MakeTextButton(parent, width, label)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 20)
	b:SetText(label)
	return b
end

local function MakeArrow(parent, up)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(28, 28)
	local tex = up and "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up" or "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up"
	b:SetNormalTexture(tex)
	b:SetPushedTexture(tex)
	b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	return b
end

-- Build one (initially blank) row. Apply() wires it to a managed category.
local function CreateRow(content)
	local row = CreateFrame("Frame", nil, content)
	row:SetHeight(ROW_HEIGHT)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints(row)
	row.bg:SetColorTexture(1, 1, 1, 0.04)

	-- Colour swatch (left): left-click recolour, right-click clear.
	row.swatch = CreateFrame("Button", nil, row)
	row.swatch:SetSize(16, 16)
	row.swatch:SetPoint("LEFT", row, "LEFT", 6, 0)
	row.swatch.tex = row.swatch:CreateTexture(nil, "ARTWORK")
	row.swatch.tex:SetAllPoints(row.swatch)
	row.swatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row.swatch:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			Org():ClearColor(row.name)
			Manager:Refresh()
		else
			OpenColorPicker(row.name, row.color)
		end
	end)

	row.label = F.CreateFS(row, 13, "", "OVERLAY")
	row.label:SetPoint("LEFT", row.swatch, "RIGHT", 6, 6)
	row.label:SetJustifyH("LEFT")

	row.info = F.CreateFS(row, 10, "", "OVERLAY")
	row.info:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -1)
	row.info:SetJustifyH("LEFT")
	row.info:SetTextColor(0.6, 0.6, 0.6)

	-- Right-to-left action cluster.
	row.up = MakeArrow(row, true)
	row.up:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.up:SetScript("OnClick", function()
		Manager:Move(row.name, -1)
	end)

	row.down = MakeArrow(row, false)
	row.down:SetPoint("RIGHT", row.up, "LEFT", -2, 0)
	row.down:SetScript("OnClick", function()
		Manager:Move(row.name, 1)
	end)

	row.delete = MakeTextButton(row, 24, "X")
	row.delete:SetPoint("RIGHT", row.down, "LEFT", -4, 0)
	row.delete:SetScript("OnClick", function()
		Org():DeleteCategory(row.name, row.kind)
		Manager:Refresh()
	end)

	row.rename = MakeTextButton(row, 58, L["Rename"])
	row.rename:SetPoint("RIGHT", row.delete, "LEFT", -4, 0)
	row.rename:SetScript("OnClick", function()
		StaticPopup_Show("BAGFORGE_RENAME_CATEGORY", nil, nil, { name = row.name, kind = row.kind })
	end)

	-- Search-only controls (hidden for custom rows). Group is wide enough for its
	-- longest caption ("Group: Expansion") so the label stays inside the frame
	-- instead of bleeding into Query (left) and Rename (right).
	row.group = MakeTextButton(row, 104, "")
	row.group:SetPoint("RIGHT", row.rename, "LEFT", -4, 0)
	row.group:SetScript("OnClick", function()
		Manager:CycleGroup(row)
	end)

	row.edit = MakeTextButton(row, 46, L["Query"])
	row.edit:SetPoint("RIGHT", row.group, "LEFT", -4, 0)
	row.edit:SetScript("OnClick", function()
		StaticPopup_Show("BAGFORGE_EDIT_QUERY", nil, nil, { name = row.name, query = row.query })
	end)

	row.enable = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	row.enable:SetSize(22, 22)
	row.enable:SetPoint("RIGHT", row.edit, "LEFT", -2, 0)
	row.enable:SetScript("OnClick", function(self)
		Org():SetSearchEnabled(row.name, self:GetChecked())
		Manager:Refresh()
	end)

	return row
end

-- ---------------------------------------------------------------------------
-- Window construction (lazy)
-- ---------------------------------------------------------------------------
function Manager:Build()
	if self.frame then
		return
	end

	EnsureSettingsTemplate()

	local frame = CreateFrame("Frame", "BagforgeCategoryManager", UIParent, "SettingsFrameTemplate")
	frame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("HIGH")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()

	if frame.NineSlice and frame.NineSlice.Text then
		frame.NineSlice.Text:SetText(L["Category Manager"])
	end
	if frame.ClosePanelButton then
		frame.ClosePanelButton:SetShown(true)
	end

	-- Top action row: saved searches can be created directly from the manager;
	-- custom categories are created by assigning an item from the bag.
	local newBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	newBtn:SetSize(180, 22)
	newBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -32)
	newBtn:SetText(L["New Search Category"])
	newBtn:SetScript("OnClick", function()
		StaticPopup_Show("BAGFORGE_NEW_SEARCH")
	end)

	local exportBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	exportBtn:SetSize(72, 22)
	exportBtn:SetPoint("LEFT", newBtn, "RIGHT", 8, 0)
	exportBtn:SetText(L["Export"])
	exportBtn:SetScript("OnClick", function()
		StaticPopup_Show("BAGFORGE_EXPORT_CATEGORIES")
	end)

	local importBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	importBtn:SetSize(72, 22)
	importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 8, 0)
	importBtn:SetText(L["Import"])
	importBtn:SetScript("OnClick", function()
		StaticPopup_Show("BAGFORGE_IMPORT_CATEGORIES")
	end)

	-- Scroll list.
	local scroll = CreateFrame("ScrollFrame", "BagforgeCategoryManagerScroll", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -60)
	scroll:SetPoint("BOTTOMRIGHT", -30, 44)

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(WINDOW_WIDTH - 44, 10)
	scroll:SetScrollChild(content)
	self.content = content

	-- Parented to the main window (NOT the scroll frame, which clips regions that
	-- aren't its scroll child) and anchored over the scroll area, so an empty
	-- manager always explains itself instead of looking blank.
	self.empty = F.CreateFS(frame, 13, L["No custom or search categories yet."], "OVERLAY")
	self.empty:SetPoint("CENTER", scroll, "CENTER", 0, 12)
	self.empty:SetTextColor(0.7, 0.7, 0.7)

	self.emptyHint = F.CreateFS(frame, 11, L["Assign items to a category from the bag, or add a search category below."], "OVERLAY")
	self.emptyHint:SetPoint("TOP", self.empty, "BOTTOM", 0, -6)
	self.emptyHint:SetWidth(WINDOW_WIDTH - 80)
	self.emptyHint:SetTextColor(0.5, 0.5, 0.5)

	self.empty:Hide()
	self.emptyHint:Hide()

	self.rowPool = F.CreatePool(function()
		return CreateRow(content)
	end)

	self.frame = frame
	tinsert(UISpecialFrames, "BagforgeCategoryManager")
end

-- ---------------------------------------------------------------------------
-- Population
-- ---------------------------------------------------------------------------
function Manager:Refresh()
	if not (self.frame and self.frame:IsShown()) then
		return
	end

	self.rowPool:ReleaseAll()
	local list = Org():GetManagedCategories()
	self.order = {}

	local width = self.content:GetWidth()
	for i = 1, #list do
		local item = list[i]
		self.order[i] = item.name

		local row = self.rowPool:Acquire()
		row:SetWidth(width)
		row:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -(i - 1) * (ROW_HEIGHT + 2))
		row:SetPoint("TOPRIGHT", self.content, "TOPRIGHT", 0, -(i - 1) * (ROW_HEIGHT + 2))

		row.name = item.name
		row.kind = item.kind

		-- Swatch colour (defaults to the panel's normal yellow when unset).
		local o = ns.db.organize
		local color = o.colors and o.colors[item.name]
		row.color = color
		if color then
			row.swatch.tex:SetColorTexture(color[1], color[2], color[3])
		else
			row.swatch.tex:SetColorTexture(1, 0.82, 0)
		end

		if item.kind == "search" then
			local def = item.def or {}
			row.query = def.query or ""
			row.label:SetText(item.name)
			row.info:SetText(format(L["Search: %s"], row.query ~= "" and row.query or L["(empty)"]))

			row.enable:Show()
			row.enable:SetChecked(def.enabled ~= false)
			row.edit:Show()
			row.group:Show()
			local g = def.groupBy or "none"
			row.group:SetText(format(L["Group: %s"], GROUP_LABEL[g] or g))
		else
			row.query = nil
			row.label:SetText(item.name)
			row.info:SetText(format(L["Custom - %d item(s)"], item.count or 0))
			row.enable:Hide()
			row.edit:Hide()
			row.group:Hide()
		end
	end

	local rows = #list
	self.content:SetHeight(math.max(10, rows * (ROW_HEIGHT + 2)))
	self.empty:SetShown(rows == 0)
	self.emptyHint:SetShown(rows == 0)
end

-- Move a category one slot up (-1) or down (+1) by rewriting the managed order.
function Manager:Move(name, dir)
	local order = self.order
	if not order then
		return
	end
	local index
	for i = 1, #order do
		if order[i] == name then
			index = i
			break
		end
	end
	if not index then
		return
	end
	local target = index + dir
	if target < 1 or target > #order then
		return
	end
	order[index], order[target] = order[target], order[index]
	Org():ApplyManagedOrder(order)
	self:Refresh()
end

function Manager:CycleGroup(row)
	local current = "none"
	local o = ns.db.organize
	local def = o.searches and o.searches[row.name]
	if def then
		current = def.groupBy or "none"
	end
	local nextIndex = 1
	for i = 1, #GROUP_CYCLE do
		if GROUP_CYCLE[i] == current then
			nextIndex = (i % #GROUP_CYCLE) + 1
			break
		end
	end
	Org():SetSearchGroupBy(row.name, GROUP_CYCLE[nextIndex])
	self:Refresh()
end

function Manager:Toggle()
	self:Build()
	if self.frame:IsShown() then
		self.frame:Hide()
	else
		self.frame:Show()
		self:Refresh()
	end
end
