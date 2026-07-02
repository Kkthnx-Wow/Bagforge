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
local TAB_SELECTED_COLOR = { 0.35, 0.75, 1 }

local BANK_TYPE_ACCOUNT = Enum.BankType and Enum.BankType.Account
local BANK_TYPE_CHARACTER = Enum.BankType and Enum.BankType.Character
local MONEY_COIN_BUTTONS = { "GoldButton", "SilverButton", "CopperButton" }
local BANK_TAB_TOOLTIP_CLICK_INSTRUCTION = _G["BANK_TAB_TOOLTIP_CLICK_INSTRUCTION"]
local GREEN_FONT_COLOR = _G["GREEN_FONT_COLOR"]

local BankView = {}
ns.BankView = BankView

local View = {}
View.__index = View
ns.ContainerWindow.Apply(View)

local function TabSlot_OnEnter(button)
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	GameTooltip:SetText(button.tabName or L["Bank Tabs"])

	-- Add deposit assignments if they exist
	local FlagsUtil = _G["FlagsUtil"]
	local ContainerFrameUtil_ConvertFilterFlagsToList = _G["ContainerFrameUtil_ConvertFilterFlagsToList"]
	local GameTooltip_AddNormalLine = _G["GameTooltip_AddNormalLine"]
	local BANK_TAB_EXPANSION_ASSIGNMENT = _G["BANK_TAB_EXPANSION_ASSIGNMENT"]
	local BANK_TAB_EXPANSION_FILTER_CURRENT = _G["BANK_TAB_EXPANSION_FILTER_CURRENT"]
	local BANK_TAB_EXPANSION_FILTER_LEGACY = _G["BANK_TAB_EXPANSION_FILTER_LEGACY"]
	local BANK_TAB_DEPOSIT_ASSIGNMENTS = _G["BANK_TAB_DEPOSIT_ASSIGNMENTS"]
	if button.depositFlags then
		if FlagsUtil and FlagsUtil.IsSet then
			if FlagsUtil.IsSet(button.depositFlags, Enum.BagSlotFlags.ExpansionCurrent) then
				if GameTooltip_AddNormalLine and BANK_TAB_EXPANSION_ASSIGNMENT and BANK_TAB_EXPANSION_FILTER_CURRENT then
					GameTooltip_AddNormalLine(GameTooltip, BANK_TAB_EXPANSION_ASSIGNMENT:format(BANK_TAB_EXPANSION_FILTER_CURRENT))
				end
			elseif FlagsUtil.IsSet(button.depositFlags, Enum.BagSlotFlags.ExpansionLegacy) then
				if GameTooltip_AddNormalLine and BANK_TAB_EXPANSION_ASSIGNMENT and BANK_TAB_EXPANSION_FILTER_LEGACY then
					GameTooltip_AddNormalLine(GameTooltip, BANK_TAB_EXPANSION_ASSIGNMENT:format(BANK_TAB_EXPANSION_FILTER_LEGACY))
				end
			end
		end

		if ContainerFrameUtil_ConvertFilterFlagsToList then
			local filterList = ContainerFrameUtil_ConvertFilterFlagsToList(button.depositFlags)
			if filterList and GameTooltip_AddNormalLine and BANK_TAB_DEPOSIT_ASSIGNMENTS then
				GameTooltip_AddNormalLine(GameTooltip, BANK_TAB_DEPOSIT_ASSIGNMENTS:format(filterList), true)
			end
		end
	end

	if button.view and button.view.depositTargetBag == button.bagID then
		GameTooltip:AddLine(L["Deposit tab selected"], 0.35, 0.75, 1)
	else
		GameTooltip:AddLine(L["Left-click to choose deposit tab"], 0.7, 0.7, 0.7)
	end

	if button.tabName and BANK_TAB_TOOLTIP_CLICK_INSTRUCTION then
		local r, g, b = 0, 1, 0
		if GREEN_FONT_COLOR then
			r, g, b = GREEN_FONT_COLOR.r, GREEN_FONT_COLOR.g, GREEN_FONT_COLOR.b
		end
		GameTooltip:AddLine(BANK_TAB_TOOLTIP_CLICK_INSTRUCTION, r, g, b)
	end

	GameTooltip:Show()

	if button.bagID then
		local ItemButton = ns:GetModule("ItemButton")
		if ItemButton and ItemButton.SetBagHighlight then
			ItemButton:SetBagHighlight(button.bagID, true)
		end
	end
