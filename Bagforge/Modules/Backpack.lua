--[[
	Bagforge - Backpack (the window)
	-------------------------------------------------------------------------
	cargBags/NDui layout: the main "Bag" panel is the draggable root frame;
	category panels stack upward in a masonry flow. Shared chrome/draw plumbing
	lives in ContainerWindow; bag-bar and Blizzard suppression are mixed in from
	BagBar and BlizzardBags.
--]]

local _, ns = ...
local C, F, L = ns.C, ns.F, ns.L

local CreateFrame = CreateFrame
local C_AddOns = C_AddOns
local C_CurrencyInfo = C_CurrencyInfo
local C_Container = C_Container
local pairs = pairs
local wipe = wipe
local tonumber = tonumber
local floor = math.floor
local pcall = pcall
local tinsert = table.insert
local max = math.max
local min = math.min
local format = string.format

local PlaySound = PlaySound
local GameTooltip = GameTooltip
local UIParent = UIParent
local IsAltKeyDown = IsAltKeyDown
local IsControlKeyDown = IsControlKeyDown
local StaticPopup_Show = StaticPopup_Show
local SOUNDKIT = _G["SOUNDKIT"]
local GameTooltip_SetTitle = _G["GameTooltip_SetTitle"]
local GameTooltip_AddNormalLine = _G["GameTooltip_AddNormalLine"]
local GameTooltip_Hide = _G["GameTooltip_Hide"]
local HIGHLIGHT_FONT_COLOR = _G["HIGHLIGHT_FONT_COLOR"]
local BAG_CLEANUP_BAGS = _G["BAG_CLEANUP_BAGS"]
local BAG_CLEANUP_BAGS_DESCRIPTION = _G["BAG_CLEANUP_BAGS_DESCRIPTION"]
local CLOSE = _G["CLOSE"]
local UnitName = UnitName
local MoneyFrame_SetType = _G["MoneyFrame_SetType"]

local BagIndex = Enum.BagIndex
local TOKEN_UI = "Blizzard_TokenUI"
local REAGENT_BAG_BAGS = BagIndex.ReagentBag and { BagIndex.ReagentBag } or nil

-- Currency cluster spacing (see currencies:UpdateTokenAnchoring). ICON_INSET is
-- the count->icon gap; token height matches SmallMoneyFrameTemplate (13px).
local CURRENCY_TOKEN_HEIGHT = 13
local CURRENCY_TOKEN_FONT_DELTA = 1
local CURRENCY_TOKEN_ICON_INSET = 9
local CURRENCY_TOKEN_GAP = 18
local CURRENCY_BAR_PAD_LEFT = 0
local CURRENCY_BAR_PAD_RIGHT = 0

-- Character-create arrow textures (same family KkthnxUI-style toolbar toggle).
local TEXTURE_TOOLBAR_EXPAND = "Interface\\BUTTONS\\UI-SpellbookIcon-NextPage-Up"
local TEXTURE_TOOLBAR_EXPAND_DOWN = "Interface\\BUTTONS\\UI-SpellbookIcon-NextPage-Down"
local TEXTURE_TOOLBAR_COLLAPSE = "Interface\\BUTTONS\\UI-SpellbookIcon-PrevPage-Up"
local TEXTURE_TOOLBAR_COLLAPSE_DOWN = "Interface\\BUTTONS\\UI-SpellbookIcon-PrevPage-Down"
local TOOLBAR_TOGGLE_SIZE = 30

local function SetToolbarToggleArt(btn, expanded)
	local normal = expanded and TEXTURE_TOOLBAR_COLLAPSE or TEXTURE_TOOLBAR_EXPAND
	local pushed = expanded and TEXTURE_TOOLBAR_COLLAPSE_DOWN or TEXTURE_TOOLBAR_EXPAND_DOWN
	if btn.SetNormalTexture then
		btn:SetNormalTexture(normal)
		btn:SetPushedTexture(pushed)
	end
end

-- Tokens are pooled: each draw re-acquires the same frames, so never bump font
-- size relative to GetFont() or it grows without bound across redraws.
local currencyCountFont

local function GetCurrencyCountFont()
	if currencyCountFont then
		return currencyCountFont
	end
	local ref = _G.GameFontHighlightSmall
	if not ref then
		return
	end
	local font, size, flags = ref:GetFont()
	if not (font and size) then
		return
	end
	currencyCountFont = { font, size + CURRENCY_TOKEN_FONT_DELTA, flags }
	return currencyCountFont
end

ns:RegisterDefaults({
	backpack = {
		columns = C.Layout.COLUMNS,
		iconSize = C.Layout.ITEM_SIZE,
		showBagBar = false,
		categoriesPerColumn = C.Layout.BACKPACK_CATEGORIES_PER_COLUMN,
		flashFind = true,
		showJunkPrice = true,
		toolbarExpanded = false,
		-- Auto-open matrix (Baganator OpenClose.lua + PLAYER_INTERACTION_MANAGER).
		openOnTrade = false,
		openOnMerchant = false,
		openOnMail = false,
		openOnAuction = false,
		openOnScrapping = false,
		specialBagColors = true,
	},
})

