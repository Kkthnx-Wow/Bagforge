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
local C_PlayerInteractionManager = C_PlayerInteractionManager
local wipe = wipe

local BankSession = ns.BankSession
local BankView = ns.BankView

--- Warband Bank Convergence (and other account-only banker NPCs) expose warband
--- storage only. Blizzard gates character tabs with C_Bank.CanViewBank(Character).
local function IsAccountBankerOnly()
	if not (C_PlayerInteractionManager and C_PlayerInteractionManager.IsInteractingWithNpcOfType) then
		return false
	end
	local accountBanker = Enum.PlayerInteractionType and Enum.PlayerInteractionType.AccountBanker
	if not accountBanker then
		return false
	end
	return C_PlayerInteractionManager.IsInteractingWithNpcOfType(accountBanker)
end

ns:RegisterDefaults({
	bank = {
		active = true,
		warband = true,
		columns = C.Layout.BANK_COLUMNS,
		warbandColumns = C.Layout.WARBAND_COLUMNS,
		iconSize = C.Layout.ITEM_SIZE,
		warbandIconSize = C.Layout.ITEM_SIZE,
		categoriesPerColumn = C.Layout.BANK_CATEGORIES_PER_COLUMN,
		depositReagents = true,
		showTabBar = false,
		lastView = "active",
		positions = {},
	},
})

ns:RegisterDefaults({ bankMoneyDebug = false }, "global")

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

function Bank:RefreshIfOpen(rescan, dirtyBags, dirtySlotKeys)
	if not self.views then
		return
	end
	for i = 1, #self.views do
		self.views[i]:RefreshIfOpen(rescan, dirtyBags, dirtySlotKeys)
	end
end

--- Repaint purchased-tab icons/names after Blizzard updates tab metadata.
function Bank:RefreshTabBars(bankType)
	if not self.views then
		return
	end
	for i = 1, #self.views do
		local view = self.views[i]
		if view.open and (not bankType or view.bankType == bankType) then
			if view.tabSettingsMenu and view.tabSettingsMenu:IsShown() then
				view.tabSettingsMenu:Hide()
			end
			view:UpdateTabBar()
		end
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

function Bank:RefreshQuestState()
	if not self.views then
		return false
	end
	local changed = false
	for i = 1, #self.views do
		local view = self.views[i]
		if view.open and view.scanner and view.scanner:RefreshQuestState() then
			changed = true
			view._pendingChangeset = view.scanner.lastChangeset
			if view.DrawLayout then
				view:DrawLayout()
			end
		end
	end
	return changed
end

function Bank:RefreshItemID(itemID, accumulate)
	if not (self.views and itemID) then
		return false, false, false
	end
	local needRescan = false
	local junkChanged = false
	local needLayout = false
	for i = 1, #self.views do
		local view = self.views[i]
		if view.scanner then
			local changed, junk, finalize = view.scanner:RefreshItemID(itemID, accumulate)
			if finalize then
				needRescan = true
			end
			if junk then
				junkChanged = true
			end
			if view.open and (changed or junk) and not finalize then
				view._pendingChangeset = view.scanner.lastChangeset
				needLayout = true
			end
		end
	end
	return needRescan, junkChanged, needLayout
end

--- refreshFn(scanner[, onComplete]) → changed, needsFinalize[, pending].
--- When any view is budget-pending, returns pending=true and calls onAllDone
--- once every view has finished (sync or async).
function Bank:ApplyViewScannerRefresh(refreshFn, onAllDone)
	if not self.views then
		return false, false, false
	end
	local anyChanged = false
	local needRescan = false
	local pending = 0
	local finished = false

	local function noteResult(view, scanner, changed, finalize)
		if finalize then
			needRescan = true
		end
		if changed and view.open then
			view._pendingChangeset = scanner.lastChangeset
			anyChanged = true
		end
	end

	local function tryAllDone()
		if pending > 0 or finished then
			return
		end
		finished = true
		if onAllDone then
			onAllDone(anyChanged, needRescan)
		end
	end

	for i = 1, #self.views do
		local view = self.views[i]
		local scanner = view and view.scanner
		if scanner and refreshFn and #scanner.slots > 0 then
			pending = pending + 1
			local changed, finalize, isPending = refreshFn(scanner, function(asyncChanged, asyncFinalize)
				noteResult(view, scanner, asyncChanged, asyncFinalize)
				pending = pending - 1
				tryAllDone()
			end)
			if not isPending then
				noteResult(view, scanner, changed, finalize)
				pending = pending - 1
			end
		end
	end

	if pending > 0 then
		return anyChanged, needRescan, true
	end
	return anyChanged, needRescan, false
