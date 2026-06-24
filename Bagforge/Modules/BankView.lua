--[[
	Bagforge - BankView (per-bank-kind categorized window)
	-------------------------------------------------------------------------
	One view instance per bank kind (character / warband). Built on ContainerWindow
	for shared draw/category plumbing; tab flyout and bank-specific chrome live here.
--]]

local _, ns = ...
local C, F, L = ns.C, ns.F, ns.L

local C_Bank = C_Bank
local C_Container = C_Container
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local PlaySound = PlaySound
local UIParent = UIParent
local GameTooltip = GameTooltip
local GameTooltip_Hide = _G["GameTooltip_Hide"]
local BANKSLOTPURCHASE = _G["BANKSLOTPURCHASE"]
local QUESTION_MARK_ICON = _G["QUESTION_MARK_ICON"] or "Interface\\Icons\\INV_Misc_QuestionMark"
local StaticPopup_Show = _G["StaticPopup_Show"]
local StaticPopup_Hide = _G["StaticPopup_Hide"]
local StaticPopup_Visible = _G["StaticPopup_Visible"]
local SetItemButtonTexture = _G["SetItemButtonTexture"]
local GetMoneyString = _G["GetMoneyString"]
local GetMoney = _G["GetMoney"]
local GetCVarBool = _G["GetCVarBool"]
local SetCVar = _G["SetCVar"]
local SmallMoneyFrame_OnLoad = _G["SmallMoneyFrame_OnLoad"]
local MoneyFrame_SetType = _G["MoneyFrame_SetType"]
local MoneyFrame_UpdateMoney = _G["MoneyFrame_UpdateMoney"]
local ACCOUNT_BANK_ERROR_NO_LOCK = _G["ACCOUNT_BANK_ERROR_NO_LOCK"]
local SOUNDKIT = _G["SOUNDKIT"]
local tinsert = table.insert
local wipe = wipe
local max = math.max

local TAB_SLOT_SIZE = 37
local TAB_SLOT_GAP = 6
local TAB_PURCHASE_HEIGHT = 22
local TAB_PURCHASE_GAP = 8

local BANK_TYPE_ACCOUNT = Enum.BankType and Enum.BankType.Account
local MONEY_COIN_BUTTONS = { "GoldButton", "SilverButton", "CopperButton" }

local BankView = {}
ns.BankView = BankView

local View = {}
View.__index = View
ns.ContainerWindow.Apply(View)

local function TabSlot_OnEnter(button)
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	GameTooltip:SetText(button.tabName or L["Bank Tabs"])
	GameTooltip:Show()
end

local function SetIconButtonEnabled(button, enabled)
	if not button then
		return
	end
	button:SetEnabled(enabled)
	button:SetAlpha(enabled and 1 or 0.4)
end

function BankView.New(opts)
	return setmetatable({
		bankType = opts.bankType,
		enabledKey = opts.enabledKey,
		columnsKey = opts.columnsKey,
		frameName = opts.frameName,
		title = opts.title,
		staticBags = opts.staticBags,
		isMember = opts.isMember,
		sortTooltip = opts.sortTooltip,
		depositLabel = opts.depositLabel,
		defaultPoint = opts.defaultPoint,
		defaultRelPoint = opts.defaultRelPoint,
		defaultX = opts.defaultX,
		defaultY = opts.defaultY,
		scanner = ns.Scan.New(),
		bankBags = {},
		categoryContainers = {},
		activeCategories = {},
		freeSlots = 0,
		open = false,
		pendingDraw = false,
	}, View)
end

function View:IsWarband()
	return self.bankType == BANK_TYPE_ACCOUNT
end

function View:GetMoneyFrameType()
	return self:IsWarband() and "ACCOUNT" or "PLAYER"
end

function View:SupportsMoneyTransfer()
	local bankType = self.bankType
	return bankType and C_Bank and C_Bank.DoesBankTypeSupportMoneyTransfer and C_Bank.DoesBankTypeSupportMoneyTransfer(bankType) and true or false
end

function View:GetFooterBottomInset()
	if self.open then
		return C.Layout.WARBAND_FOOTER_HEIGHT
	end
	return 0
end