local Backpack = ns:NewModule("Backpack", "backpack")
Backpack.title = ns.L["Backpack"]
Backpack.order = 10
Backpack.group = "general"

ns.ContainerWindow.Apply(Backpack)
ns.BagBar.Apply(Backpack)
ns.BlizzardBags.Apply(Backpack)

local function EnsureTokenTemplate()
	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.LoadAddOn and not C_AddOns.IsAddOnLoaded(TOKEN_UI) then
		pcall(C_AddOns.LoadAddOn, TOKEN_UI)
	end
	return _G["BackpackTokenFrameMixin"] ~= nil
end

function Backpack:BuildChrome()
	local frame = self.frame
	local leftX, rightX, rowY, btnW, btnGap = self:GetChromeInsets()

	local close = frame.ClosePanelButton or CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	close:SetScript("OnClick", function(_, mouseButton)
		if mouseButton == "RightButton" then
			Backpack:ResetPosition()
		else
			Backpack:Close()
		end
	end)
	close:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip_SetTitle(GameTooltip, CLOSE or L["Backpack"], HIGHLIGHT_FONT_COLOR)
		F.AddClickHintLine(GameTooltip, "left", "%s to close bags.")
		F.AddClickHintLine(GameTooltip, "right", "%s to reset the window position.")
		GameTooltip:Show()
	end)
	close:SetScript("OnLeave", GameTooltip_Hide)
	self.closeButton = close

	local sort = F.CreateIconButton(frame, btnW, btnW, 655994)
	sort:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -rightX, rowY)
	sort:SetScript("OnClick", function()
		if ns:IsBagSortActive() then
			return
		end
		PlaySound(SOUNDKIT.UI_BAG_SORTING_01)
		local items = ns:GetModule("Items")
		if items then
			items:Sort()
		end
	end)
	sort:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip_SetTitle(GameTooltip, BAG_CLEANUP_BAGS, HIGHLIGHT_FONT_COLOR)
		GameTooltip_AddNormalLine(GameTooltip, BAG_CLEANUP_BAGS_DESCRIPTION)
		GameTooltip:Show()
	end)
	sort:SetScript("OnLeave", GameTooltip_Hide)
	self.sortButton = sort

	local function UpdateSortButton()
		local btn = Backpack.sortButton
		if not btn then
			return
		end
		local enabled = not ns:IsBagSortActive()
		btn:SetEnabled(enabled)
		btn:SetAlpha(enabled and 1 or 0.4)
	end
	Backpack.UpdateSortButton = UpdateSortButton

	local bagToggle = F.CreateIconButton(frame, btnW, btnW, 133633)
	bagToggle:SetPoint("RIGHT", sort, "LEFT", -btnGap, 0)
	bagToggle:SetScript("OnClick", function()
		Backpack:ToggleBagBar()
	end)
	bagToggle:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip_SetTitle(GameTooltip, ns.L["Bag Bar"], HIGHLIGHT_FONT_COLOR)
		GameTooltip_AddNormalLine(GameTooltip, ns.L["Toggle the equipped-bag slots."])
		GameTooltip:Show()
	end)
	bagToggle:SetScript("OnLeave", GameTooltip_Hide)
	self.bagToggleButton = bagToggle

	-- Custom-category assign mode (NDui's Favourite-mode button): arm it, then
	-- left-click items to pick their category. Uses the favorites star atlas; the
	-- locked highlight is the "armed" cue.
	local assign = F.CreateIconButton(frame, btnW, btnW, "Interface\\AddOns\\Bagforge\\assets\\FavoritesIcon")
	assign:SetPoint("RIGHT", bagToggle, "LEFT", -btnGap, 0)
	assign:SetScript("OnClick", function(btn)
		local organize = ns:GetModule("Organize")
		if organize then
			organize:ToggleMode("assign")
		end
	end)
	assign:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip_SetTitle(GameTooltip, ns.L["Assign Categories"], HIGHLIGHT_FONT_COLOR)
		GameTooltip_AddNormalLine(GameTooltip, ns.L["Arm, then left-click items to set their custom category."])
		GameTooltip:Show()
	end)
	assign:SetScript("OnLeave", GameTooltip_Hide)
	assign:SetScript("OnHide", function(btn)
		local organize = ns:GetModule("Organize")
		if organize then
			organize:SetMode(nil)
		else
			btn:UnlockHighlight()
		end
	end)
	self.assignButton = assign

	-- Custom-junk mode (NDui's CustomJunkMode button): arm it, then left-click
	-- items to flag them as junk (grouped + auto-sold). Alt+Ctrl wipes the list.
	-- "bags-junkcoin" is the same coin atlas the in-bag junk overlay uses, so the
	-- button and the marks it produces read as one feature. (Atlas, not a path:
	-- F.CreateIconButton routes plain names through SetNormalAtlas.)
	local junk = F.CreateIconButton(frame, btnW, btnW, "SpellIcon-256x256-SellJunk")
	junk:SetPoint("RIGHT", assign, "LEFT", -btnGap, 0)
	junk:SetScript("OnClick", function(btn)
		local organize = ns:GetModule("Organize")
		if not organize then
			return
		end
		if IsAltKeyDown() and IsControlKeyDown() then
			if StaticPopup_Show then
				StaticPopup_Show("BAGFORGE_WIPE_JUNK")
			end
			return
		end
		organize:ToggleMode("junk")
	end)
	junk:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip_SetTitle(GameTooltip, ns.L["Mark Junk"], HIGHLIGHT_FONT_COLOR)
		GameTooltip_AddNormalLine(GameTooltip, ns.L["Arm, then left-click items to mark them as junk."])
		GameTooltip_AddNormalLine(GameTooltip, ns.L["Alt+Ctrl click to wipe the junk list."])
		GameTooltip:Show()
	end)
	junk:SetScript("OnLeave", GameTooltip_Hide)
	junk:SetScript("OnHide", function(btn)
		local organize = ns:GetModule("Organize")
		if organize then
			organize:SetMode(nil)
		else
			btn:UnlockHighlight()
		end
	end)
	self.junkButton = junk

	-- Delete mode mirrors NDui/cargBags: arm it, then Ctrl+Alt left-click a
	-- non-rare item to destroy it without Blizzard's delete confirmation box.
	local delete = F.CreateIconButton(frame, btnW, btnW, "Interface\\AddOns\\Bagforge\\assets\\DeleteModeIcon")
	delete:SetPoint("RIGHT", junk, "LEFT", -btnGap, 0)
	delete:SetScript("OnClick", function()
		local organize = ns:GetModule("Organize")
		if organize then
			organize:ToggleMode("delete")
		end
	end)
	delete:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip_SetTitle(GameTooltip, ns.L["Delete Items"], HIGHLIGHT_FONT_COLOR)
		-- Colour "Rare" with the rare-quality blue (#0070dd) so the safety
		-- threshold stands out in the hint.
		local rareWord = "|cff0070dd" .. ns.L["Rare"] .. "|r"
		GameTooltip_AddNormalLine(GameTooltip, string.format(ns.L["Arm, then Ctrl+Alt left-click items below %s quality to delete them."], rareWord))
		GameTooltip:Show()
	end)
	delete:SetScript("OnLeave", GameTooltip_Hide)
	delete:SetScript("OnHide", function(btn)
		local organize = ns:GetModule("Organize")
		if organize then
			organize:SetMode(nil)
		else
			btn:UnlockHighlight()
		end
	end)
	self.deleteButton = delete

	-- One-shot "delete cheapest" action (NexEnhance's goblin-head button): find
	-- and (after a confirm showing the item) destroy the lowest vendor-value
	-- item in the bags. Left-click prompts; right-click previews in chat. The
	-- scan, confirm dialog and protection filters live in the DeleteCheapest
	-- module; this is just the chrome icon. The dead-goblin-head icon reads as
	-- "purge the hoard"; trim the icon ring so it sits like the other flat
	-- chrome icons.
	local deleteCheapest = F.CreateIconButton(frame, btnW, btnW, 901746)
	deleteCheapest:SetPoint("RIGHT", delete, "LEFT", -btnGap, 0)
	deleteCheapest:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	deleteCheapest:SetScript("OnClick", function(_, mouseButton)
		local mod = ns:GetModule("DeleteCheapest")
		if not mod then
			return
		end
		if mouseButton == "RightButton" then
			mod:Report()
		else
			mod:Prompt()
		end
	end)
	deleteCheapest:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip_SetTitle(GameTooltip, ns.L["Delete Cheapest Item"], HIGHLIGHT_FONT_COLOR)
		F.AddClickHintLine(GameTooltip, "left", "%s to destroy the cheapest sellable item in your bags.")
		F.AddClickHintLine(GameTooltip, "right", "%s to show the cheapest item without deleting it.")
		GameTooltip:Show()
	end)
	deleteCheapest:SetScript("OnLeave", GameTooltip_Hide)
	self.deleteCheapestButton = deleteCheapest

	local organize = ns:GetModule("Organize")
	if organize then
		organize:RegisterModeButton("assign", assign)
		organize:RegisterModeButton("junk", junk)
		organize:RegisterModeButton("delete", delete)
	end

	self.toolbarExtraButtons = { assign, junk, delete, deleteCheapest }

	local toggle = F.CreateIconButton(frame, TOOLBAR_TOGGLE_SIZE, TOOLBAR_TOGGLE_SIZE, TEXTURE_TOOLBAR_EXPAND, TEXTURE_TOOLBAR_EXPAND_DOWN)
	F.SetIconButtonHighlightSize(toggle, btnW)
	toggle:SetPoint("RIGHT", bagToggle, "LEFT", -btnGap, 0)
	toggle:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		if Backpack.toolbarExpanded then
			GameTooltip_SetTitle(GameTooltip, L["Collapse Toolbar"], HIGHLIGHT_FONT_COLOR)
			GameTooltip_AddNormalLine(GameTooltip, L["Hide extra bag actions."])
		else
			GameTooltip_SetTitle(GameTooltip, L["Expand Toolbar"], HIGHLIGHT_FONT_COLOR)
			GameTooltip_AddNormalLine(GameTooltip, L["Show assign, junk, delete, and more."])
		end
		GameTooltip:Show()
	end)
	toggle:SetScript("OnLeave", GameTooltip_Hide)
	toggle:SetScript("OnClick", function()
		local db = ns.db and ns.db.backpack
		Backpack.toolbarExpanded = not Backpack.toolbarExpanded
		if db then
			db.toolbarExpanded = Backpack.toolbarExpanded
		end
		Backpack:UpdateToolbarChrome()
	end)
	self.toolbarToggleButton = toggle

	-- Search width follows visible chrome buttons (collapse hides extras).
	self.search = self:CreateSearchBox(3)
	self:UpdateToolbarChrome()
	self:UpdateDeleteCheapestButton()

	local money = CreateFrame("Frame", "BagforgeMoneyFrame", frame, "SmallMoneyFrameTemplate")
	money:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -rightX, C.Layout.FOOTER_OFFSET_Y)
	if MoneyFrame_SetType then
		MoneyFrame_SetType(money, "PLAYER")
	end
	self.moneyFrame = money
	self:DecorateMoneyFrame(money)

	if EnsureTokenTemplate() then
		local currencies = CreateFrame("Frame", nil, frame, "BackpackTokenFrameTemplate")
		currencies:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", leftX, C.Layout.CURRENCY_FOOTER_OFFSET_Y)
		if currencies.Border then
			currencies.Border:Hide()
		end
		currencies:Hide()
		-- Content-width chain left-to-right along the footer baseline (matches money).
		function currencies:UpdateTokenAnchoring()
			local n = self.numWatchedTokens or 0
			local prev
			for i = 1, n do
				local token = self.Tokens and self.Tokens[i]
				if token then
					local textWidth = token.Count and token.Count:GetStringWidth() or 0
					token:SetWidth(textWidth + CURRENCY_TOKEN_ICON_INSET)
					token:ClearAllPoints()
					if not prev then
						token:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", CURRENCY_BAR_PAD_LEFT, 0)
					else
						token:SetPoint("BOTTOMLEFT", prev, "BOTTOMRIGHT", CURRENCY_TOKEN_GAP, 0)
					end
					prev = token
				end
			end
		end
		self.currencyBar = currencies
	end

	self:BuildBagBar()
