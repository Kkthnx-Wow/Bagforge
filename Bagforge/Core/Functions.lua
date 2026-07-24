--[[
	Bagforge - Functions
	-------------------------------------------------------------------------
	Shared, stateless utility library. Reuse tables, avoid per-call garbage,
	cache globals, prefer string.format over chained concatenation. Most of
	this is borrowed verbatim from NexEnhance so the two addons feel the same
	to work on.
--]]

local _, ns = ...
local C, F = ns.C, ns.F

local select, type, tostring = select, type, tostring
local pairs = pairs
local floor = math.floor
local format = string.format
local tconcat = table.concat
local wipe = wipe
local pcall = pcall
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local C_Item = C_Item
local GetTime = GetTime
local BreakUpLargeNumbers = BreakUpLargeNumbers
local DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME

local PREFIX = format("|c%s%s|r:", C.BrandHex, "Bagforge")

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------

-- Reusable buffer so Print() doesn't allocate a fresh table per call.
local printBuffer = {}
function F.Print(...)
	wipe(printBuffer)
	printBuffer[1] = PREFIX
	for i = 1, select("#", ...) do
		printBuffer[i + 1] = tostring((select(i, ...)))
	end
	DEFAULT_CHAT_FRAME:AddMessage(tconcat(printBuffer, " "))
end

-- ---------------------------------------------------------------------------
-- Colour helpers
-- ---------------------------------------------------------------------------

--- Convert 0-1 RGB to a WoW hex string ("ffRRGGBB") for use after |c.
function F.RGBToHex(r, g, b)
	if type(r) == "table" then
		r, g, b = r[1], r[2], r[3]
	end
	return format("ff%02x%02x%02x", r * 255, g * 255, b * 255)
end

--- Wrap text in a colour escape sequence. `color` may be a {r,g,b} table or a
--- key into C.Colors ("red", "brand", ...).
function F.Colorize(text, color)
	if type(color) == "string" then
		color = C.Colors[color] or C.Colors.white
	end
	return format("|c%s%s|r", F.RGBToHex(color), text)
end

-- ---------------------------------------------------------------------------
-- Tooltip click hints (Blizzard-style "<[icon] Left-Click> to …" lines)
-- ---------------------------------------------------------------------------

local CreateAtlasMarkup = _G["CreateAtlasMarkup"]
local GameTooltip_AddNormalLine = _G["GameTooltip_AddNormalLine"]
local CLICK_ICON_SIZE = 16
local CLICK_BRACKET = "|cffc0c0c0"
local CLICK_BRACKET_END = "|r"
local LEFT_CLICK_ICON = CreateAtlasMarkup and CreateAtlasMarkup("housing-hotkey-icon-leftclick", CLICK_ICON_SIZE, CLICK_ICON_SIZE) or ""
local RIGHT_CLICK_ICON = CreateAtlasMarkup and CreateAtlasMarkup("housing-hotkey-icon-rightclick", CLICK_ICON_SIZE, CLICK_ICON_SIZE) or ""

--- Bracketed click token with optional mouse atlas, e.g. |cffc0c0c0<[icon] Left-Click>|r
function F.FormatClickToken(button)
	local L = ns.L
	local isRight = button == "right" or button == "RightButton"
	local label = isRight and L["Right-Click"] or L["Left-Click"]
	local icon = isRight and RIGHT_CLICK_ICON or LEFT_CLICK_ICON
	local token = label
	if icon ~= "" then
		token = icon .. " " .. label
	end
	return CLICK_BRACKET .. "<" .. token .. ">" .. CLICK_BRACKET_END
end

--- Full hint line; `formatKey` is an L["%s to …"] locale key.
function F.FormatClickHint(button, formatKey)
	return format(ns.L[formatKey], F.FormatClickToken(button))
end

function F.AddClickHintLine(tooltip, button, formatKey, r, g, b)
	local line = F.FormatClickHint(button, formatKey)
	if GameTooltip_AddNormalLine then
		GameTooltip_AddNormalLine(tooltip, line, r, g, b)
	else
		tooltip:AddLine(line, r or 1, g or 1, b or 1)
	end
end

local GameTooltip = GameTooltip
local MONEY_COIN_BUTTONS = { "GoldButton", "SilverButton", "CopperButton" }

--- Hover glow + pick-up tooltip on a PLAYER SmallMoneyFrame (bags / character bank).
function F.DecoratePickupMoneyFrame(money, tooltipAnchor)
	local L = ns.L
	tooltipAnchor = tooltipAnchor or "ANCHOR_LEFT"

	local highlight = money:CreateTexture(nil, "OVERLAY")
	highlight:SetAtlas("CreditsScreen-Highlight")
	highlight:SetBlendMode("ADD")
	highlight:SetAlpha(0.5)
	highlight:SetPoint("TOPLEFT", money.GoldButton or money, "TOPLEFT", -4, 2)
	highlight:SetPoint("BOTTOMRIGHT", money.CopperButton or money, "BOTTOMRIGHT", 2, -2)
	highlight:Hide()
	money.bfHighlight = highlight

	local function OnEnter()
		highlight:Show()
		GameTooltip:SetOwner(money, tooltipAnchor)
		GameTooltip:SetText(L["Money"])
		F.AddClickHintLine(GameTooltip, "left", "%s to pick up money")
		GameTooltip:Show()
	end
	local function OnLeave()
		highlight:Hide()
		GameTooltip:Hide()
	end

	for i = 1, #MONEY_COIN_BUTTONS do
		local button = money[MONEY_COIN_BUTTONS[i]]
		if button then
			button:HookScript("OnEnter", OnEnter)
			button:HookScript("OnLeave", OnLeave)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Money