local function DisableMoneyPickup(money)
	for i = 1, #MONEY_COIN_BUTTONS do
		local button = money[MONEY_COIN_BUTTONS[i]]
		if button then
			button:SetScript("OnClick", nop)
			button:EnableMouse(false)
		end
	end
end

local function DecorateTransferMoneyFrame(view, money, click)
	local highlight = money:CreateTexture(nil, "OVERLAY")
	highlight:SetAtlas("CreditsScreen-Highlight")
	highlight:SetBlendMode("ADD")
	highlight:SetAlpha(0.5)
	highlight:SetPoint("TOPLEFT", money.GoldButton or money, "TOPLEFT", -4, 2)
	highlight:SetPoint("BOTTOMRIGHT", money.CopperButton or money, "BOTTOMRIGHT", 2, -2)
	highlight:Hide()
	money.bfHighlight = highlight

	click:SetScript("OnEnter", function()
		highlight:Show()
		GameTooltip:SetOwner(click, "ANCHOR_RIGHT")
		local title = view:IsWarband() and L["Warband Bank Gold"] or L["Money"]
		GameTooltip_SetTitle(GameTooltip, title, HIGHLIGHT_FONT_COLOR)
		if view.bankMoneyLockTip then
			GameTooltip_AddErrorLine(GameTooltip, view.bankMoneyLockTip)
		elseif view:IsWarband() then
			F.AddClickHintLine(GameTooltip, "left", "%s to withdraw warband gold.")
			F.AddClickHintLine(GameTooltip, "right", "%s to deposit warband gold.")
		else
			F.AddClickHintLine(GameTooltip, "left", "%s to withdraw gold.")
			F.AddClickHintLine(GameTooltip, "right", "%s to deposit gold.")
		end
		GameTooltip:Show()
	end)
	click:SetScript("OnLeave", function()
		highlight:Hide()
		GameTooltip_Hide()
	end)
end

function View:BuildBankFooter()
	if self.bankFooter then
		return
	end

	local frame = self.frame
	local leftX = C.Layout.PANEL_PADDING_X + C.Layout.PANEL_BIAS_X
	local rightX = C.Layout.PANEL_PADDING_X - C.Layout.PANEL_BIAS_X
	local footer = CreateFrame("Frame", nil, frame)
	footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", leftX, C.Layout.WARBAND_FOOTER_OFFSET_Y)
	footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -rightX, C.Layout.WARBAND_FOOTER_OFFSET_Y)
	footer:SetHeight(C.Layout.WARBAND_FOOTER_HEIGHT)
	self.bankFooter = footer

	local moneyRow = CreateFrame("Frame", nil, footer)
	moneyRow:SetHeight(C.Layout.WARBAND_MONEY_ROW_HEIGHT)
	moneyRow:SetPoint("BOTTOMLEFT", footer, "BOTTOMLEFT", 0, 0)
	moneyRow:SetPoint("BOTTOMRIGHT", footer, "BOTTOMRIGHT", 0, 0)

	local money = CreateFrame("Frame", nil, moneyRow, "SmallMoneyFrameTemplate")
	if SmallMoneyFrame_OnLoad then
		SmallMoneyFrame_OnLoad(money)
	end
	money:SetPoint("BOTTOMRIGHT", moneyRow, "BOTTOMRIGHT", 0, 0)
	self.bankMoneyFrame = money

	if self:SupportsMoneyTransfer() then
		DisableMoneyPickup(money)
		local moneyClick = CreateFrame("Button", nil, money)
		moneyClick:SetAllPoints(money)
		moneyClick:SetFrameLevel(money:GetFrameLevel() + 10)
		moneyClick:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		moneyClick:SetScript("OnClick", function(_, mouseButton)
			self:OnBankMoneyClick(mouseButton)
		end)
		DecorateTransferMoneyFrame(self, money, moneyClick)
		self.bankMoneyClick = moneyClick
	else
		F.DecoratePickupMoneyFrame(money, "ANCHOR_RIGHT")
	end

	footer:Hide()
end

