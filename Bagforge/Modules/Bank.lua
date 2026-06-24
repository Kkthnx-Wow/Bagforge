--[[
	Bagforge - Bank (coordinator)
	-------------------------------------------------------------------------
	Owns the bank view list, routes events/settings, and delegates session
	handling (BankPanel taint, Blizzard frame suppression) to BankSession.
	Per-kind windows are BankView instances built on ContainerWindow.
--]]

local _, ns = ...
local C, F, L = ns.C, ns.F, ns.L

local C_Timer = C_Timer
local GetCVarBool = GetCVarBool
local SetCVar = SetCVar
local floor = math.floor
local tonumber = tonumber

local BAG_CLEANUP_BANK = _G["BAG_CLEANUP_BANK"]
local BAG_CLEANUP_ACCOUNT_BANK = _G["BAG_CLEANUP_ACCOUNT_BANK"]
local CHARACTER_BANK_DEPOSIT_BUTTON_LABEL = _G["CHARACTER_BANK_DEPOSIT_BUTTON_LABEL"]
local ACCOUNT_BANK_DEPOSIT_BUTTON_LABEL = _G["ACCOUNT_BANK_DEPOSIT_BUTTON_LABEL"]

local BANK_TYPE_CHARACTER = Enum.BankType and Enum.BankType.Character
local BANK_TYPE_ACCOUNT = Enum.BankType and Enum.BankType.Account

local BankSession = ns.BankSession
local BankView = ns.BankView

ns:RegisterDefaults({
	bank = {
		active = true,
		warband = true,
		columns = 14,
		warbandColumns = 14,
		categoriesPerColumn = C.Layout.DEFAULT_CATEGORIES_PER_COLUMN,
		depositReagents = true,
		showTabBar = false,
		lastView = "active",
		positions = {},
	},
})

local Bank = ns:NewModule("Bank", "bank")
Bank.title = L["Bank"]
Bank.order = 15
Bank.group = "general"

function Bank:ApplyDepositReagents()
	if SetCVar then
		SetCVar("bankAutoDepositReagents", ns.db.bank.depositReagents and "1" or "0")
	end
	local open = self:OpenView()
	if open and open.UpdateBankFooter then
		open:UpdateBankFooter()
	end
	if open and open.UpdateDepositReagentsHighlight then
		open:UpdateDepositReagentsHighlight()
	end
end

function Bank:OnInitialize()
	-- Views are built in OnEnable, but Items/Bank hooks can run earlier (e.g.
	-- QUEST_LOG_UPDATE during load); an empty table keeps #views safe.
	self.views = {}
end

function Bank:IsViewEnabled(view)
	return ns.db.bank[view.enabledKey] and true or false
end

function Bank:RefreshIfOpen()
	if not self.views then
		return
	end
	for i = 1, #self.views do
		self.views[i]:RefreshIfOpen()
	end
end

function Bank:ToggleTabBar()
	if not self.views then
		return
	end
	ns.db.bank.showTabBar = not ns.db.bank.showTabBar
	for i = 1, #self.views do
		self.views[i]:ApplyTabBarState()
	end
end

function Bank:CloseAll()
	BankSession:CloseAll(self.views)
end

function Bank:EnsureBankPanel(view)
	BankSession:EnsureBankPanel(view)
end

function Bank:HideBankPanel()
	BankSession:HideBankPanel()
end

function Bank:IsBankOpen()
	return BankSession:IsBankOpen()
end

function Bank:RefreshItemContext()
	BankSession:RefreshItemContext()
end

function Bank:RefreshSlotLock(bag, slot)
	if not self.views then
		return false
	end
	local found = false
	for i = 1, #self.views do
		local view = self.views[i]
		if view.scanner and view.scanner:RefreshLock(bag, slot) then
			found = true
		end
	end
	return found
end

function Bank:RefreshItemID(itemID)
	if not (self.views and itemID and F.NotSecret(itemID)) then
		return
	end
	for i = 1, #self.views do
		local view = self.views[i]
		if view.scanner then
			view.scanner:RefreshItemID(itemID)
		end
	end
end

function Bank:GetView(enabledKey)
	for i = 1, #self.views do
		local view = self.views[i]
		if view.enabledKey == enabledKey then
			return view
		end
	end
end

function Bank:IsViewAvailable(view)
	return self:IsViewEnabled(view) and view:CanShow()
end

function Bank:PickView()
	local last = ns.db.bank.lastView or "active"
	local fallback
	for i = 1, #self.views do
		local view = self.views[i]
		if self:IsViewAvailable(view) then
			fallback = fallback or view
			if view.enabledKey == last then
				return view
			end
		end
	end
	return fallback