-- ---------------------------------------------------------------------------

local InCombatLockdown = _G["InCombatLockdown"]
local MoneyFrame_UpdateMoney = _G["MoneyFrame_UpdateMoney"]
local MoneyFrame_SetType = _G["MoneyFrame_SetType"]

--- True when the player money frame can be refreshed outside combat lockdown.
function F.CanUpdatePlayerMoney()
	if InCombatLockdown and InCombatLockdown() then
		return false
	end
	return true
end

--- Show and refresh a SmallMoneyFrameTemplate, or hide when money is unavailable.
--- Optional moneyType for bank account/character frames. Returns true on success.
function F.UpdatePlayerMoneyFrame(money, moneyType)
	if not money or not MoneyFrame_UpdateMoney then
		return false
	end
	if not F.CanUpdatePlayerMoney() then
		money:Hide()
		return false
	end
	money:Show()
	if moneyType and MoneyFrame_SetType then
		MoneyFrame_SetType(money, moneyType)
	end
	MoneyFrame_UpdateMoney(money)
	return true
end

--- Format a copper amount into "Xg Ys Zc" using Blizzard's coin icons. The gold
--- component gets thousands separators.
function F.FormatMoney(copper)
	copper = floor(copper or 0)
	local gold = floor(copper / 10000)
	local silver = floor((copper % 10000) / 100)
	local copperRem = copper % 100

	local goldIcon = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
	local silverIcon = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
	local copperIcon = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"

	if gold > 0 then
		local goldText = BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or gold
		return format("%s%s %d%s %d%s", goldText, goldIcon, silver, silverIcon, copperRem, copperIcon)
	elseif silver > 0 then
		return format("%d%s %d%s", silver, silverIcon, copperRem, copperIcon)
	end
	return format("%d%s", copperRem, copperIcon)
end

-- Frame budget for hot UI paths (Baganator CheckTimeout ~100ms).
local frameBudgetStart

function F.ReportFrameBudget()
	frameBudgetStart = GetTimePreciseSec and GetTimePreciseSec() or GetTime()
end

function F.FrameBudgetExceeded(limitSec)
	if not frameBudgetStart then
		return false
	end
	local now = GetTimePreciseSec and GetTimePreciseSec() or GetTime()
	return (now - frameBudgetStart) >= (limitSec or 0.1)
end

--- Stable hash key for a bag/slot pair (used across scan, transfers, and buttons).
function F.SlotKey(bag, slot)
	return (bag or 0) * 1000 + (slot or 0)
end

function F.SlotBag(key)
	return floor((key or 0) / 1000)
end

function F.SlotIndex(key)
	return (key or 0) % 1000
end

--- WoW frame levels must stay in [0, 65535]; negative parents are valid.
function F.ClampFrameLevel(level)
	if not level or level < 0 then
		return 0
	end
	if level > 65535 then
		return 65535
	end
	return level
end

--- Cached vendor sell price per itemID (delegates to Core/Scan.lua).
function F.GetSellPrice(itemID, hyperlink)
	if ns.Scan and ns.Scan.GetSellPrice then
		return ns.Scan.GetSellPrice(itemID, hyperlink)
	end
end

-- ---------------------------------------------------------------------------
-- Table helpers
-- ---------------------------------------------------------------------------

--- Recursively fill `target` with any keys missing from `defaults`, without
--- clobbering values the user already set. This is the saved-variable "apply
--- defaults" pass. A saved value whose *type* no longer matches the default is
--- reset (heals schema drift). Keys absent from `defaults` are preserved, so
--- genuinely dynamic data (profiles, positions) survives.
function F.CopyDefaults(defaults, target)
	if type(target) ~= "table" then
		target = {}
	end
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			target[key] = F.CopyDefaults(value, target[key])
		elseif target[key] == nil or type(target[key]) ~= type(value) then
			target[key] = value
		end
	end
	return target
end

-- Bounded memo cache: store `value` under `key`, wiping the whole table once it
-- grows past `limit` (default 600). A session-long cache keyed by something
-- open-ended (item *links*, which vary by enchant/bonus IDs) can otherwise creep
-- forever; this caps it cheaply without per-entry LRU bookkeeping. The live
-- count rides on a non-key sentinel field so it never collides with real keys.
-- Adapted from NexEnhance's F.CacheSet.
local CACHE_COUNT = {}
function F.CacheSet(cache, key, value, limit)
	local count = cache[CACHE_COUNT] or 0
	if count >= (limit or 600) then
		wipe(cache)
		count = 0
	end
	if cache[key] == nil then
		count = count + 1
	end
	cache[CACHE_COUNT] = count
	cache[key] = value
	return value