function View:EnsureDepositReagentsGlow()
	local button = self.depositButton
	if not button or button.bfReagentsGlow then
		return button and button.bfReagentsGlow
	end
	local glow = button:CreateTexture(nil, "OVERLAY")
	glow:SetAtlas("bags-newitem")
	glow:SetBlendMode("ADD")
	glow:SetPoint("TOPLEFT", button, "TOPLEFT", -2, 2)
	glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
	glow:Hide()
	button.bfReagentsGlow = glow
	return glow
end

function View:GetDepositReagentsEnabled()
	local on = ns.db and ns.db.bank and ns.db.bank.depositReagents
	if on == nil and GetCVarBool then
		on = GetCVarBool("bankAutoDepositReagents")
	end
	return on and true or false
end

function View:ToggleDepositReagents()
	if not self:IsWarband() then
		return
	end
	ns.db.bank.depositReagents = not self:GetDepositReagentsEnabled()
	if SetCVar then
		SetCVar("bankAutoDepositReagents", ns.db.bank.depositReagents and "1" or "0")
	end
	self:UpdateDepositReagentsHighlight()
end

function View:UpdateDepositReagentsHighlight()
	if not self:IsWarband() or not self.depositButton then
		return
	end
	local active = self:GetDepositReagentsEnabled()
	local glow = self:EnsureDepositReagentsGlow()
	if active then
		self.depositButton:LockHighlight()
	else
		self.depositButton:UnlockHighlight()
	end
	if glow then
		glow:SetShown(active)
	end
end

function View:OnBankMoneyClick(mouseButton)
	if InCombatLockdown() or not self:CanUse() or not self.bankType then
		return
	end
	local bankType = self.bankType
	local moneyTransfer = C_Bank and C_Bank.DoesBankTypeSupportMoneyTransfer and C_Bank.DoesBankTypeSupportMoneyTransfer(bankType)
	if not moneyTransfer then
		return
	end
	if mouseButton == "RightButton" then
		if not (C_Bank.CanDepositMoney and C_Bank.CanDepositMoney(bankType)) then
			return
		end
		self:OnDepositMoneyClick()
	else
		if not (C_Bank.CanWithdrawMoney and C_Bank.CanWithdrawMoney(bankType)) then
			return
		end
		self:OnWithdrawMoneyClick()
	end
end

function View:OnWithdrawMoneyClick()
	if InCombatLockdown() or not self.bankType then
		return
	end
	if PlaySound and SOUNDKIT then
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION)
	end
	if StaticPopup_Hide then
		StaticPopup_Hide("BANK_MONEY_DEPOSIT")
	end
	if StaticPopup_Visible and StaticPopup_Visible("BANK_MONEY_WITHDRAW") then
		StaticPopup_Hide("BANK_MONEY_WITHDRAW")
		return
	end
	if StaticPopup_Show then
		StaticPopup_Show("BANK_MONEY_WITHDRAW", nil, nil, { bankType = self.bankType })
	end
end

function View:OnDepositMoneyClick()
	if InCombatLockdown() or not self.bankType then
		return
	end
	if PlaySound and SOUNDKIT then
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION)
	end
	if StaticPopup_Hide then
		StaticPopup_Hide("BANK_MONEY_WITHDRAW")
	end
	if StaticPopup_Visible and StaticPopup_Visible("BANK_MONEY_DEPOSIT") then
		StaticPopup_Hide("BANK_MONEY_DEPOSIT")
		return
	end
	if StaticPopup_Show then
		StaticPopup_Show("BANK_MONEY_DEPOSIT", nil, nil, { bankType = self.bankType })
	end
end

function View:CanUpdateBankMoney()
	if InCombatLockdown() then
		return false
	end
	if GetMoney and F.IsSecret(GetMoney()) then
		return false
	end
	return true
end