end

function Bank:OpenView()
	local views = self.views
	if not views then
		return
	end
	for i = 1, #views do
		if views[i].open then
			return views[i]
		end
	end
end

function Bank:ShowView(view)
	BankSession.SetSwitchingView(true)
	for i = 1, #self.views do
		local other = self.views[i]
		if other ~= view then
			other:Close()
		end
	end
	if not view then
		BankSession.SetSwitchingView(false)
		BankSession:RestoreBlizzardBankFrame()
		return
	end
	ns.db.bank.lastView = view.enabledKey
	BankSession:EnsureBankPanel(view)
	view:Open()
	self:UpdateTabs()
	BankSession:SuppressBlizzardBankFrame(self)
	BankSession:RefreshItemContext()
	BankSession.SetSwitchingView(false)
end

function Bank:UpdateTabs()
	local open = self:OpenView()
	if not open or not open.tabStrip then
		return
	end

	local available = 0
	for i = 1, #self.views do
		local view = self.views[i]
		if self:IsViewAvailable(view) then
			available = available + 1
			open.tabStrip:ShowTab(view.enabledKey)
		else
			open.tabStrip:HideTab(view.enabledKey)
		end
	end

	open.tabStrip:Resize()
	open.tabStrip:Select(open.enabledKey)
	open.tabStrip:SetShown(available > 1)
	open:AnchorTabBar()
end

function Bank:OpenBanking()
	self:ShowView(self:PickView())
	C_Timer.After(0, function()
		if not Bank:IsBankOpen() then
			return
		end
		local open = Bank:OpenView()
		if open then
			Bank:EnsureBankPanel(open)
		end
		Bank:RefreshItemContext()
	end)
end

function Bank:HasEnabledView()
	for i = 1, #self.views do
		if self:IsViewAvailable(self.views[i]) then
			return true
		end
	end
	return false
end

function Bank:SetColumns(columns, warband)
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

	ns.db.bank[warband and "warbandColumns" or "columns"] = columns
	self:RefreshIfOpen()
	return columns
end

function Bank:ResetPosition()
	ns.db.bank.windowPos = nil
	for i = 1, #self.views do
		local view = self.views[i]
		if view.frame then
			view:ApplySavedPosition(nil, view.defaultPoint, view.defaultRelPoint, view.defaultX, view.defaultY)
		end
	end
end

function Bank:DepositAll(warband)
	local view = self:GetView(warband and "warband" or "active")
	if view then
		view:DepositAll()
	end
end

function Bank:Sort(warband)
	local view = self:GetView(warband and "warband" or "active")
	if view then
		view:Sort()
	end
end

function Bank:OnSettingChanged(key)
	self:ApplyDepositReagents()
	local bankFrame = _G["BankFrame"]
	local banking = bankFrame and bankFrame:IsShown()
	if not banking then
		return
	end
	self:OpenBanking()
end

function Bank:RegisterOptions(category, builder)
	local _, characterToggle = builder:Checkbox(category, self, "active", L["Enable Bank Window"], L["Show Bagforge's categorized character bank window while visiting a banker."])
	local _, warbandToggle = builder:Checkbox(category, self, "warband", L["Enable Warband Bank Window"], L["Show Bagforge's categorized warband (account) bank window while visiting a banker."])
	local _, characterColumns = builder:Slider(category, self, "columns", L["Bank Columns"], L["How many item columns the bank panels are wide."], C.Layout.MIN_COLUMNS, C.Layout.MAX_COLUMNS, 1)
	builder:DependsOn(characterColumns, characterToggle)
	local _, warbandColumns = builder:Slider(category, self, "warbandColumns", L["Warband Bank Columns"], L["How many item columns the warband bank panels are wide."], C.Layout.MIN_COLUMNS, C.Layout.MAX_COLUMNS, 1)
	builder:DependsOn(warbandColumns, warbandToggle)
	builder:Slider(category, self, "categoriesPerColumn", L["Categories Per Column"], L["How many category panels stack in a column before wrapping to a new column on the left."], C.Layout.MIN_CATEGORIES_PER_COLUMN, C.Layout.MAX_CATEGORIES_PER_COLUMN, 1)
	local _, reagents = builder:Checkbox(category, self, "depositReagents", L["Deposit Reagents"], L["Include reagent-bag materials when using Deposit All."])
	builder:DependsOn(reagents, characterToggle)
	builder:Checkbox(category, self, "showTabBar", L["Bank Tabs"], L["Toggle the bank tabs."])