end

--- The backpack's item icon size (per-view; falls back to the shared default).
function Backpack:GetIconSize()
	return (ns.db and ns.db.backpack and ns.db.backpack.iconSize) or C.Layout.ITEM_SIZE
end

--- How many icon buttons sit on the search row (sort + bag + toggle + optional extras).
function Backpack:GetToolbarButtonCount()
	local count = 3
	if self.toolbarExpanded then
		count = count + 3
		local cheapest = self.deleteCheapestButton
		if cheapest and cheapest:IsShown() then
			count = count + 1
		end
	end
	return count
end

function Backpack:UpdateToolbarChrome()
	local db = ns.db and ns.db.backpack
	self.toolbarExpanded = db and db.toolbarExpanded == true

	local _, _, _, _, btnGap = self:GetChromeInsets()
	local expanded = self.toolbarExpanded
	local extras = self.toolbarExtraButtons
	if extras then
		for i = 1, #extras do
			local btn = extras[i]
			if btn == self.deleteCheapestButton then
				local enabled = ns.db and ns.db.deleteCheapest and ns.db.deleteCheapest.enable
				btn:SetShown(expanded and enabled and true or false)
			else
				btn:SetShown(expanded and true or false)
			end
		end
	end

	local toggle = self.toolbarToggleButton
	if toggle then
		SetToolbarToggleArt(toggle, expanded)
		toggle:ClearAllPoints()
		if expanded then
			local anchor = self.deleteCheapestButton
			if not (anchor and anchor:IsShown()) then
				anchor = self.deleteButton
			end
			toggle:SetPoint("RIGHT", anchor, "LEFT", -btnGap, 0)
		else
			toggle:SetPoint("RIGHT", self.bagToggleButton, "LEFT", -btnGap, 0)
		end
		toggle:Show()
	end

	if self.search then
		local _, _, _, btnW = self:GetChromeInsets()
		self:SetSearchReserve(self:GetToolbarButtonCount(), TOOLBAR_TOGGLE_SIZE - btnW)
	end