function View:UpdateBankFooter()
	self:BuildBankFooter()
	local footer = self.bankFooter
	if not footer then
		return
	end

	local shown = self.open and true or false
	footer:SetShown(shown)
	if not shown then
		return
	end

	local canUse = self:CanUse()
	local bankType = self.bankType
	local moneyTransfer = self:SupportsMoneyTransfer()
	local locked = bankType and C_Bank and C_Bank.FetchBankLockedReason and C_Bank.FetchBankLockedReason(bankType) ~= nil
	self.bankMoneyLockTip = locked and ACCOUNT_BANK_ERROR_NO_LOCK or nil

	local canWithdraw = moneyTransfer and C_Bank.CanWithdrawMoney and C_Bank.CanWithdrawMoney(bankType)
	local canDeposit = moneyTransfer and C_Bank.CanDepositMoney and C_Bank.CanDepositMoney(bankType)
	local click = self.bankMoneyClick
	if click then
		local moneyVisible = self.bankMoneyFrame and self.bankMoneyFrame:IsShown()
		click:SetShown(moneyTransfer and moneyVisible and true or false)
		click:SetEnabled(canUse and (canWithdraw or canDeposit) and true or false)
	end

	local money = self.bankMoneyFrame
	if money and MoneyFrame_UpdateMoney then
		if self:CanUpdateBankMoney() then
			self.bankMoneyPending = false
			money:Show()
			if MoneyFrame_SetType then
				MoneyFrame_SetType(money, self:GetMoneyFrameType())
			end
			MoneyFrame_UpdateMoney(money)
		else
			self.bankMoneyPending = true
			money:Hide()
		end
	end
end

function View:CanShow()
	if self.bankType == (Enum.BankType and Enum.BankType.Account) then
		if not Enum.BankType or not Enum.BankType.Account then
			return false
		end
		if C_Bank and C_Bank.CanViewBank then
			return C_Bank.CanViewBank(Enum.BankType.Account) and true or false
		end
		return false
	end
	return true
end

function View:CanUse()
	if self.bankType and C_Bank and C_Bank.CanUseBank then
		return C_Bank.CanUseBank(self.bankType) and true or false
	end
	return true
end

function View:SupportsAutoDeposit()
	if self.bankType and C_Bank and C_Bank.DoesBankTypeSupportAutoDeposit then
		return C_Bank.DoesBankTypeSupportAutoDeposit(self.bankType) and true or false
	end
	return true
end