end

-- ---------------------------------------------------------------------------
-- Timing
-- ---------------------------------------------------------------------------

--- Debounce: returns a function that, however often it's called, runs `func`
--- only once after `delay` seconds of quiet. Built for event storms like
--- BAG_UPDATE that fire a dozen times for a single loot.
function F.Debounce(delay, func)
	local scheduled = false
	return function(...)
		if scheduled then
			return
		end
		scheduled = true
		local args = { ... }
		C_Timer.After(delay, function()
			scheduled = false
			func(unpack(args))
		end)
	end
end

--- Debounce with no per-call args table (for zero-argument refresh handlers).
--- Leading-edge: first call in a burst schedules one run; calls during the window
--- are dropped (not reset). Prefer DebounceTrailingNoArgs for bag refresh storms.
function F.DebounceNoArgs(delay, func)
	local scheduled = false
	return function()
		if scheduled then
			return
		end
		scheduled = true
		C_Timer.After(delay, function()
			scheduled = false
			func()
		end)
	end
end

--- Trailing debounce (BetterBags-style): each call resets the timer so `func`
--- runs once after `delay` seconds of quiet. Use for BAG_UPDATE / sort flush.
function F.DebounceTrailingNoArgs(delay, func)
	local timer
	return function()
		if timer and timer.Cancel then
			timer:Cancel()
		end
		timer = C_Timer.NewTimer(delay, function()
			timer = nil
			func()
		end)
	end
end

local bucketTimers = {}
local bucketArgs = {}
local bucketArgCount = 0

--- Bucket rapid-fire events (BetterBags-style): each fire resets the timer;
--- `handler` runs once after `delay` seconds of quiet. Registers on the
--- shared ns event frame.
--- Returns the registered callback so callers can UnregisterEvent on teardown.
function F.BucketEvent(event, delay, handler)
	if not (event and handler) then
		return
	end
	delay = delay or 0.2
	local callback = function(...)
		bucketArgCount = select("#", ...)
		for i = 1, bucketArgCount do
			bucketArgs[i] = select(i, ...)
		end
		local timer = bucketTimers[event]
		if timer and timer.Cancel then
			timer:Cancel()
		end
		bucketTimers[event] = C_Timer.NewTimer(delay, function()
			bucketTimers[event] = nil
			handler(unpack(bucketArgs, 1, bucketArgCount))
		end)
	end
	return ns:RegisterEvent(event, callback)
end

-- ---------------------------------------------------------------------------
-- Tooltip hover throttle
--   Rapid cursor movement across hundreds of bank slots must not call
--   GameTooltip:Hide / mixin OnLeave / C_Timer.NewTimer per crossing. One shared
--   OnUpdate polls the hover target; Blizzard cleanup runs only after a tooltip
--   was actually shown.
-- ---------------------------------------------------------------------------
local TOOLTIP_HOVER_DELAY = 0.12
local hoverFrame
local hoverTarget
local hoverReadyAt = 0
local tooltipShownButton
local GameTooltip = _G["GameTooltip"]
local ContainerFrameItemButtonMixin = _G["ContainerFrameItemButtonMixin"]

local function GetBagSlot(button)
	local parent = button:GetParent()
	local entry = parent and parent.entry
	if entry and entry.bag ~= nil and entry.slot then
		return entry.bag, entry.slot
	end
	local bag = parent and parent:GetID()
	local slot = button:GetID()
	-- Backpack is bag 0; bank tabs can be negative. Only slot must be positive.
	if bag == nil or not slot or slot <= 0 then
		return nil, nil
	end
	return bag, slot
end

local function IsMouseOnButton(button)
	if not button then
		return false
	end
	if button:IsMouseOver() then
		return true
	end
	local parent = button:GetParent()
	return parent and parent:IsMouseOver()
end

local function HideShownTooltip()
	if not tooltipShownButton then
		return
	end
	local prev = tooltipShownButton
	tooltipShownButton = nil
	if ContainerFrameItemButtonMixin and ContainerFrameItemButtonMixin.OnLeave then
		local ok, err = pcall(ContainerFrameItemButtonMixin.OnLeave, prev)
		if not ok and not F.IsSecretLuaError(err) then
			geterrorhandler()(err)
		end
	elseif GameTooltip then
		GameTooltip:Hide()
	end
end