end

-- Show/hide the delete-cheapest chrome button to match its setting, reclaiming
-- the search-box width for the sixth button slot when it is turned off.
function Backpack:UpdateDeleteCheapestButton()
	if not self.deleteCheapestButton then
		return
	end
	self:UpdateToolbarChrome()
end

-- SmallMoneyFrame coin buttons already support pick-up; F.DecoratePickupMoneyFrame
-- adds the hover glow and tooltip (see Functions.lua).
function Backpack:DecorateMoneyFrame(money)
	F.DecoratePickupMoneyFrame(money, "ANCHOR_LEFT")
end

function Backpack:ApplyCurrencyTokenStyle(bar)
	bar:SetHeight(CURRENCY_TOKEN_HEIGHT)
	local tokens = bar.Tokens
	if not tokens then
		return
	end
	for i = 1, bar.numWatchedTokens or 0 do
		local token = tokens[i]
		if token then
			token:SetHeight(CURRENCY_TOKEN_HEIGHT)
			local count = token.Count
			if count then
				local spec = GetCurrencyCountFont()
				if spec then
					count:SetFont(spec[1], spec[2], spec[3])
				end
				count:SetHeight(CURRENCY_TOKEN_HEIGHT)
			end
			local icon = token.Icon
			if icon then
				icon:SetSize(CURRENCY_TOKEN_HEIGHT, CURRENCY_TOKEN_HEIGHT)
				icon:ClearAllPoints()
				icon:SetPoint("RIGHT", token, "RIGHT", 4, 0)
			end
		end
	end