end

function Bank:RefreshCategories()
	return Bank:ApplyViewScannerRefresh(function(scanner, onComplete)
		return scanner:RefreshCategories(nil, onComplete)
	end)
end

function Bank:DrawPendingLayouts()
	if not self.views then
		return
	end
	for i = 1, #self.views do
		local view = self.views[i]
		if view.open and view._pendingChangeset and view.DrawLayout then
			view:DrawLayout()
		end
	end
end

local function CopyDirtyBags(dirtyBags, into)
	if not next(dirtyBags) then
		return nil
	end
	local copy = into
	if copy then
		wipe(copy)
	else
		copy = {}
	end
	for bag in pairs(dirtyBags) do
		copy[bag] = true
	end
	return copy
end

local function MarkAllBankBagsDirty(dirtyBags)
	for _, bag in ipairs(C.CHARACTER_BANK_BAGS) do
		dirtyBags[bag] = true
	end
	for _, bag in ipairs(C.ACCOUNT_BANK_BAGS) do
		dirtyBags[bag] = true
	end
end

local function DirtyBagsAffectOpenView(dirtyBags)
	local open = Bank:OpenView()
	if not open or not next(dirtyBags) then
		return false
	end
	local bags = open:GetBankBags()
	for i = 1, #bags do
		if dirtyBags[bags[i]] then
			return true
		end
	end
	return false
end

Bank._dirtySlotScratch = {}
Bank._dirtyBagCopy = {}

local function FlushBankRefresh(dirtyBags)
	if InCombatLockdown() then
		Bank._pendingCombatRefresh = true
		return
	end
	Bank._pendingCombatRefresh = false
	if not Bank:OpenView() then
		wipe(dirtyBags)
		return
	end
	local sortFlush = ns:IsSortFlush()
	if not sortFlush and not DirtyBagsAffectOpenView(dirtyBags) then
		wipe(dirtyBags)
		return
	end
	local dirtyCopy = (not sortFlush) and CopyDirtyBags(dirtyBags, Bank._dirtyBagCopy) or nil
	local dirtySlots
	local open = Bank:OpenView()
	if dirtyCopy and open and open.scanner and open.GetBankBags and ns.Scan and ns.Scan.CollectDirtySlotKeys then
		dirtySlots = ns.Scan.CollectDirtySlotKeys(open.scanner, open:GetBankBags(), dirtyCopy, Bank._dirtySlotScratch)
		if not dirtySlots then
			wipe(dirtyBags)
			return
		end
	end
	wipe(dirtyBags)
	if sortFlush then
		open = Bank:OpenView()
		if open and open.ScanAfterSort then
			open:ScanAfterSort()
			return
		end
	end
	Bank:RefreshIfOpen(nil, dirtyCopy, dirtySlots)
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
	if IsAccountBankerOnly() then
		local warband = self:GetView("warband")
		if warband and self:IsViewAvailable(warband) then
			return warband
		end
	end

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

--- Refresh backpack ItemContextOverlay when bank context changes (open/close/tab).
function Bank:NotifyBackpackBankContext()
	local itemButton = ns:GetModule("ItemButton")
	if itemButton and itemButton.RefreshWarbandDim then
		itemButton:RefreshWarbandDim()
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
		self:NotifyBackpackBankContext()
		return
	end
	ns.db.bank.lastView = view.enabledKey
	BankSession:EnsureBankPanel(view)
	view:Open()
	self:UpdateTabs()
	BankSession:SuppressBlizzardBankFrame(self)
	BankSession:RefreshItemContext()
	BankSession.SetSwitchingView(false)
	self:NotifyBackpackBankContext()
end