local function ShowBagItemTooltip(button)
	if not button then
		return
	end
	local bag, slot = GetBagSlot(button)
	if not bag or not slot then
		return
	end
	if tooltipShownButton ~= button then
		HideShownTooltip()
	end
	-- Full stock tooltip (quest text, dress-up cursor, comparison, etc.).
	local shown = false
	if ContainerFrameItemButtonMixin and ContainerFrameItemButtonMixin.OnEnter then
		local ok, err = pcall(ContainerFrameItemButtonMixin.OnEnter, button)
		if ok then
			shown = true
		elseif not F.IsSecretLuaError(err) then
			geterrorhandler()(err)
		end
	end
	if not shown and GameTooltip and GameTooltip.SetBagItem then
		GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
		local ok = pcall(GameTooltip.SetBagItem, GameTooltip, bag, slot)
		if ok then
			GameTooltip:Show()
			shown = true
		end
	end
	if shown then
		tooltipShownButton = button
	end
end

local function StopHoverPoll()
	if hoverFrame then
		hoverFrame:SetScript("OnUpdate", nil)
	end
end

local function EnsureHoverFrame()
	if not hoverFrame then
		hoverFrame = CreateFrame("Frame")
	end
	return hoverFrame
end

local function StartHoverPoll()
	local frame = EnsureHoverFrame()
	if frame:GetScript("OnUpdate") then
		return
	end
	frame:SetScript("OnUpdate", function()
		local target = hoverTarget
		if not target then
			StopHoverPoll()
			return
		end
		if GetTime() < hoverReadyAt then
			return
		end
		if not IsMouseOnButton(target) then
			hoverTarget = nil
			StopHoverPoll()
			return
		end
		hoverTarget = nil
		StopHoverPoll()
		ShowBagItemTooltip(target)
	end)
end

function F.TooltipThrottleLeave(button)
	if hoverTarget == button then
		hoverTarget = nil
	end
	-- Fast path: cursor passed over a slot without ever showing its tooltip.
	if tooltipShownButton ~= button then
		return
	end
	HideShownTooltip()
end

function F.TooltipThrottleEnter(button)
	if not button then
		return
	end
	hoverTarget = button
	hoverReadyAt = GetTime() + TOOLTIP_HOVER_DELAY
	StartHoverPoll()
end

function F.HideActiveBagTooltip()
	hoverTarget = nil
	StopHoverPoll()
	HideShownTooltip()
end

function F.RefreshBagItemTooltipIfHovered(button)
	if not button or not IsMouseOnButton(button) then
		return
	end
	if tooltipShownButton == button then
		ShowBagItemTooltip(button)
	end
end

--- Install delayed tooltip show on a ContainerFrameItemButtonTemplate button.
--- SetScript replaces Blizzard's OnEnter/OnLeave so pass-through hovers stay cheap.
function F.InstallTooltipThrottle(button)
	if not button or button.bfTooltipThrottle then
		return
	end
	button.bfTooltipThrottle = true
	button:SetScript("OnEnter", F.TooltipThrottleEnter)
	button:SetScript("OnLeave", F.TooltipThrottleLeave)
end