end

function Backpack:UpdateCurrencyBar(gridWidth)
	local bar = self.currencyBar
	if not (bar and C_CurrencyInfo and C_CurrencyInfo.GetBackpackCurrencyInfo and bar.Update) then
		return false
	end

	-- CURRENCY_DISPLAY_UPDATE fires this with no width; recompute it from the
	-- column count (the same source Draw uses) so we never do arithmetic on nil.
	gridWidth = gridWidth or ns.Container.GridWidth(ns.db.backpack.columns or C.Layout.COLUMNS, self:GetIconSize())

	local leftX = C.Layout.PANEL_PADDING_X + C.Layout.PANEL_BIAS_X
	local rightX = C.Layout.PANEL_PADDING_X - C.Layout.PANEL_BIAS_X
	local footerGap = C.Layout.FOOTER_GAP

	bar:ClearAllPoints()
	bar:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", leftX, C.Layout.CURRENCY_FOOTER_OFFSET_Y)

	local moneyW = 0
	if self.moneyFrame then
		moneyW = self.moneyFrame:GetWidth() or 0
		if moneyW < 1 then
			moneyW = 140
		end
	end
	local maxWidth = gridWidth - leftX - rightX - moneyW - footerGap
	if maxWidth < 1 then
		maxWidth = 1
	end

	-- Wide enough for Blizzard's token layout pass; reclamped to content after.
	bar:SetWidth(maxWidth)
	bar:Update()
	if bar.Border then
		bar.Border:Hide()
	end
	self:ApplyCurrencyTokenStyle(bar)

	local num = bar.GetNumWatchedTokens and bar:GetNumWatchedTokens() or 0
	if num > 0 then
		local contentWidth = CURRENCY_BAR_PAD_LEFT + CURRENCY_BAR_PAD_RIGHT
		for i = 1, num do
			local token = bar.Tokens and bar.Tokens[i]
			if token then
				contentWidth = contentWidth + (token:GetWidth() or 0)
				if i > 1 then
					contentWidth = contentWidth + CURRENCY_TOKEN_GAP
				end
			end
		end
		bar:SetWidth(min(contentWidth, maxWidth))
		if bar.UpdateTokenAnchoring then
			bar:UpdateTokenAnchoring()
		end
	end

	bar:SetShown(num > 0)
	return num > 0
end

function Backpack:CanUpdateMoneyFrame()
	return F.CanUpdatePlayerMoney()
end

function Backpack:UpdateMoneyFrame()
	local money = self.moneyFrame
	if not money then
		return
	end
	if F.UpdatePlayerMoneyFrame(money) then
		self.moneyPending = false
	else
		self.moneyPending = true
	end
end

function Backpack:LayoutFooter(gridWidth)
	if not self.frame then
		return false
	end

	local rightX = C.Layout.PANEL_PADDING_X - C.Layout.PANEL_BIAS_X
	if self.moneyFrame then
		self.moneyFrame:ClearAllPoints()
		self.moneyFrame:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -rightX, C.Layout.FOOTER_OFFSET_Y)
		self:UpdateMoneyFrame()
	end

	return self:UpdateCurrencyBar(gridWidth)
end

function Backpack:BuildWindow()
	-- Re-enable must not spawn a second main frame / UISpecialFrames entry.
	if self.frame then
		return
	end
	self:InitCategoryContainers()
	self.mainContainer = ns.Container.NewMain(UIParent)
	self.mainContainer:SetFreeSlotDeposit(function()
		return C.BACKPACK_BAGS
	end)
	local frame = self.mainContainer:GetFrame()
	self.frame = frame

	self:ApplyFrameChrome(frame)
	self:SetupDragPersistence(frame, function(pos)
		ns.db.backpack.position = pos
	end)
	self:BuildChrome()
	self:ApplySavedPosition(ns.db.backpack.position)

	tinsert(UISpecialFrames, "BagforgeBackpackFrame")
end

function Backpack:GetMainTitle()
	local name = C.Player.name
	if not name or name == "Unknown" then
		name = UnitName("player") or ""
	end
	return format(L["%s Bags"], name)
end