function View:GetBankBags()
	if C_Bank and C_Bank.FetchPurchasedBankTabIDs and self.bankType then
		local tabs = C_Bank.FetchPurchasedBankTabIDs(self.bankType)
		if tabs and #tabs > 0 then
			wipe(self.bankBags)
			for i = 1, #tabs do
				local bag = tabs[i]
				if self.isMember[bag] then
					self.bankBags[#self.bankBags + 1] = bag
				end
			end
			return self.bankBags
		end
	end
	return self.staticBags
end

-- Run() calls this when the build is ready (immediately, and again once any late
-- item data has loaded). Cached per view so we don't allocate a closure per draw.
function View:GetScanCallback()
	if not self._onScan then
		self._onScan = function(scanner)
			if not self.open then
				return
			end
			self.sections = scanner.sections
			self.freeSlots = scanner.freeSlots
			self:DrawLayout()
		end
	end
	return self._onScan
end

function View:SavedPosition()
	return ns.db.bank.windowPos
end

function View:BuildWindow()
	self:InitCategoryContainers()
	self.mainContainer = ns.Container.New(UIParent, self.frameName, true)
	ns.Container.AddFreeSlot(self.mainContainer)
	self.mainContainer:SetFreeSlotDeposit(function()
		return self:GetBankBags()
	end)
	local frame = self.mainContainer:GetFrame()
	self.frame = frame

	self:ApplyFrameChrome(frame)
	self:SetupDragPersistence(frame, function(pos)
		ns.db.bank.windowPos = pos
	end)
	if frame.ClosePanelButton then
		local close = frame.ClosePanelButton
		local view = self
		close:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		close:SetScript("OnClick", function(_, mouseButton)
			if mouseButton == "RightButton" then
				local bank = ns:GetModule("Bank")
				if bank then
					bank:ResetPosition()
				end
			else
				view:Close()
			end
		end)
		close:SetScript("OnEnter", function(btn)
			GameTooltip:SetOwner(btn, "ANCHOR_TOP")
			GameTooltip_SetTitle(GameTooltip, CLOSE or view.title, HIGHLIGHT_FONT_COLOR)
			F.AddClickHintLine(GameTooltip, "left", "%s to close bank.")
			F.AddClickHintLine(GameTooltip, "right", "%s to reset the window position.")
			GameTooltip:Show()
		end)
		close:SetScript("OnLeave", GameTooltip_Hide)
	end
	self:BuildChrome()
	self:BuildBankFooter()
	self:ApplySavedPosition(self:SavedPosition(), self.defaultPoint, self.defaultRelPoint, self.defaultX, self.defaultY)

	tinsert(UISpecialFrames, self.frameName)
end

function View:BuildChrome()
	local frame = self.frame
	local leftX, rightX, rowY, btnW, btnGap = self:GetChromeInsets()

	local sort = F.CreateIconButton(frame, btnW, btnW, 655994)
	sort:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -rightX, rowY)
	sort:SetScript("OnClick", function()
		self:Sort()
	end)
	sort:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip:SetText(self.sortTooltip or L["Sort Bank"])
		GameTooltip:Show()
	end)
	sort:SetScript("OnLeave", GameTooltip_Hide)
	self.sortButton = sort

	local deposit = F.CreateIconButton(frame, btnW, btnW, 450905)
	deposit:SetPoint("RIGHT", sort, "LEFT", -btnGap, 0)
	local view = self
	deposit:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	deposit:SetScript("OnClick", function(_, mouseButton)
		if view:IsWarband() and mouseButton == "RightButton" then
			view:ToggleDepositReagents()
			return
		end
		view:DepositAll()
	end)
	deposit:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip_SetTitle(GameTooltip, view.depositLabel or L["Deposit All"], HIGHLIGHT_FONT_COLOR)
		if view:IsWarband() then
			F.AddClickHintLine(GameTooltip, "left", "%s to deposit all warbound items.")
			F.AddClickHintLine(GameTooltip, "right", "%s to toggle including tradeable reagents.")
			if view:GetDepositReagentsEnabled() then
				GameTooltip_AddNormalLine(GameTooltip, L["Include tradeable reagents is on."], 0, 1, 0)
			end
		end
		GameTooltip:Show()
	end)
	deposit:SetScript("OnLeave", GameTooltip_Hide)
	self.depositButton = deposit
	self:EnsureDepositReagentsGlow()

	local tabToggle = F.CreateIconButton(frame, btnW, btnW, "Interface\\Buttons\\Button-Backpack-Up", "Interface\\Buttons\\Button-Backpack-Down")
	tabToggle:SetPoint("RIGHT", deposit, "LEFT", -btnGap, 0)
	tabToggle:SetScript("OnClick", function()
		local bank = ns:GetModule("Bank")
		if bank then
			bank:ToggleTabBar()
		end
	end)
	tabToggle:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip:SetText(L["Bank Tabs"])
		GameTooltip:Show()
	end)
	tabToggle:SetScript("OnLeave", GameTooltip_Hide)
	self.tabToggleButton = tabToggle

	self.search = self:CreateSearchBox(3)

	local Bank = ns:GetModule("Bank")
	local strip = ns.Tabs.Create(frame)
	strip:SetClickHandler(function(enabledKey)
		if Bank then
			local target = Bank:GetView(enabledKey)
			if target and target ~= Bank:OpenView() then
				Bank:ShowView(target)
			end
		end
	end)
	if Bank and Bank.views then
		for i = 1, #Bank.views do
			local v = Bank.views[i]
			strip:AddTab(v.enabledKey, v.title)
		end
	end
	strip:SetShown(false)
	self.tabStrip = strip

	self:BuildTabBar()
end