-- ---------------------------------------------------------------------------
-- Object pool
--   Generic recycler that spares the GC for frequently created/freed objects
--   (frames, item buttons). Tracks the active set so the whole batch can be
--   reclaimed in one ReleaseAll() - the "rebuild this grid from scratch"
--   pattern the bag redraw leans on. Adapted from NexEnhance's F.CreatePool.
-- ---------------------------------------------------------------------------
function F.CreatePool(creator, onRemoved, onAcquired)
	-- `active` is a hash set (obj -> true) so Release is O(1) instead of O(n).
	-- `objects` stays an array for full-pool iteration (e.g. ApplyOverlayLayout).
	-- `free` stays a stack array for fast LIFO recycling.
	local pool = {
		objects = {},
		active = {},
		free = {},
		numFree = 0,
	}

	local function reclaim(obj)
		if obj.ClearAllPoints then
			obj:ClearAllPoints()
		end
		if obj.Hide then
			obj:Hide()
		end
		if onRemoved then
			onRemoved(obj)
		end
		pool.numFree = pool.numFree + 1
		pool.free[pool.numFree] = obj
	end

	local function objRelease(obj)
		pool:Release(obj)
	end

	function pool:Acquire()
		local obj
		if self.numFree > 0 then
			obj = self.free[self.numFree]
			self.free[self.numFree] = nil
			self.numFree = self.numFree - 1
		else
			obj = creator()
			if not obj then
				return nil
			end
			self.objects[#self.objects + 1] = obj
			obj.Release = objRelease
		end

		-- Hash-set membership: O(1) insert and O(1) remove in Release.
		self.active[obj] = true
		if obj.Show then
			obj:Show()
		end
		if onAcquired then
			onAcquired(obj)
		end
		return obj
	end

	-- O(1): hash-set lookup instead of the old O(n) linear scan + tremove.
	function pool:Release(obj)
		if self.active[obj] then
			self.active[obj] = nil
			reclaim(obj)
		end
	end

	function pool:ReleaseAll()
		-- Collect first to avoid mutating the table mid-pairs (Lua 5.1 safety).
		local active = self.active
		local batch = {}
		for obj in pairs(active) do
			batch[#batch + 1] = obj
		end
		for i = 1, #batch do
			active[batch[i]] = nil
			reclaim(batch[i])
		end
	end

	--- Pre-build `count` objects and immediately park them. Done out of combat
	--- so the secure item buttons we hand out mid-fight were created clean and
	--- never taint the bag frame (the BetterBags trick).
	function pool:Prewarm(count)
		local made = {}
		for i = 1, count do
			made[i] = self:Acquire()
		end
		for i = 1, count do
			self:Release(made[i])
		end
	end

	-- Returns pairs() iterator over the active hash set (obj keys, true values).
	function pool:EnumerateActive()
		return pairs(self.active)
	end

	return pool
end

-- ---------------------------------------------------------------------------
-- Blizzard secure-action proxies (bank tab purchase, money transfer, …)
--   Protected APIs must run from Blizzard's untainted OnClick path. Addon
--   buttons use InsecureActionButtonTemplate + clickbutton forwarding.
-- ---------------------------------------------------------------------------
local InCombatLockdown = _G["InCombatLockdown"]

function F.GetBlizzardBankPanel()
	local bankFrame = _G.BankFrame
	return bankFrame and bankFrame.BankPanel
end

function F.GetBlizzardBankPurchaseButton()
	local panel = F.GetBlizzardBankPanel()
	local prompt = panel and panel.PurchasePrompt
	local costFrame = prompt and prompt.TabCostFrame
	return costFrame and costFrame.PurchaseButton
end

function F.GetBlizzardBankMoneyButtons()
	local panel = F.GetBlizzardBankPanel()
	local moneyFrame = panel and panel.MoneyFrame
	if not moneyFrame then
		return nil, nil
	end
	return moneyFrame.WithdrawButton, moneyFrame.DepositButton
end

--- Keep Blizzard withdraw/deposit handlers alive for secure click proxies.
--- Purchase-prompt mode hides MoneyFrame; without this, clickbutton targets stay
--- hidden/disabled and warband gold transfer never opens the popup.
function F.PrepareBlizzardBankMoneyButtons(bankType)
	local panel = F.GetBlizzardBankPanel()
	if not panel or not bankType then
		return nil, nil
	end
	if panel.GetActiveBankType and panel:GetActiveBankType() ~= bankType and panel.SetBankType then
		panel:SetBankType(bankType)
	end
	local moneyFrame = panel.MoneyFrame
	if not moneyFrame then
		return nil, nil
	end
	moneyFrame:Show()
	if moneyFrame.RefreshContents then
		moneyFrame:RefreshContents()
	elseif moneyFrame.Refresh then
		moneyFrame:Refresh()
	end
	local withdraw = moneyFrame.WithdrawButton
	local deposit = moneyFrame.DepositButton
	if withdraw and withdraw.Refresh then
		withdraw:Refresh()
	end
	if deposit and deposit.Refresh then
		deposit:Refresh()
	end
	-- Bagforge paints its own money display; hide Blizzard chrome only.
	if moneyFrame.MoneyDisplay then
		moneyFrame.MoneyDisplay:Hide()
	end
	if withdraw then
		withdraw:EnableMouse(false)
	end
	if deposit then
		deposit:EnableMouse(false)
	end
	return withdraw, deposit
end

--- Wire left/right secure bank money transfer on one proxy (avoids overlapping
--- frames swallowing clicks meant for the other mouse button).
function F.ConfigureSecureBankMoneyProxy(button, withdrawTarget, depositTarget)
	if not button or (InCombatLockdown and InCombatLockdown()) then
		return false
	end
	if not withdrawTarget and not depositTarget then
		return false
	end
	button:SetAttribute("useOnKeyDown", false)
	button:SetAttribute("type", nil)
	button:SetAttribute("clickbutton", nil)
	if withdrawTarget then
		button:SetAttribute("type1", "click")
		button:SetAttribute("clickbutton1", withdrawTarget)
	else
		button:SetAttribute("type1", nil)
		button:SetAttribute("clickbutton1", nil)
	end
	if depositTarget then
		button:SetAttribute("type2", "click")
		button:SetAttribute("clickbutton2", depositTarget)
	else
		button:SetAttribute("type2", nil)
		button:SetAttribute("clickbutton2", nil)
	end
	button:EnableMouse(true)
	return true
end

--- Point `button` (InsecureActionButtonTemplate) at Blizzard's secure button.
--- `mouseButton` is "LeftButton" or "RightButton" (maps to secure suffix 1/2).
function F.ConfigureSecureClickProxy(button, target, mouseButton)
	if not button or not target or (InCombatLockdown and InCombatLockdown()) then
		return false
	end
	-- Mouse-up clicks are ignored when the global key-down CVar is on unless we
	-- override per-button (same issue as action bars with ActionButtonUseKeyDown).
	button:SetAttribute("useOnKeyDown", false)
	button:SetAttribute("type", nil)
	button:SetAttribute("clickbutton", nil)
	if mouseButton == "RightButton" then
		button:SetAttribute("type1", nil)
		button:SetAttribute("clickbutton1", nil)
		button:SetAttribute("type2", "click")
		button:SetAttribute("clickbutton2", target)
	elseif mouseButton == "LeftButton" then
		button:SetAttribute("type2", nil)
		button:SetAttribute("clickbutton2", nil)
		button:SetAttribute("type1", "click")
		button:SetAttribute("clickbutton1", target)
	else
		button:SetAttribute("type1", "click")
		button:SetAttribute("clickbutton1", target)
		button:SetAttribute("type2", "click")
		button:SetAttribute("clickbutton2", target)
	end
	button:EnableMouse(true)
	return true
end

function F.BankMoneyDebugEnabled()
	return ns.global and ns.global.bankMoneyDebug and true or false
end

function F.SetBankMoneyDebug(enabled)
	if ns.global then
		ns.global.bankMoneyDebug = enabled and true or false
	end
end

local function DbgYesNo(v)
	return v and "yes" or "no"
end

local function DbgName(frame)
	return frame and frame:GetName() or "anon"
end

--- Verbose warband/character bank gold transfer diagnostics (`/bf debugmoney`).
function F.DebugBankMoney(view, tag, extra)
	if not F.BankMoneyDebugEnabled() then
		return
	end

	local format = string.format
	local prefix = format("|cffaaaaaa[BankMoney:%s]|r", tag or "?")
	local C_Bank = _G.C_Bank
	local bankType = view and view.bankType
	local panel = F.GetBlizzardBankPanel()
	local moneyFrame = panel and panel.MoneyFrame
	local withdraw = moneyFrame and moneyFrame.WithdrawButton
	local deposit = moneyFrame and moneyFrame.DepositButton
	local proxy = view and view.bankMoneyClick

	F.Print(prefix, "view", view and view.enabledKey or "nil", "open", DbgYesNo(view and view.open))
	F.Print(prefix, "bankType", bankType, "transfer", DbgYesNo(view and view.SupportsMoneyTransfer and view:SupportsMoneyTransfer()))
	if bankType and C_Bank then
		F.Print(
			prefix,
			"canUse",
			DbgYesNo(view and view.CanUse and view:CanUse()),
			"canWithdraw",
			DbgYesNo(C_Bank.CanWithdrawMoney and C_Bank.CanWithdrawMoney(bankType)),
			"canDeposit",
			DbgYesNo(C_Bank.CanDepositMoney and C_Bank.CanDepositMoney(bankType))
		)
		local locked = C_Bank.FetchBankLockedReason and C_Bank.FetchBankLockedReason(bankType)
		if locked ~= nil then
			F.Print(prefix, "lockedReason", locked)
		end
	end
	F.Print(prefix, "combat", DbgYesNo(InCombatLockdown and InCombatLockdown()))

	local bfMoney = view and view.bankMoneyFrame
	if bfMoney then
		F.Print(prefix, "bfMoney", DbgYesNo(bfMoney:IsShown()), DbgYesNo(bfMoney:IsVisible()), "enabled", DbgYesNo(bfMoney:IsMouseEnabled()))
	end
	if proxy then
		F.Print(
			prefix,
			"proxy",
			DbgYesNo(proxy:IsShown()),
			DbgYesNo(proxy:IsEnabled()),
			"mouse",
			DbgYesNo(proxy:IsMouseEnabled()),
			"withdraw",
			DbgName(extra and extra.withdrawTarget or withdraw),
			"deposit",
			DbgName(extra and extra.depositTarget or deposit),
			"wired",
			DbgYesNo(extra and extra.withdrawProxy)
		)
	end

	if panel then
		local activeType = panel.GetActiveBankType and panel:GetActiveBankType()
		F.Print(prefix, "panel", DbgYesNo(panel:IsShown()), "activeType", activeType)
		local purchasePrompt = panel.PurchasePrompt
		if purchasePrompt then
			F.Print(prefix, "purchasePrompt", DbgYesNo(purchasePrompt:IsShown()))
		end
	end
	if moneyFrame then
		F.Print(prefix, "blizzMoney", DbgYesNo(moneyFrame:IsShown()), DbgYesNo(moneyFrame:IsVisible()))
	end
	if withdraw then
		local forbidden = withdraw.IsForbidden and withdraw:IsForbidden()
		F.Print(prefix, "blizzW", DbgYesNo(withdraw:IsShown()), DbgYesNo(withdraw:IsEnabled()), "forbidden", DbgYesNo(forbidden))
	end
	if deposit then
		local forbidden = deposit.IsForbidden and deposit:IsForbidden()
		F.Print(prefix, "blizzD", DbgYesNo(deposit:IsShown()), DbgYesNo(deposit:IsEnabled()), "forbidden", DbgYesNo(forbidden))
	end

	local GetCVarBool = _G.GetCVarBool
	if GetCVarBool then
		F.Print(prefix, "cvarKeyDown", DbgYesNo(GetCVarBool("ActionButtonUseKeyDown")))
	end

	local StaticPopup_Visible = _G.StaticPopup_Visible
	if StaticPopup_Visible then
		F.Print(
			prefix,
			"popupW",
			DbgYesNo(StaticPopup_Visible("BANK_MONEY_WITHDRAW")),
			"popupD",
			DbgYesNo(StaticPopup_Visible("BANK_MONEY_DEPOSIT"))
		)
	end
end

function F.DebugBankMoneyDumpAll()
	local bank = ns:GetModule("Bank")
	if not bank or not bank.views then
		F.DebugBankMoney(nil, "dump")
		return
	end
	for i = 1, #bank.views do
		local view = bank.views[i]
		if view then
			F.DebugBankMoney(view, "dump-" .. (view.enabledKey or i))
		end
	end
end

-- ---------------------------------------------------------------------------
-- Secret values (Patch 12.0 / Midnight)
--   Only gate APIs Resources tags as return-secret (see
--   wow-midnight-secret-values-guide.mdc). Item/container/money fields are
--   SecretArguments-only or untagged — do not invent IsSecret there.
--   Keep helpers for identity (Recent GUID) and IsSecretLuaError swallows.
-- ---------------------------------------------------------------------------
do
	local issecretvalue = _G["issecretvalue"]
	local canaccessvalue = _G["canaccessvalue"]

	--- True when `value` is a secret value (always safe to call).
	function F.IsSecret(value)
		return issecretvalue and issecretvalue(value)
	end

	--- True when `value` is a normal (non-secret) value.
	function F.NotSecret(value)
		return not F.IsSecret(value)
	end

	--- True when tainted code may actually read `value`. Defaults to true where
	--- the primitive is unavailable (i.e. pre-Midnight clients).
	function F.CanAccessValue(value)
		return not canaccessvalue or canaccessvalue(value)
	end

	--- Return `value` when safe to compare or do arithmetic; nil if secret/missing.
	--- Prefer raw numbers for untagged item APIs; kept for soft coerce callers.
	function F.SafeNumber(value)
		if value == nil or F.IsSecret(value) then
			return nil
		end
		return value
	end

	--- Return `value` when safe to branch on; nil if secret/missing.
	function F.SafeBool(value)
		if value == nil or F.IsSecret(value) then
			return nil
		end
		return value
	end

	--- True when a Lua error was raised by touching a secret value in tainted code.
	function F.IsSecretLuaError(err)
		return type(err) == "string" and err:find("secret value", 1, true) ~= nil
	end
end

-- Midnight tooltip guards: ShowBagItemTooltip / HideShownTooltip above wrap
-- ContainerFrameItemButtonMixin and SetBagItem in pcall. F.IsSecretLuaError
-- identifies secret-value failures so we fall back or hide without Lua errors.

-- ---------------------------------------------------------------------------
-- Font strings
-- ---------------------------------------------------------------------------

--- Create an OUTLINE font string on `parent` using a stock game font as the
--- base, then resize it. Keeps every label in the addon consistent.
function F.CreateFS(parent, size, text, layer)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY", "GameFontNormal")
	local font, _, flags = fs:GetFont()
	fs:SetFont(font, size or 12, flags or "")
	if text then
		fs:SetText(text)
	end
	return fs
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

--- A bare texture button (no template) with the additive square highlight the
--- chrome icons share (cleanup broom, bag-bar toggle, bank sort). `normal` /
--- `pushed` accept a fileID (number), a texture path (string with a slash) OR
--- an atlas name (plain string) - the latter routes through Set*Atlas, since
--- SetNormalTexture silently ignores atlas names. `pushed` defaults to `normal`.
--- The highlight is pinned to the button's centre at its full size so it lines
--- up whatever the art. Callers attach their own OnClick / tooltip scripts.
local function ApplyButtonArt(btn, art, setTexture, setAtlas)
	if not art then
		return
	end
	-- fileID (number) or an explicit texture path (has a slash) -> SetTexture;
	-- a plain name is an atlas, which needs Set*Atlas to resolve.
	if type(art) == "number" or art:find("[\\/]") then
		btn[setTexture](btn, art)
	elseif btn[setAtlas] then
		btn[setAtlas](btn, art)
	else
		btn[setTexture](btn, art)
	end
end

function F.CreateIconButton(parent, width, height, normal, pushed)
	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(width, height)
	if normal then
		ApplyButtonArt(btn, normal, "SetNormalTexture", "SetNormalAtlas")
		ApplyButtonArt(btn, pushed or normal, "SetPushedTexture", "SetPushedAtlas")
	end
	btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	local hl = btn:GetHighlightTexture()
	if hl then
		hl:ClearAllPoints()
		hl:SetSize(width, height)
		hl:SetPoint("CENTER", btn, "CENTER", 0, 0)
	end
	return btn
end

--- Shrink the stock ButtonHilight-Square (e.g. oversized chrome icons).
function F.SetIconButtonHighlightSize(button, size)
	local hl = button:GetHighlightTexture()
	if hl then
		hl:ClearAllPoints()
		hl:SetSize(size, size)
		hl:SetPoint("CENTER", button, "CENTER", 0, 0)
	end
end

--- Additive bags-newitem glow shared by armed toolbar modes and chrome hovers.
--- `inset` pulls the glow inward (px); default 0 matches the armed-mode buttons.
function F.EnsureIconGlow(button, inset)
	if button.bfIconGlow then
		return button.bfIconGlow
	end
	inset = inset or 0
	local x = -2 + inset
	local y = 2 - inset
	local glow = button:CreateTexture(nil, "OVERLAY")
	glow:SetAtlas("bags-newitem")
	glow:SetBlendMode("ADD")
	glow:SetPoint("TOPLEFT", button, "TOPLEFT", x, y)
	glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -x, -y)
	glow:Hide()
	button.bfIconGlow = glow
	return glow
end

-- Anchor a small overlay (font string / texture) to a slot corner. `corner` is
-- one of topleft | topright | bottomleft | bottomright (case-insensitive).
function F.AnchorOverlayCorner(overlay, parent, corner, inset)
	if not (overlay and parent) then
		return
	end
	inset = inset or 2
	local c = corner and string.lower(corner) or "bottomleft"
	overlay:ClearAllPoints()
	if c == "topright" then
		overlay:SetPoint("TOPRIGHT", parent, "TOPRIGHT", inset, -inset)
	elseif c == "bottomleft" then
		overlay:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", inset, inset)
	elseif c == "bottomright" then
		overlay:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", inset, inset)
	elseif c == "top" then
		overlay:SetPoint("TOP", parent, "TOP", 0, -inset)
	elseif c == "bottom" then
		overlay:SetPoint("BOTTOM", parent, "BOTTOM", 0, inset)
	elseif c == "left" then
		overlay:SetPoint("LEFT", parent, "LEFT", inset, 0)
	elseif c == "right" then
		overlay:SetPoint("RIGHT", parent, "RIGHT", inset, 0)
	elseif c == "center" then
		overlay:SetPoint("CENTER", parent, "CENTER", 0, 0)
	else
		overlay:SetPoint("TOPLEFT", parent, "TOPLEFT", inset, -inset)
	end
end

--- Normalize C_Item.GetItemInfo for Midnight (ItemInfo table) and older
--- multi-return callers. Field names match Blizzard ItemDocumentation.lua.
--- Returns nil when data is not cached yet.
function F.GetItemInfoRecord(itemIDOrLink)
	if not (itemIDOrLink and C_Item and C_Item.GetItemInfo) then
		return nil
	end
	local a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r = C_Item.GetItemInfo(itemIDOrLink)
	if not a then
		return nil
	end
	if type(a) == "table" then
		return a
	end
	return {
		itemName = a,
		itemLink = b,
		itemQuality = c,
		itemLevel = d,
		itemMinLevel = e,
		itemType = f,
		itemSubType = g,
		itemStackCount = h,
		itemEquipLoc = i,
		itemTexture = j,
		sellPrice = k,
		classID = l,
		subclassID = m,
		bindType = n,
		expansionID = o,
		setID = p,
		isCraftingReagent = q,
		itemDescription = r,
	}
end

--- Normalize C_Item.GetItemInfoInstant. Blizzard documents a *different* shape
--- than GetItemInfo: itemID, itemType, itemSubType, itemEquipLoc, icon, classID,
--- subclassID (no link, quality, stack, or expansion). See warcraft.wiki.gg
--- API_C_Item.GetItemInfoInstant and ItemDocumentation.lua.
function F.GetItemInfoInstantRecord(itemIDOrLink)
	if not (itemIDOrLink and C_Item and C_Item.GetItemInfoInstant) then
		return nil
	end
	local a, b, c, d, e, f, g = C_Item.GetItemInfoInstant(itemIDOrLink)
	if not a then
		return nil
	end
	if type(a) == "table" then
		local sub = a.subclassID or a.subClassID
		return {
			itemID = a.itemID,
			itemType = a.itemType,
			itemSubType = a.itemSubType,
			itemEquipLoc = a.itemEquipLoc,
			itemTexture = a.itemTexture or a.icon,
			classID = a.classID,
			subclassID = sub,
			subClassID = sub,
		}
	end
	return {
		itemID = a,
		itemType = b,
		itemSubType = c,
		itemEquipLoc = d,
		itemTexture = e,
		classID = f,
		subclassID = g,
		subClassID = g,
	}
end

--- Item ID from a full item hyperlink (stable across API return-shape changes).
function F.GetItemIDFromLink(link)
	if not link then
		return nil
	end
	local id = link:match("item:(%d+)")
	return id and tonumber(id) or nil
end

--- Localized item name from either API shape.
function F.GetItemName(itemID)
	local info = F.GetItemInfoRecord(itemID)
	return info and info.itemName
end

-- Item-level and bind-label helpers live in Modules/ItemInfo.lua (cached at scan).