function Bank:UpdateTabs()
	local open = self:OpenView()
	if not open or not open.tabStrip then
		return
	end

	-- Hide unavailable views (convergence toy = character bank tab off). Keep the
	-- strip visible when at least one tab remains so the active bank label still
	-- shows (matches Blizzard's lone "Warband Bank" tab on account-only bankers).
	local viewableCount = 0
	for i = 1, #self.views do
		local view = self.views[i]
		if self:IsViewEnabled(view) then
			if self:IsViewAvailable(view) then
				viewableCount = viewableCount + 1
				open.tabStrip:ShowTab(view.enabledKey)
			else
				open.tabStrip:HideTab(view.enabledKey)
			end
		else
			open.tabStrip:HideTab(view.enabledKey)
		end
	end

	open.tabStrip:Resize()
	open.tabStrip:Select(open.enabledKey)
	open.tabStrip:SetShown(viewableCount > 0)
	open:AnchorTabBar()
end

function Bank:OpenBanking()
	local view = self:PickView()
	-- CanViewBank can lag BANKFRAME_OPENED by a frame on fresh login; retry
	-- once so we don't suppress Blizzard's frame and show nothing.
	if not view then
		C_Timer.After(0, function()
			if not Bank:IsBankOpen() then
				return
			end
			if not Bank:OpenView() then
				Bank:ShowView(Bank:PickView())
			end
			local open = Bank:OpenView()
			if open then
				Bank:EnsureBankPanel(open)
			end
			Bank:RefreshItemContext()
		end)
		return
	end
	self:ShowView(view)
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

function Bank:ResetPosition(scope)
	-- scope: nil = all views; true/"warband" = warband only; "active" or other
	-- enabledKey = that view only.
	local warbandOnly = scope == true or scope == "warband"
	local onlyKey = (type(scope) == "string" and scope ~= "warband") and scope or nil
	if not warbandOnly and not onlyKey then
		ns.db.bank.windowPos = nil
	end
	for i = 1, #self.views do
		local view = self.views[i]
		local key = view.enabledKey or "active"
		if warbandOnly and key ~= "warband" then
			-- skip
		elseif onlyKey and key ~= onlyKey then
			-- skip
		else
			ns.db.bank["windowPos_" .. key] = nil
			if view.frame then
				view:ApplySavedPosition(nil, view.defaultPoint, view.defaultRelPoint, view.defaultX, view.defaultY)
			end
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
	if key == "depositReagents" then
		self:ApplyDepositReagents()
	end

	-- Enable/disable toggles may need to swap or hide a view while banking.
	if key == "active" or key == "warband" then
		if self:IsRuntimeActive() then
			if not self._hooksInstalled then
				self:OnEnable()
			end
		else
			self:OnDisable()
		end
		if self:IsRuntimeActive() and (self:IsBankOpen() or self:OpenView()) then
			self:OpenBanking()
		elseif not self:IsRuntimeActive() then
			self:CloseAll()
		end
		return
	end

	-- Live layout refresh for any open Bagforge bank window (character or warband).
	local open = self:OpenView()
	if not open then
		return
	end

	if key == "columns" or key == "warbandColumns" or key == "categoriesPerColumn" or key == "iconSize" or key == "warbandIconSize" then
		-- Column/icon-size changes must rebuild panel geometry; per-column masonry
		-- only needs a layout pass (do not bump DrawEpoch or rescan — that broke the UI).
		if key == "columns" or key == "warbandColumns" or key == "iconSize" or key == "warbandIconSize" then
			open:InvalidateLayout()
		end
		open:Relayout()
		-- categoriesPerColumn is shared; relayout any other open bank view too.
		if key == "categoriesPerColumn" and self.views then
			for i = 1, #self.views do
				local view = self.views[i]
				if view ~= open and view.open then
					view:Relayout()
				end
			end
		end
		return
	end

	open:RefreshIfOpen()
end

function Bank:RegisterOptions(category, builder)
	local _, characterToggle = builder:Checkbox(category, self, "active", L["Enable Bank Window"], L["Show Bagforge's categorized character bank window while visiting a banker."])
	local _, warbandToggle = builder:Checkbox(category, self, "warband", L["Enable Warband Bank Window"], L["Show Bagforge's categorized warband (account) bank window while visiting a banker."])
	local _, characterColumns = builder:Slider(category, self, "columns", L["Bank Columns"], L["How many item columns the bank panels are wide."], C.Layout.MIN_COLUMNS, C.Layout.MAX_COLUMNS, 1)
	builder:DependsOn(characterColumns, characterToggle)
	local _, characterIconSize = builder:Slider(category, self, "iconSize", L["Bank Icon Size"], L["Width and height of each bank item button, in pixels. The window resizes to fit."], C.Layout.MIN_ICON_SIZE, C.Layout.MAX_ICON_SIZE, 1)
	builder:DependsOn(characterIconSize, characterToggle)
	local _, warbandColumns = builder:Slider(category, self, "warbandColumns", L["Warband Bank Columns"], L["How many item columns the warband bank panels are wide."], C.Layout.MIN_COLUMNS, C.Layout.MAX_COLUMNS, 1)
	builder:DependsOn(warbandColumns, warbandToggle)
	local _, warbandIconSize = builder:Slider(category, self, "warbandIconSize", L["Warband Bank Icon Size"], L["Width and height of each warband bank item button, in pixels. The window resizes to fit."], C.Layout.MIN_ICON_SIZE, C.Layout.MAX_ICON_SIZE, 1)
	builder:DependsOn(warbandIconSize, warbandToggle)
	builder:Slider(category, self, "categoriesPerColumn", L["Categories Per Column"], L["How many category panels stack in a column before wrapping to a new column on the left."], C.Layout.MIN_CATEGORIES_PER_COLUMN, C.Layout.MAX_CATEGORIES_PER_COLUMN, 1)
	local _, reagents = builder:Checkbox(category, self, "depositReagents", L["Deposit Reagents"], L["Include reagent-bag materials when using Deposit All."])
	builder:DependsOn(reagents, characterToggle)
	-- No "Bank Tabs" checkbox: the bank window's own tab button toggles it
	-- (ToggleTabBar), so a settings duplicate was redundant. showTabBar still
	-- persists; the in-bank button drives it.
end

function Bank:IsRuntimeActive()
	return ns.db.bank.active or ns.db.bank.warband
end

function Bank:EnsureViews()
	if self.views and #self.views > 0 then
		return
	end

	self.views = {}
	self.views[#self.views + 1] = BankView.New({
		bankType = BANK_TYPE_CHARACTER,
		enabledKey = "active",
		columnsKey = "columns",
		iconSizeKey = "iconSize",
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
			iconSizeKey = "warbandIconSize",
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
end

function Bank:IsBankRefreshPending()
	local dirty = self._dirtyBankBags
	return dirty and next(dirty) ~= nil
end

function Bank:RefreshCategoryHeaders()
	local view = self:OpenView()
	if not (view and view.open and view.RefreshCategoryHeaders) then
		return
	end
	view:RefreshCategoryHeaders()
end

function Bank:InstallHooks()
	local dirtyBankBags = {}
	self._dirtyBankBags = dirtyBankBags
	self._hookHandles = {}

	local function track(event, callback)
		self._hookHandles[#self._hookHandles + 1] = { event = event, callback = callback }
	end

	local queueRefresh = F.DebounceTrailingNoArgs(0.05, function()
		if ns:IsBagSortActive() then
			ns:ScheduleBagSortFlush("bank", function()
				FlushBankRefresh(dirtyBankBags)
			end)
			return
		end
		FlushBankRefresh(dirtyBankBags)
	end)

	-- Mark dirty only; flush on BAG_UPDATE_DELAYED (same as backpack Items.lua).
	-- Eager queueRefresh here raced slot data and double-fired with DELAYED.
	track(
		"BAG_UPDATE",
		ns:RegisterEvent("BAG_UPDATE", function(_, bagID)
			if bagID and (C.IS_CHARACTER_BANK_BAG[bagID] or C.IS_ACCOUNT_BANK_BAG[bagID]) then
				dirtyBankBags[bagID] = true
			end
		end)
	)

	track(
		"BANKFRAME_OPENED",
		self:RegisterEvent("BANKFRAME_OPENED", function()
			Bank:OpenBanking()
		end)
	)
	track(
		"BANKFRAME_CLOSED",
		self:RegisterEvent("BANKFRAME_CLOSED", function()
			Bank:CloseAll()
		end)
	)
	track(
		"BANK_TABS_CHANGED",
		self:RegisterEvent("BANK_TABS_CHANGED", function(_, bankType)
			-- Structural: tab count / bag list changed — flush now, don't wait for DELAYED.
			MarkAllBankBagsDirty(dirtyBankBags)
			queueRefresh()
			Bank:RefreshTabBars(bankType)
		end)
	)
	track(
		"PLAYERBANKSLOTS_CHANGED",
		self:RegisterEvent("PLAYERBANKSLOTS_CHANGED", function()
			-- Slot churn: mark dirty only; BAG_UPDATE_DELAYED owns the flush
			-- (same as backpack). Eager queueRefresh double-scanned with DELAYED.
			MarkAllBankBagsDirty(dirtyBankBags)
		end)
	)
	track(
		"PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED",
		self:RegisterEvent("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", function()
			MarkAllBankBagsDirty(dirtyBankBags)
		end)
	)
	track(
		"BANK_TAB_SETTINGS_UPDATED",
		self:RegisterEvent("BANK_TAB_SETTINGS_UPDATED", function(_, bankType)
			Bank:RefreshTabBars(bankType)
			MarkAllBankBagsDirty(dirtyBankBags)
		end)
	)
	track(
		"BANK_BAG_SLOT_FLAGS_UPDATED",
		self:RegisterEvent("BANK_BAG_SLOT_FLAGS_UPDATED", function(_, bankType)
			Bank:RefreshTabBars(bankType)
		end)
	)
	track("BAG_UPDATE_DELAYED", ns:RegisterEvent("BAG_UPDATE_DELAYED", queueRefresh))

	ns:RegisterCallback("Sort.StateChanged", function()
		for i = 1, #Bank.views do
			local view = Bank.views[i]
			if view and view.UpdateChrome then
				view:UpdateChrome()
			end
		end
	end, Bank)

	-- Events.lua: INVENTORY_SEARCH_UPDATE — keep bank scanner filters warm when closed.
	local queueSearch = F.DebounceNoArgs(0.05, function()
		local open = Bank:OpenView()
		if open and open.RefreshFiltered then
			open:RefreshFiltered()
			return
		end
		-- No open view: still refresh each view's scanner so next Open paints right.
		if not Bank.views then
			return
		end
		for i = 1, #Bank.views do
			local view = Bank.views[i]
			if view.scanner and view.scanner.RefreshFiltered then
				view.scanner:RefreshFiltered()
			end
		end
	end)
	track("INVENTORY_SEARCH_UPDATE", ns:RegisterEvent("INVENTORY_SEARCH_UPDATE", queueSearch))

	track(
		"PLAYER_MONEY",
		ns:RegisterEvent("PLAYER_MONEY", function()
			local open = Bank:OpenView()
			if open then
				open:UpdateTabBar()
				if open.UpdateBankFooter then
					open:UpdateBankFooter()
				end
			end
		end)
	)
	track(
		"ACCOUNT_MONEY",
		ns:RegisterEvent("ACCOUNT_MONEY", function()
			local open = Bank:OpenView()
			if open and open.UpdateBankFooter then
				open:UpdateBankFooter()
			end
		end)
	)
	track(
		"PLAYER_REGEN_ENABLED",
		ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
			if Bank._pendingCombatRefresh then
				MarkAllBankBagsDirty(dirtyBankBags)
				FlushBankRefresh(dirtyBankBags)
			end
			for i = 1, #Bank.views do
				local view = Bank.views[i]
				if view.open then
					if view.ConfigureSecureBankButtons then
						view:ConfigureSecureBankButtons()
					end
					if view.UpdateBankFooter then
						view:UpdateBankFooter()
					end
				end
				if view.pendingDraw or view.bankMoneyPending then
					view:RefreshIfOpen()
				end
			end
		end)
	)

	ns:RegisterCallback("Bank.Refresh", "RefreshIfOpen", self)
end

function Bank:UninstallHooks()
	if self._hookHandles then
		for i = 1, #self._hookHandles do
			local handle = self._hookHandles[i]
			ns:UnregisterEvent(handle.event, handle.callback)
		end
		self._hookHandles = nil
	end
	ns:UnregisterCallback("Bank.Refresh", self)
	ns:UnregisterCallback("Sort.StateChanged", self)
end

function Bank:OnDisable()
	if not self._hooksInstalled then
		return
	end
	self._hooksInstalled = false
	self:UninstallHooks()
	self:CloseAll()
	BankSession:RestoreBlizzardBankFrame()
	BankSession:HideBankPanel()
	self:NotifyBackpackBankContext()
end

function Bank:OnEnable()
	if ns.db.bank.depositReagents == nil and GetCVarBool then
		ns.db.bank.depositReagents = GetCVarBool("bankAutoDepositReagents") and true or false
	end
	self:ApplyDepositReagents()

	self:EnsureViews()

	if self._hooksInstalled then
		return
	end
	if not self:IsRuntimeActive() then
		return
	end
	self._hooksInstalled = true
	self:InstallHooks()
end