function View:BuildTabBar()
	if self.tabBar then
		return
	end

	local frame = self.frame
	local panel = ns.Container.New(frame)
	local bar = panel:GetFrame()
	local accountType = Enum.BankType and Enum.BankType.Account
	panel.header:SetText(self.bankType == accountType and L["Warband Bank Tabs"] or L["Bank Tabs"])
	panel.header:Show()
	self.tabBarPanel = panel
	self.tabBar = bar
	self.tabSlots = {}

	local size, gap = TAB_SLOT_SIZE, TAB_SLOT_GAP
	local leftX = C.Layout.PANEL_PADDING_X + C.Layout.PANEL_BIAS_X
	local topInset = C.Layout.PANEL_PADDING + C.Layout.PANEL_HEADER_HEIGHT

	local bags = self.staticBags
	local n = #bags
	for i = 1, n do
		local button = self:CreateTabSlotButton(bar, i)
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", bar, "TOPLEFT", leftX + (i - 1) * (size + gap), -topInset)
		self.tabSlots[i] = button
	end

	local rowWidth = n * size + (n - 1) * gap
	local purchase = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
	purchase:SetText(BANKSLOTPURCHASE or L["Purchase"])
	purchase:SetSize(max(96, (purchase:GetTextWidth() or 60) + 24), TAB_PURCHASE_HEIGHT)
	purchase:SetPoint("TOP", bar, "TOPLEFT", leftX + rowWidth / 2, -(topInset + size + TAB_PURCHASE_GAP))
	purchase:SetScript("OnClick", function()
		self:PurchaseTab()
	end)
	purchase:SetScript("OnEnter", function(btn)
		local tabData = self.bankType and C_Bank and C_Bank.FetchNextPurchasableBankTabData and C_Bank.FetchNextPurchasableBankTabData(self.bankType)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip:SetText(BANKSLOTPURCHASE or L["Purchase"])
		if tabData and GetMoneyString and tabData.tabCost and F.NotSecret(tabData.tabCost) then
			GameTooltip:AddLine(GetMoneyString(tabData.tabCost, true), 1, 1, 1)
		end
		GameTooltip:Show()
	end)
	purchase:SetScript("OnLeave", GameTooltip_Hide)
	self.purchaseButton = purchase

	local width = C.Layout.PANEL_PADDING_X * 2 + n * size + (n - 1) * gap
	bar:SetWidth(width)
	self:ResizeTabBar(true)
	self:AnchorTabBar()

	bar:SetShown(ns.db.bank.showTabBar)
	self:UpdateTabBar()
end

function View:AnchorTabBar()
	if not self.tabBar then
		return
	end
	self.tabBar:ClearAllPoints()
	self.tabBar:SetPoint("TOPRIGHT", self.frame, "BOTTOMRIGHT", 0, -C.Layout.PANEL_GAP)
end

function View:CreateTabSlotButton(parent, index)
	local name = self.frameName .. "TabSlot" .. index
	local button = CreateFrame("ItemButton", name, parent)
	button:SetSize(TAB_SLOT_SIZE, TAB_SLOT_SIZE)
	button.tabIndex = index
	button.icon = _G[name .. "IconTexture"]
	button:SetScript("OnEnter", TabSlot_OnEnter)
	button:SetScript("OnLeave", GameTooltip_Hide)
	return button
end

function View:UpdateTabBar()
	if not self.tabSlots then
		return
	end
	if self.tabBar and not self.tabBar:IsShown() then
		return
	end

	local bankType = self.bankType
	local purchased
	if bankType and C_Bank and C_Bank.FetchPurchasedBankTabData then
		purchased = C_Bank.FetchPurchasedBankTabData(bankType)
	end

	for i = 1, #self.tabSlots do
		local button = self.tabSlots[i]
		local data = purchased and purchased[i]
		if data then
			SetItemButtonTexture(button, data.icon or QUESTION_MARK_ICON)
			button.tabName = data.name
		else
			SetItemButtonTexture(button, QUESTION_MARK_ICON)
			button.tabName = nil
		end
	end

	local purchase = self.purchaseButton
	if purchase then
		local hasMax = bankType and C_Bank and C_Bank.HasMaxBankTabs and C_Bank.HasMaxBankTabs(bankType)
		if hasMax then
			purchase:Hide()
		else
			purchase:Show()
			local canBuy = bankType and C_Bank and C_Bank.CanPurchaseBankTab and C_Bank.CanPurchaseBankTab(bankType)
			purchase:SetEnabled(canBuy and true or false)
		end
		self:ResizeTabBar(purchase:IsShown())
	end
end

function View:ResizeTabBar(withPurchase)
	local bar = self.tabBar
	if not bar then
		return
	end
	local height = C.Layout.PANEL_PADDING * 2 + C.Layout.PANEL_HEADER_HEIGHT + TAB_SLOT_SIZE
	if withPurchase then
		height = height + TAB_PURCHASE_GAP + TAB_PURCHASE_HEIGHT
	end
	bar:SetHeight(height)