end

local function TabSlot_OnClick(button, mouseButton)
	if mouseButton == "LeftButton" then
		local view = button.view
		if view and view.tabSettingsMenu and view.tabSettingsMenu:IsShown() then
			view.tabSettingsMenu:Hide()
		end
		if view and button.bagID and button.tabPurchased and view.SetDepositTargetBag then
			view:SetDepositTargetBag(button.bagID)
		end
		return
	end
	if mouseButton == "RightButton" then
		local view = button.view
		if view and button.bagID and button.tabName and view.OpenTabSettings then
			view:OpenTabSettings(button, button.bagID)
		end
	end
end

local function TabSlot_OnLeave(button)
	GameTooltip_Hide()

	if button.bagID then
		local ItemButton = ns:GetModule("ItemButton")
		if ItemButton and ItemButton.SetBagHighlight then
			ItemButton:SetBagHighlight(button.bagID, false)
		end
	end
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
		depositTargetBag = nil,
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

local function WireMoneyTransferDebug(view, button, action)
	if not button or button.bfMoneyDebugHooked then
		return
	end
	button.bfMoneyDebugHooked = true
	button:HookScript("PreClick", function()
		F.DebugBankMoney(view, "pre-" .. action)
	end)
	button:HookScript("PostClick", function()
		F.DebugBankMoney(view, "post-" .. action)
	end)
end

local function ShowMoneyTransferTooltip(view, owner)
	local money = view.bankMoneyFrame
	local highlight = money and money.bfHighlight
	if highlight then
		highlight:Show()
	end
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
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
end

local function HideMoneyTransferTooltip(view)
	local money = view.bankMoneyFrame
	if money and money.bfHighlight then
		money.bfHighlight:Hide()
	end
	GameTooltip_Hide()
end

local function InstallMoneyTransferTooltips(view, clickFrame)
	if not clickFrame or clickFrame.bfTransferTooltip then
		return
	end
	clickFrame.bfTransferTooltip = true
	clickFrame:HookScript("OnEnter", function()
		ShowMoneyTransferTooltip(view, clickFrame)
	end)
	clickFrame:HookScript("OnLeave", function()
		HideMoneyTransferTooltip(view)
	end)
end

local function EnsureMoneyTransferHighlight(money)
	if money.bfHighlight then
		return money.bfHighlight
	end
	local highlight = money:CreateTexture(nil, "OVERLAY")
	highlight:SetAtlas("CreditsScreen-Highlight")
	highlight:SetBlendMode("ADD")
	highlight:SetAlpha(0.5)
	highlight:SetPoint("TOPLEFT", money.GoldButton or money, "TOPLEFT", -4, 2)
	highlight:SetPoint("BOTTOMRIGHT", money.CopperButton or money, "BOTTOMRIGHT", 2, -2)
	highlight:Hide()
	money.bfHighlight = highlight
	return highlight
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
		EnsureMoneyTransferHighlight(money)

		-- Deposit below withdraw: both cover the money row, but only withdraw
		-- registers left-clicks. A higher deposit layer used to swallow left-clicks.
		local depositClick = CreateFrame("Button", nil, money, "InsecureActionButtonTemplate")
		depositClick:SetAllPoints(money)
		depositClick:SetFrameLevel(money:GetFrameLevel() + 10)
		depositClick:RegisterForClicks("RightButtonUp")
		if depositClick.SetPropagateMouseClicks then
			depositClick:SetPropagateMouseClicks(true)
		end

		local withdrawClick = CreateFrame("Button", nil, money, "InsecureActionButtonTemplate")
		withdrawClick:SetAllPoints(money)
		withdrawClick:SetFrameLevel(money:GetFrameLevel() + 11)
		withdrawClick:RegisterForClicks("LeftButtonUp")

		InstallMoneyTransferTooltips(self, withdrawClick)
		WireMoneyTransferDebug(self, withdrawClick, "withdraw")
		WireMoneyTransferDebug(self, depositClick, "deposit")
		self.bankMoneyWithdrawClick = withdrawClick
		self.bankMoneyDepositClick = depositClick
		self:ConfigureMoneyButtons()
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
	local withdrawClick = self.bankMoneyWithdrawClick
	local depositClick = self.bankMoneyDepositClick
	local moneyVisible = self.bankMoneyFrame and self.bankMoneyFrame:IsShown()
	local moneyActive = moneyTransfer and moneyVisible and true or false
	if withdrawClick then
		withdrawClick:SetShown(moneyActive)
		withdrawClick:SetEnabled(canUse and canWithdraw and true or false)
	end
	if depositClick then
		depositClick:SetShown(moneyActive)
		depositClick:SetEnabled(canUse and canDeposit and true or false)
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
			if self:SupportsMoneyTransfer() and not (InCombatLockdown and InCombatLockdown()) then
				self:ConfigureMoneyButtons()
			end
		else
			self.bankMoneyPending = true
			money:Hide()
		end
	end