function Backpack:RefreshCategoryHeaders()
	if not self:IsShown() then
		return
	end
	local items = ns:GetModule("Items")
	local categories = ns:GetModule("Categories")
	if not (items and categories and items.scanner) then
		return
	end
	local changeset = items.scanner.lastChangeset
	if not changeset then
		return
	end
	local sections = items:GetSections()
	local drawSections = sections
	if REAGENT_BAG_BAGS and categories.HasReagentBag and categories:HasReagentBag() then
		drawSections = select(1, self:BuildReagentDraw(sections, categories))
	end
	ns.ContainerWindow.RefreshCategoryHeaders(self, {
		changeset = changeset,
		sections = drawSections,
		drawSections = drawSections,
		mainName = categories:GetMainCategory(),
		mainTitle = self:GetMainTitle(),
	})
end

function Backpack:Draw(changeset)
	if not self.frame then
		return
	end

	local items = ns:GetModule("Items")
	local categories = ns:GetModule("Categories")
	if not (items and categories) then
		return
	end

	if not changeset and items.scanner then
		changeset = items.scanner.lastChangeset
	end

	local sections = items:GetSections()
	local cols = ns.db.backpack.columns or C.Layout.COLUMNS
	local gridW = ns.Container.GridWidth(cols, self:GetIconSize())
	self:LayoutFooter(gridW)
	local bottomInset = C.Layout.MAIN_CHROME_BOTTOM

	local drawSections, freeSlots = sections, nil
	local mainFree = items:GetFreeSlots()
	if REAGENT_BAG_BAGS and categories.HasReagentBag and categories:HasReagentBag() then
		drawSections, freeSlots = self:BuildReagentDraw(sections, categories)
		local reagentFree = freeSlots[categories:GetReagentBagCategory()].count
		mainFree = max(mainFree - reagentFree, 0)
	end

	local mainCategory = categories:GetMainCategory()
	local mainSection = items.scanner and items.scanner.sectionsByName and items.scanner.sectionsByName[mainCategory]
	if not mainSection then
		mainSection = self:FindMainSection(sections, mainCategory, categories)
	end

	self:DrawCategorized({
		sections = drawSections,
		drawSections = drawSections,
		mainName = mainCategory,
		mainSection = mainSection,
		mainTitle = self:GetMainTitle(),
		columns = cols,
		gridWidth = gridW,
		perColumn = ns.db.backpack.categoriesPerColumn or C.Layout.BACKPACK_CATEGORIES_PER_COLUMN,
		freeSlots = freeSlots,
		layoutBatchSize = C.Layout.BACKPACK_LAYOUT_BATCH,
		mainLayoutOpts = {
			showMainTitle = true,
			topInset = C.Layout.MAIN_CHROME_TOP,
			bottomInset = bottomInset,
			freeCount = mainFree,
		},
		afterLayout = function()
			local bank = ns:GetModule("Bank")
			if bank and bank.IsBankOpen and bank:IsBankOpen() then
				bank:RefreshItemContext()
			end
		end,
		changeset = changeset,
	})
end