end

function View:ApplyTabBarState()
	if self.tabBar then
		self:AnchorTabBar()
		self.tabBar:SetShown(ns.db.bank.showTabBar)
		self:UpdateTabBar()
	end
end

function View:PurchaseTab()
	if not self.bankType or InCombatLockdown() then
		return
	end
	if C_Bank and C_Bank.CanPurchaseBankTab and not C_Bank.CanPurchaseBankTab(self.bankType) then
		return
	end
	if PlaySound and SOUNDKIT then
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION)
	end
	if StaticPopup_Show then
		StaticPopup_Show("CONFIRM_BUY_BANK_TAB", nil, nil, { bankType = self.bankType })
	end
end

function View:UpdateChrome()
	local canUse = self.open and self:CanUse()
	SetIconButtonEnabled(self.sortButton, canUse)
	SetIconButtonEnabled(self.depositButton, canUse and self:SupportsAutoDeposit())
	self:UpdateDepositReagentsHighlight()
	self:UpdateBankFooter()
end

function View:Draw()
	if not self.frame or not self.open then
		return
	end

	-- Scan, then render in the callback: Run() fires immediately and again once
	-- any late item data has loaded, so the bank refines in place (no polling).
	self.scanner:Run(self:GetBankBags(), self:GetScanCallback())
end

function View:DrawLayout()
	if not self.frame or not self.open then
		return
	end

	local categories = ns:GetModule("Categories")
	local cols = ns.db.bank[self.columnsKey] or ns.db.bank.columns or 14
	local mainCategory = categories and categories:GetMainCategory() or L["Other"]
	local mainSection = self:FindMainSection(self.sections, mainCategory, categories)

	self:DrawCategorized({
		requireOpen = true,
		sections = self.sections,
		mainName = mainCategory,
		mainTitle = self.title,
		mainSection = mainSection,
		columns = cols,
		perColumn = ns.db.bank.categoriesPerColumn,
		mainLayoutOpts = {
			topInset = C.Layout.MAIN_CHROME_TOP,
			bottomInset = self:GetFooterBottomInset(),
			freeCount = self.freeSlots,
		},
	})
end

function View:Open()
	if not self.frame then
		return
	end
	self.open = true
	self.frame:Show()
	self:UpdateChrome()
	self:ApplyTabBarState()
	self:UpdateBankFooter()
	self:Draw()
end

function View:Close()
	self.open = false
	self:UpdateChrome()
	if self.frame then
		self.frame:Hide()
	end
	if self.categoryContainers then
		for _, container in pairs(self.categoryContainers) do
			container:Reset()
		end
	end
end

function View:RefreshIfOpen()
	if self.open then
		self:UpdateTabBar()
		self:UpdateBankFooter()
		self:Draw()
	end
end

--- Incremental search-filter refresh: a search keystroke only flips isFiltered on
--- the items already scanned, so re-read those flags in place and relayout
--- (sections/free count are unchanged) instead of a full scanner:Run(). The
--- per-section signature folds in isFiltered, so only the panels that actually
--- gained/lost a match repaint.
function View:RefreshFiltered()
	if not self.open or not self.scanner then
		return
	end
	if self.scanner:RefreshFiltered() then
		self:DrawLayout()
	end
end

function View:DepositAll()
	if InCombatLockdown() then
		F.Print(L["Can't deposit bank items during combat."])
		return
	end
	if not self:CanUse() or not self:SupportsAutoDeposit() then
		return
	end
	if C_Bank and C_Bank.AutoDepositItemsIntoBank and self.bankType then
		if PlaySound and SOUNDKIT then
			PlaySound(SOUNDKIT.IG_MAINMENU_OPTION)
		end
		C_Bank.AutoDepositItemsIntoBank(self.bankType)
	end
end

function View:Sort()
	if InCombatLockdown() then
		F.Print(L["Can't sort bank during combat."])
		return
	end
	if not self:CanUse() then
		return
	end
	if C_Container.SortBank and self.bankType then
		if PlaySound and SOUNDKIT then
			PlaySound(SOUNDKIT.UI_BAG_SORTING_01)
		end
		C_Container.SortBank(self.bankType)
	end
end

BankView.View = View