end

function View:CanShow()
	if not (self.bankType and C_Bank and C_Bank.CanViewBank) then
		return self.bankType ~= (Enum.BankType and Enum.BankType.Account)
	end
	return C_Bank.CanViewBank(self.bankType) and true or false
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

function View:GetDepositTargetBag()
	if not (self.open and self:CanUse()) then
		return nil
	end
	self:EnsureDepositTarget()
	return self.depositTargetBag
end

function View:EnsureDepositTarget()
	if self.depositTargetBag then
		for i = 1, #self.tabSlots do
			local btn = self.tabSlots[i]
			if btn.bagID == self.depositTargetBag and btn.tabPurchased then
				return
			end
		end
		self.depositTargetBag = nil
	end
	if self.tabSlots then
		for i = 1, #self.tabSlots do
			local btn = self.tabSlots[i]
			if btn.bagID and btn.tabPurchased then
				self.depositTargetBag = btn.bagID
				return
			end
		end
	end
end

function View:SetDepositTargetBag(bagID)
	if not bagID or self.depositTargetBag == bagID then
		return
	end
	self.depositTargetBag = bagID
	self:UpdateTabBarSelection()
end

function View:UpdateTabBarSelection()
	if not self.tabSlots then
		return
	end
	local selected = self.depositTargetBag
	for i = 1, #self.tabSlots do
		local button = self.tabSlots[i]
		local icon = button.icon
		if icon then
			if selected and button.bagID == selected then
				icon:SetVertexColor(TAB_SELECTED_COLOR[1], TAB_SELECTED_COLOR[2], TAB_SELECTED_COLOR[3])
			else
				icon:SetVertexColor(1, 1, 1)
			end
		end
	end
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
	-- Per-view key so Character Bank and Warband Bank each remember their own
	-- position independently. Fall back to the old shared "windowPos" key on
	-- first load so existing users don't lose their saved position.
	local key = "windowPos_" .. (self.enabledKey or "active")
	return ns.db.bank[key] or ns.db.bank.windowPos
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
	-- Save under the per-view key so Character Bank and Warband Bank positions
	-- don't overwrite each other (the old code used one shared "windowPos").
	local posKey = "windowPos_" .. (self.enabledKey or "active")
	self:SetupDragPersistence(frame, function(pos)
		ns.db.bank[posKey] = pos
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

function View:GetBankTabData(tabID)
	if not (tabID and self.bankType and C_Bank and C_Bank.FetchPurchasedBankTabData) then
		return nil
	end
	local tabs = C_Bank.FetchPurchasedBankTabData(self.bankType)
	if not tabs then
		return nil
	end
	for i = 1, #tabs do
		local data = tabs[i]
		if data.ID == tabID then
			return data
		end
	end
	return nil
end

--- Blizzard's tab icon/name/filter editor (BankPanelTabSettingsMenuTemplate).
--- Baganator/Sorted/BetterBags each host their own menu; BankFrame has no
--- BankTabSettingsMenu child — it lives on BankPanel.TabSettingsMenu.
function View:EnsureTabSettingsMenu()
	if self.tabSettingsMenu then
		return self.tabSettingsMenu
	end
	if not self.frame then
		return nil
	end

	local menu = CreateFrame("Frame", nil, self.frame, "BankPanelTabSettingsMenuTemplate")
	menu:SetClampedToScreen(true)
	menu:SetFrameStrata("DIALOG")
	menu:SetFrameLevel(self.frame:GetFrameLevel() + 50)
	if menu.BorderBox then
		menu.BorderBox:SetFrameLevel(menu:GetFrameLevel() + 5)
		if menu.BorderBox.OkayButton then
			menu.BorderBox.OkayButton:SetFrameLevel(menu.BorderBox:GetFrameLevel() + 5)
		end
		if menu.BorderBox.CancelButton then
			menu.BorderBox.CancelButton:SetFrameLevel(menu.BorderBox:GetFrameLevel() + 5)
		end
	end
	menu:Hide()
	menu:SetPoint("TOPLEFT", self.frame, "TOPRIGHT", 40, 5)

	local view = self
	menu.GetBankPanel = function()
		return {
			GetTabData = function(_, tabID)
				return view:GetBankTabData(tabID)
			end,
		}
	end

	self.tabSettingsMenu = menu
	return menu
end

function View:OpenTabSettings(tabButton, bagID)
	if not (bagID and tabButton) then
		return
	end

	local panel = _G["BankPanel"]
	if panel then
		if panel.SetBankType and self.bankType then
			panel:SetBankType(self.bankType)
		end
		if panel.FetchPurchasedBankTabData then
			panel:FetchPurchasedBankTabData()
		end
		if panel.SelectTab then
			panel:SelectTab(bagID)
		end
	end

	local menu = self:EnsureTabSettingsMenu()
	if not menu then
		return
	end

	menu:ClearAllPoints()
	menu:SetPoint("TOPLEFT", tabButton, "TOPRIGHT", 8, 0)

	if menu.OnOpenTabSettingsRequested then
		menu:OnOpenTabSettingsRequested(bagID)
	else
		menu:SetSelectedTab(bagID)
		menu:Show()
	end
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
	-- Blizzard's script template runs PurchaseTabButtonMixin:OnClick in a secure
	-- context (see BankFrame.xml BankPanelPurchaseButtonScriptTemplate).
	local purchase = CreateFrame("Button", nil, bar, "BankPanelPurchaseButtonScriptTemplate, UIPanelButtonTemplate")
	purchase:SetText(BANKSLOTPURCHASE or L["Purchase"])
	purchase:SetSize(max(96, (purchase:GetTextWidth() or 60) + 24), TAB_PURCHASE_HEIGHT)
	purchase:SetPoint("TOP", bar, "TOPLEFT", leftX + rowWidth / 2, -(topInset + size + TAB_PURCHASE_GAP))
	purchase:RegisterForClicks("LeftButtonUp")
	purchase:SetAttribute("overrideBankType", self.bankType)
	purchase:HookScript("OnEnter", function(btn)
		local tabData = self.bankType and C_Bank and C_Bank.FetchNextPurchasableBankTabData and C_Bank.FetchNextPurchasableBankTabData(self.bankType)
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		GameTooltip:SetText(BANKSLOTPURCHASE or L["Purchase"])
		if tabData and GetMoneyString and tabData.tabCost and F.NotSecret(tabData.tabCost) then
			GameTooltip:AddLine(GetMoneyString(tabData.tabCost, true), 1, 1, 1)
		end
		GameTooltip:Show()
	end)
	purchase:HookScript("OnLeave", GameTooltip_Hide)
	self.purchaseButton = purchase
	self:ConfigurePurchaseButton()

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
	button.bagID = self.staticBags[index]
	button.view = self
	button.icon = _G[name .. "IconTexture"]
	button:RegisterForClicks("AnyUp")
	button:SetScript("OnClick", TabSlot_OnClick)
	button:SetScript("OnEnter", TabSlot_OnEnter)
	button:SetScript("OnLeave", TabSlot_OnLeave)
	return button
end

function View:UpdateTabBar()
	if not self.tabSlots then
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
			button.depositFlags = data.depositFlags
			button.bagID = data.ID or button.bagID
			button.tabPurchased = true
			SetIconButtonEnabled(button, true)
		else
			SetItemButtonTexture(button, QUESTION_MARK_ICON)
			button.tabName = nil
			button.depositFlags = nil
			button.tabPurchased = false
			SetIconButtonEnabled(button, false)
		end
	end

	if self.depositTargetBag then
		local valid = false
		for i = 1, #self.tabSlots do
			local btn = self.tabSlots[i]
			if btn.bagID == self.depositTargetBag and btn.tabPurchased then
				valid = true
				break
			end
		end
		if not valid then
			self.depositTargetBag = nil
			self:EnsureDepositTarget()
		end
	end

	if not (self.tabBar and self.tabBar:IsShown()) then
		return
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
		if purchase:IsShown() and not (InCombatLockdown and InCombatLockdown()) then
			self:ConfigurePurchaseButton()
		end
	end
	self:UpdateTabBarSelection()
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
		self:EnsureDepositTarget()
		self:UpdateTabBarSelection()
	end
end

--- Wire secure bank chrome to Blizzard's untainted handlers (out of combat only).
function View:ConfigureSecureBankButtons()
	self:ConfigurePurchaseButton()
	self:ConfigureMoneyButtons()
end

function View:ConfigurePurchaseButton()
	local button = self.purchaseButton
	if not button or not self.bankType or (InCombatLockdown and InCombatLockdown()) then
		return
	end
	button:SetAttribute("overrideBankType", self.bankType)
end

function View:ConfigureMoneyButtons()
	local withdraw, deposit = F.PrepareBlizzardBankMoneyButtons(self.bankType)
	local withdrawProxy = F.ConfigureSecureClickProxy(self.bankMoneyWithdrawClick, withdraw, "LeftButton")
	local depositProxy = F.ConfigureSecureClickProxy(self.bankMoneyDepositClick, deposit, "RightButton")
	F.DebugBankMoney(self, "configure", {
		withdrawTarget = withdraw,
		depositTarget = deposit,
		withdrawProxy = withdrawProxy,
		depositProxy = depositProxy,
	})
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
		layoutBatchSize = C.Layout.BANK_LAYOUT_BATCH,
		mainLayoutOpts = {
			topInset = C.Layout.MAIN_CHROME_TOP,
			bottomInset = self:GetFooterBottomInset(),
			freeCount = self.freeSlots,
		},
		afterLayout = function()
			local itemButton = ns:GetModule("ItemButton")
			if itemButton and itemButton.RefreshCooldowns then
				itemButton:RefreshCooldowns()
			end
		end,
	})
