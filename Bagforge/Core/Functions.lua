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
local pairs, ipairs = pairs, ipairs
local floor = math.floor
local format = string.format
local tconcat = table.concat
local tremove = table.remove
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
		if GetMoney and F.IsSecret(GetMoney()) then
			GameTooltip:SetOwner(money, tooltipAnchor)
			GameTooltip:SetText(L["Money"])
			GameTooltip:Show()
			return
		end
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

--- Format a copper amount into "Xg Ys Zc" using Blizzard's coin icons. The gold
--- component gets thousands separators. Callers must pre-screen secret values
--- (GetMoney can return a secret in combat - see the Midnight guide).
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

--- Stable hash key for a bag/slot pair (used across scan, transfers, and buttons).
function F.SlotKey(bag, slot)
	return (bag or 0) * 1000 + (slot or 0)
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
-- Secret values (Patch 12.0 / Midnight)
--   A handful of APIs (money in combat, unit identity in instances) return
--   "secret" values that tainted code may not compare or do arithmetic on.
--   Gate any such read with these guards first. Each helper is safe to call
--   even on clients where the underlying primitive doesn't exist.
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

-- Item-level and bind-label helpers live in Modules/ItemInfo.lua (cached at scan).
