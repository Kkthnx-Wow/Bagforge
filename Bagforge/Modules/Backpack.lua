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
local ipairs = ipairs
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
local InCombatLockdown = InCombatLockdown
local GetMoney = GetMoney
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
local MoneyFrame_UpdateMoney = _G["MoneyFrame_UpdateMoney"]

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
		columns = 12,
		showBagBar = false,
		categoriesPerColumn = C.Layout.DEFAULT_CATEGORIES_PER_COLUMN,
		flashFind = true,
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

	local bagToggle = F.CreateIconButton(frame, btnW, btnW, "hud-backpack")
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
	local deleteCheapest = F.CreateIconButton(frame, btnW, btnW, [[Interface\ICONS\achievement_Goblinheaddead]])
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

	-- Reserve room on the search row for all six chrome buttons; the
	-- delete-cheapest button may then hide itself (reclaiming its slot) when
	-- the feature is toggled off.
	self.search = self:CreateSearchBox(6)
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

-- Show/hide the delete-cheapest chrome button to match its setting, reclaiming
-- the search-box width for the sixth button slot when it is turned off.
function Backpack:UpdateDeleteCheapestButton()
	local btn = self.deleteCheapestButton
	if not btn then
		return
	end
	local db = ns.db and ns.db.deleteCheapest
	local enabled = db and db.enable
	btn:SetShown(enabled and true or false)
	self:SetSearchReserve(enabled and 6 or 5)
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
	if InCombatLockdown() then
		return false
	end
	if GetMoney and F.IsSecret(GetMoney()) then
		return false
	end
	return true
end

function Backpack:UpdateMoneyFrame()
	local money = self.moneyFrame
	if not money or not MoneyFrame_UpdateMoney then
		return
	end
	if not self:CanUpdateMoneyFrame() then
		self.moneyPending = true
		money:Hide()
		return
	end
	self.moneyPending = false
	money:Show()
	MoneyFrame_UpdateMoney(money)
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

function Backpack:Draw()
	if not self.frame then
		return
	end

	local items = ns:GetModule("Items")
	local categories = ns:GetModule("Categories")
	if not (items and categories) then
		return
	end

	local sections = items:GetSections()
	local cols = ns.db.backpack.columns or C.Layout.COLUMNS
	local gridW = ns.Container.GridWidth(cols)
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
		perColumn = ns.db.backpack.categoriesPerColumn,
		freeSlots = freeSlots,
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

function Backpack:Open()
	if not self.frame then
		return
	end
	self.frame:Show()
	-- Match Blizzard's ContainerFrame open/close sounds (IG_BACKPACK_*).
	if SOUNDKIT then
		PlaySound(SOUNDKIT.IG_BACKPACK_OPEN)
	end
	local items = ns:GetModule("Items")
	if items and items._scanDirty then
		items:Scan()
	end
	self:UpdateMoneyFrame()
	self:ApplyBagBarState()
	self:Draw()
end

function Backpack:Close()
	if self.frame then
		-- Only chime if we were actually open, so a redundant Close() stays silent.
		local wasShown = self.frame:IsShown()
		self.frame:Hide()
		if wasShown and SOUNDKIT then
			PlaySound(SOUNDKIT.IG_BACKPACK_CLOSE)
		end
	end
	if self.categoryContainers then
		for _, container in pairs(self.categoryContainers) do
			container:Reset()
		end
	end
end

function Backpack:Toggle()
	if self.frame and self.frame:IsShown() then
		self:Close()
	else
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

function Backpack:OnSettingChanged()
	if self.frame then
		self:ApplyBagBarState()
		self:Draw()
	end
end

function Backpack:RegisterOptions(category, builder)
	builder:Slider(category, self, "columns", ns.L["Columns"], ns.L["How many item columns each bag panel is wide."], C.Layout.MIN_COLUMNS, C.Layout.MAX_COLUMNS, 1)
	builder:Checkbox(category, self, "showBagBar", ns.L["Bag Bar"], ns.L["Toggle the equipped-bag slots."])
	builder:Checkbox(category, self, "flashFind", ns.L["Flash Find"], ns.L["Alt-click an item to highlight every matching stack in your open bags and bank."])
	builder:Slider(category, self, "categoriesPerColumn", ns.L["Categories Per Column"], ns.L["How many category panels stack in a column before wrapping to a new column on the left."], C.Layout.MIN_CATEGORIES_PER_COLUMN, C.Layout.MAX_CATEGORIES_PER_COLUMN, 1)
end

function Backpack:OnEnable()
	self:BuildWindow()
	self:SuppressBlizzardBags()

	local toggleButton = CreateFrame("Button", "BagforgeToggleButton", UIParent)
	toggleButton:RegisterForClicks("AnyUp")
	toggleButton:SetScript("OnClick", function()
		Backpack:Toggle()
	end)
	self.toggleButton = toggleButton

	self.bindingFrame = CreateFrame("Frame")
	self.bindingFrame:SetScript("OnEvent", function(f)
		f:UnregisterEvent("PLAYER_REGEN_ENABLED")
		Backpack:SetupKeybinds()
	end)
	self:SetupKeybinds()

	local queueDraw = F.DebounceNoArgs(0.05, function()
		if Backpack:IsShown() then
			Backpack:Draw()
		end
	end)
	ns:RegisterCallback("Items.Updated", queueDraw)

	ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
		if Backpack.pendingDraw and Backpack:IsShown() then
			Backpack:Draw()
		end
		if Backpack.moneyPending and Backpack:IsShown() then
			Backpack:UpdateMoneyFrame()
		end
	end)

	ns:RegisterEvent("PLAYER_MONEY", function()
		if Backpack:IsShown() then
			Backpack:UpdateMoneyFrame()
		end
	end)

	ns:RegisterEvent("CURRENCY_DISPLAY_UPDATE", queueDraw)

	local refreshBagBar = F.DebounceNoArgs(0.05, function()
		if Backpack:IsShown() then
			Backpack:UpdateBagBar()
		end
	end)
	ns:RegisterEvent("BAG_UPDATE", refreshBagBar)
	ns:RegisterEvent("ITEM_LOCK_CHANGED", refreshBagBar)
	ns:RegisterEvent("BAG_CONTAINER_UPDATE", refreshBagBar)

	ns:RegisterEvent("UPDATE_BINDINGS", function()
		Backpack:SetupKeybinds()
	end)
end