function Backpack:BuildReagentDraw(sections, categories)
	local reagentCat = categories:GetReagentBagCategory()

	local items = ns:GetModule("Items")
	local hasReagentSection = false
	if items and items.scanner and items.scanner.sectionsByName then
		hasReagentSection = items.scanner.sectionsByName[reagentCat] ~= nil
	else
		for s = 1, #sections do
			if sections[s].name == reagentCat then
				hasReagentSection = true
				break
			end
		end
	end

	local drawSections = self._drawSections or {}
	self._drawSections = drawSections
	wipe(drawSections)
	if hasReagentSection then
		for s = 1, #sections do
			drawSections[#drawSections + 1] = sections[s]
		end
	else
		local empty = self._reagentEmptySection or { items = {} }
		empty.name = reagentCat
		empty.order = categories:GetOrder(reagentCat)
		self._reagentEmptySection = empty
		local inserted = false
		for s = 1, #sections do
			if not inserted and (sections[s].order or 100) > empty.order then
				drawSections[#drawSections + 1] = empty
				inserted = true
			end
			drawSections[#drawSections + 1] = sections[s]
		end
		if not inserted then
			drawSections[#drawSections + 1] = empty
		end
	end

	local info = self._reagentFreeInfo
	if not info then
		info = {
			getBags = function()
				return REAGENT_BAG_BAGS
			end,
		}
		self._reagentFreeInfo = info
	end
	info.count = C_Container.GetContainerNumFreeSlots(BagIndex.ReagentBag) or 0

	local freeSlots = self._reagentFreeMap or {}
	self._reagentFreeMap = freeSlots
	wipe(freeSlots)
	freeSlots[reagentCat] = info

	return drawSections, freeSlots
end

function Backpack:Open(fromAuto)
	if not self.frame then
		return
	end
	-- Manual open (keybind / bag button) clears autoOpened so interaction HIDE
	-- won't close bags the player opened on purpose (Baganator OpenClose.lua).
	if not fromAuto then
		self._autoOpened = false
	end
	-- Shell size before Show so combat (CheckCombatDraw) never leaves a 0x0 window.
	self:EnsureShellSize(ns.db.backpack.columns or C.Layout.COLUMNS)
	self.frame:Show()
	-- Match Blizzard's ContainerFrame open/close sounds (IG_BACKPACK_*).
	if SOUNDKIT then
		PlaySound(SOUNDKIT.IG_BACKPACK_OPEN)
	end
	local items = ns:GetModule("Items")
	-- Fresh login: bags often open while `_scanDirty` (updates while closed) or
	-- before the first model build. Scan() is sync; Draw() must run here — not
	-- wait on debounced Items.Updated (that left a 0x0 frame with only sound).
	-- Empty bags still have `_hasScanned`; do not treat #slots==0 as "never scanned".
	local needScan = items and (items._scanDirty or not items._hasScanned)
	if needScan then
		items:Scan()
	elseif items and items.scanner and items.scanner.RefreshFiltered then
		-- Search may have changed while closed; sync isFiltered before paint.
		items.scanner:RefreshFiltered()
	end
	self:UpdateMoneyFrame()
	self:ApplyBagBarState()
	self:Draw()
end

function Backpack:Close()
	self._autoOpened = false
	if self.frame then
		-- Only chime if we were actually open, so a redundant Close() stays silent.
		local wasShown = self.frame:IsShown()
		self.frame:Hide()
		if wasShown and SOUNDKIT then
			PlaySound(SOUNDKIT.IG_BACKPACK_CLOSE)
		end
	end
	local itemButton = ns:GetModule("ItemButton")
	if itemButton and itemButton.ClearBagHighlight then
		itemButton:ClearBagHighlight()
	end
	if self.categoryContainers then
		for _, container in pairs(self.categoryContainers) do
			container:Reset()
		end
	end
	if self.mainContainer and self.mainContainer.AbortLayout then
		self.mainContainer:AbortLayout()
	end
end

function Backpack:Toggle()
	if self.frame and self.frame:IsShown() then
		self:Close()
	else
		self._autoOpened = false
		self:Open()
	end
end

function Backpack:IsShown()
	return self.frame and self.frame:IsShown()
end

function Backpack:ResetPosition()
	if not self.frame then
		return
	end
	ns.db.backpack.position = nil
	self:ApplySavedPosition(nil)
	self:Draw()
end

function Backpack:SetColumns(columns)
	columns = tonumber(columns)
	if not columns then
		return false
	end
	columns = floor(columns)

	if columns < C.Layout.MIN_COLUMNS then
		columns = C.Layout.MIN_COLUMNS
	elseif columns > C.Layout.MAX_COLUMNS then
		columns = C.Layout.MAX_COLUMNS
	end

	ns.db.backpack.columns = columns
	self:Draw()
	return columns
end

function Backpack:OnSettingChanged(key)
	if key == "showJunkPrice" then
		ns:UIRefresh({ headers = true, zone = ns.C.RefreshZone.backpack })
		return
	end
	if key == "columns" or key == "categoriesPerColumn" or key == "iconSize" then
		if self:IsShown() then
			ns:UIRefresh({ layout = true, zone = ns.C.RefreshZone.backpack })
		end
		return
	end
	-- Chrome-only toggles: bag bar, auto-open matrix, etc.
	if key == "specialBagColors" or key == "openOnTrade" or key == "openOnMerchant" or key == "openOnMail" or key == "openOnAuction" or key == "openOnScrapping" or key == "flashFind" then
		if self:IsShown() then
			ns:UIRefresh({ chrome = true, zone = ns.C.RefreshZone.backpack })
		end
		return
	end
	if self:IsShown() then
		ns:UIRefresh({ layout = true, zone = ns.C.RefreshZone.backpack })
	end
end

function Backpack:RegisterOptions(category, builder)
	builder:Slider(category, self, "columns", ns.L["Columns"], ns.L["How many item columns each bag panel is wide."], C.Layout.MIN_COLUMNS, C.Layout.MAX_COLUMNS, 1)
	builder:Slider(category, self, "iconSize", ns.L["Icon Size"], ns.L["Width and height of each item button, in pixels. The window resizes to fit."], C.Layout.MIN_ICON_SIZE, C.Layout.MAX_ICON_SIZE, 1)
	-- No "Bag Bar" checkbox here: the bag window's own bag-icon button toggles it
	-- (ToggleBagBar), so a settings duplicate was redundant and popped the window
	-- on change. showBagBar still persists; the in-bag toggle drives it.
	builder:Checkbox(category, self, "specialBagColors", ns.L["Specialty Bag Colors"], ns.L["Tint equipped specialty bag slots on the bag bar."])
	builder:Header(ns.L["Auto-Open Bags"])
	builder:Checkbox(category, self, "openOnTrade", ns.L["Open on Trade"], ns.L["Open your bags when a trade window appears."])
	builder:Checkbox(category, self, "openOnMerchant", ns.L["Open on Merchant"], ns.L["Open your bags when talking to a vendor."])
	builder:Checkbox(category, self, "openOnMail", ns.L["Open on Mail"], ns.L["Open your bags at a mailbox."])
	builder:Checkbox(category, self, "openOnAuction", ns.L["Open on Auction House"], ns.L["Open your bags at the auction house."])
	builder:Checkbox(category, self, "openOnScrapping", ns.L["Open on Scrapping"], ns.L["Open your bags at a scrapping machine."])
	builder:Checkbox(category, self, "flashFind", ns.L["Flash Find"], ns.L["Alt-click an item to highlight every matching stack in your open bags and bank."])
	builder:Checkbox(category, self, "showJunkPrice", ns.L["Show Junk Total Price"], ns.L["Display the total gold value of all items inside the Junk category header."])
	builder:Slider(category, self, "categoriesPerColumn", ns.L["Categories Per Column"], ns.L["How many category panels stack in a column before wrapping to a new column on the left."], C.Layout.MIN_CATEGORIES_PER_COLUMN, C.Layout.MAX_CATEGORIES_PER_COLUMN, 1)
end

function Backpack:OnEnable()
	if self._hooksInstalled then
		return
	end
	self._hooksInstalled = true
	self._eventHandles = self._eventHandles or {}
	local handles = self._eventHandles

	self:BuildWindow()
	self:SuppressBlizzardBags()

	if not self.toggleButton then
		local toggleButton = CreateFrame("Button", "BagforgeToggleButton", UIParent)
		toggleButton:RegisterForClicks("AnyUp")
		toggleButton:SetScript("OnClick", function()
			Backpack:Toggle()
		end)
		self.toggleButton = toggleButton
	end

	if not self.bindingFrame then
		self.bindingFrame = CreateFrame("Frame")
		self.bindingFrame:SetScript("OnEvent", function(f)
			f:UnregisterEvent("PLAYER_REGEN_ENABLED")
			Backpack:SetupKeybinds()
		end)
	end
	self:SetupKeybinds()

	local pendingChangeset
	local queueDraw = F.DebounceNoArgs(0.05, function()
		if Backpack:IsShown() then
			Backpack:Draw(pendingChangeset)
			pendingChangeset = nil
		end
	end)
	ns:RegisterCallback("Items.Updated", function(_, changeset)
		pendingChangeset = changeset
		queueDraw()
	end, Backpack)

	ns:RegisterCallback("Sort.StateChanged", function()
		if Backpack.UpdateSortButton then
			Backpack:UpdateSortButton()
		end
	end, Backpack)

	ns:TrackEvent(handles, "PLAYER_REGEN_ENABLED", function()
		if Backpack.pendingDraw and Backpack:IsShown() then
			Backpack:Draw()
		end
		if Backpack.moneyPending and Backpack:IsShown() then
			Backpack:UpdateMoneyFrame()
		end
	end)

	ns:TrackEvent(handles, "PLAYER_MONEY", function()
		if Backpack:IsShown() then
			Backpack:UpdateMoneyFrame()
		end
	end)

	ns:TrackEvent(handles, "CURRENCY_DISPLAY_UPDATE", function()
		if Backpack:IsShown() then
			Backpack:UpdateCurrencyBar()
		end
	end)

	local refreshBagBar = F.DebounceNoArgs(0.05, function()
		if Backpack:IsShown() then
			Backpack:UpdateBagBar()
		end
	end)
	ns:TrackEvent(handles, "BAG_UPDATE", refreshBagBar)
	ns:TrackEvent(handles, "ITEM_LOCK_CHANGED", refreshBagBar)
	ns:TrackEvent(handles, "BAG_CONTAINER_UPDATE", refreshBagBar)

	ns:TrackEvent(handles, "UPDATE_BINDINGS", function()
		Backpack:SetupKeybinds()
	end)

	-- Baganator OpenClose.lua: open on SHOW; close on HIDE only if we auto-opened
	-- (manual open stays open when the merchant/mail/etc. window closes).
	local IT = Enum.PlayerInteractionType
	local openOnByType = {
		[IT.TradePartner] = "openOnTrade",
		[IT.Merchant] = "openOnMerchant",
		[IT.MailInfo] = "openOnMail",
		[IT.Auctioneer] = "openOnAuction",
		[IT.ScrappingMachine] = "openOnScrapping",
	}
	local function InteractionOptionEnabled(interactionType)
		local key = openOnByType[interactionType]
		if not key then
			return false
		end
		local db = ns.db and ns.db.backpack
		return db and db[key] and true or false
	end
	ns:TrackEvent(handles, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, interactionType)
		if not InteractionOptionEnabled(interactionType) then
			return
		end
		-- Already open from a keybind — don't claim ownership.
		if Backpack:IsShown() and not Backpack._autoOpened then
			return
		end
		if not Backpack:IsShown() then
			Backpack._autoOpened = true
			Backpack:Open(true)
		else
			Backpack._autoOpened = true
		end
	end)
	ns:TrackEvent(handles, "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, interactionType)
		if not InteractionOptionEnabled(interactionType) then
			return
		end
		if Backpack._autoOpened then
			Backpack:Close()
		end
	end)
end

function Backpack:OnDisable()
	if not self._hooksInstalled then
		return
	end
	self._hooksInstalled = false
	ns:UnregisterModuleEventHandles(self._eventHandles)
	ns:UnregisterCallback("Items.Updated", Backpack)
	ns:UnregisterCallback("Sort.StateChanged", Backpack)
	if self.Close then
		self:Close()
	end
	if self.RestoreBlizzardBags then
		self:RestoreBlizzardBags()
	end
end