end

function View:Open()
	if not self.frame then
		return
	end
	self.open = true
	self.frame:Show()
	self:ConfigureSecureBankButtons()
	self:UpdateChrome()
	self:ApplyTabBarState()
	self:UpdateBankFooter()
	self:Draw()
end

function View:Close()
	self.open = false
	if self.tabSettingsMenu and self.tabSettingsMenu:IsShown() then
		self.tabSettingsMenu:Hide()
	end
	self:UpdateChrome()
	if self.frame then
		self.frame:Hide()
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
	local bank = ns:GetModule("Bank")
	if bank and bank.NotifyBackpackBankContext then
		bank:NotifyBackpackBankContext()
	end
end

function View:InvalidateLayout()
	if self.mainContainer then
		self.mainContainer._sig = nil
		self.mainContainer._lastW = nil
		self.mainContainer._lastH = nil
	end
	if self.categoryContainers then
		for _, container in pairs(self.categoryContainers) do
			container._sig = nil
			container._lastW = nil
			container._lastH = nil
		end
	end
end

--- Live settings refresh: relayout from the last scan without rescanning bags.
--- `opts.refreshTabs` — also refresh Bank/Warband switcher + purchased tab bar
--- (skip for masonry-only sliders; UpdateTabs was hiding the strip mid-drag).
function View:Relayout(opts)
	opts = opts or {}
	if not self.open or not self.frame then
		return
	end
	ns.BankSession:EnsureBankPanel(self)
	if self.sections then
		self:DrawLayout()
	else
		self:Draw()
	end
	self:UpdateBankFooter()
	if opts.refreshTabs then
		self:ApplyTabBarState()
		local bank = ns:GetModule("Bank")
		if bank then
			bank:UpdateTabs()
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
		ns:BeginBagSort()
		local bank = ns:GetModule("Bank")
		if bank then
			ns:ScheduleBagSortFlush("bank", function()
				bank:RefreshIfOpen()
			end)
		end
		C_Container.SortBank(self.bankType)
	end
end

BankView.View = View