end

function Bank:OnEnable()
	if not ns.db.bank.windowPos then
		local old = ns.db.bank.position
		if not old and ns.db.bank.positions then
			old = ns.db.bank.positions[BANK_TYPE_CHARACTER] or ns.db.bank.positions[BANK_TYPE_ACCOUNT]
		end
		if old then
			ns.db.bank.windowPos = old
		end
	end
	ns.db.bank.position = nil
	ns.db.bank.positions = nil

	if GetCVarBool then
		ns.db.bank.depositReagents = GetCVarBool("bankAutoDepositReagents") and true or false
	end
	self:ApplyDepositReagents()

	self.views = {}
	self.views[#self.views + 1] = BankView.New({
		bankType = BANK_TYPE_CHARACTER,
		enabledKey = "active",
		columnsKey = "columns",
		frameName = "BagforgeBankFrame",
		title = L["Bank"],
		staticBags = C.CHARACTER_BANK_BAGS,
		isMember = C.IS_CHARACTER_BANK_BAG,
		sortTooltip = BAG_CLEANUP_BANK or L["Sort Bank"],
		depositLabel = CHARACTER_BANK_DEPOSIT_BUTTON_LABEL or L["Deposit All"],
		defaultPoint = C.Layout.BANK_DEFAULT_POINT,
		defaultRelPoint = C.Layout.BANK_DEFAULT_REL_POINT,
		defaultX = C.Layout.BANK_DEFAULT_X,
		defaultY = C.Layout.BANK_DEFAULT_Y,
	})
	if BANK_TYPE_ACCOUNT then
		self.views[#self.views + 1] = BankView.New({
			bankType = BANK_TYPE_ACCOUNT,
			enabledKey = "warband",
			columnsKey = "warbandColumns",
			frameName = "BagforgeWarbandBankFrame",
			title = L["Warband Bank"],
			staticBags = C.ACCOUNT_BANK_BAGS,
			isMember = C.IS_ACCOUNT_BANK_BAG,
			sortTooltip = BAG_CLEANUP_ACCOUNT_BANK or L["Sort Bank"],
			depositLabel = ACCOUNT_BANK_DEPOSIT_BUTTON_LABEL or L["Deposit All"],
			defaultPoint = C.Layout.BANK_DEFAULT_POINT,
			defaultRelPoint = C.Layout.BANK_DEFAULT_REL_POINT,
			defaultX = C.Layout.BANK_DEFAULT_X,
			defaultY = C.Layout.BANK_DEFAULT_Y,
		})
	end

	for i = 1, #self.views do
		self.views[i]:BuildWindow()
		self.views[i]:UpdateChrome()
	end
	BankSession:InstallCloseHooks(self.views)
	BankSession:InstallBankFrameHooks(self)

	ns:RegisterCallback("Bank.Refresh", "RefreshIfOpen", self)

	self:RegisterEvent("BANKFRAME_OPENED", function()
		Bank:OpenBanking()
	end)
	self:RegisterEvent("BANKFRAME_CLOSED", function()
		Bank:CloseAll()
	end)

	local queueRefresh = F.DebounceNoArgs(0.05, function()
		Bank:RefreshIfOpen()
	end)
	self:RegisterEvent("BANK_TABS_CHANGED", queueRefresh)
	self:RegisterEvent("PLAYERBANKSLOTS_CHANGED", queueRefresh)
	self:RegisterEvent("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", queueRefresh)
	ns:RegisterEvent("BAG_UPDATE_DELAYED", queueRefresh)

	-- Search only desaturates items in place; refresh the filter flags on the
	-- open view's existing scan and relayout instead of a full rescan/redraw.
	local queueSearch = F.DebounceNoArgs(0.05, function()
		local open = Bank:OpenView()
		if open and open.RefreshFiltered then
			open:RefreshFiltered()
		end
	end)
	ns:RegisterEvent("INVENTORY_SEARCH_UPDATE", queueSearch)

	ns:RegisterEvent("PLAYER_MONEY", function()
		local open = Bank:OpenView()
		if open then
			open:UpdateTabBar()
			if open.UpdateBankFooter then
				open:UpdateBankFooter()
			end
		end
	end)
	ns:RegisterEvent("ACCOUNT_MONEY", function()
		local open = Bank:OpenView()
		if open and open.UpdateBankFooter then
			open:UpdateBankFooter()
		end
	end)
	ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
		for i = 1, #Bank.views do
			local view = Bank.views[i]
			if view.pendingDraw or view.bankMoneyPending then
				view:RefreshIfOpen()
			end
		end
	end)
end
