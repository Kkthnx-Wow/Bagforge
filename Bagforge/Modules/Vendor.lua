--[[
	Bagforge - Vendor (merchant automation)
	-------------------------------------------------------------------------
	When a merchant opens, optionally sell junk (grey + user-flagged custom
	junk) and repair gear. Both are opt-in-safe: selling is off by default,
	repair uses your own funds unless guild repair is allowed and affordable.

	Selling is the part that bites naive implementations: the server silently
	rate-limits rapid sells, so firing every UseContainerItem in one frame
	("sell all my junk") drops most of them. NDui solves this by selling one
	item per tick on a timer; we do the same:

	  * Grey junk           - C_MerchantFrame.SellAllJunkItems() clears it in a
	    single native, server-side action (instant, no client throttle).
	  * Custom + stragglers - a throttled ticker (one UseContainerItem every
	    SELL_THROTTLE seconds) sweeps user-flagged junk and anything the native
	    call missed, stopping on MERCHANT_CLOSED or the "vendor won't buy" error.

	Repair tries guild funds first (when allowed and within the withdraw cap);
	if the guild bank can't actually cover the bill we catch the error and fall
	back to personal funds (NDui's UI_ERROR_MESSAGE pattern).

	Merchant interactions happen out of combat, so there's no taint/lockdown
	concern; money/quality/itemID values are still secret-guarded defensively.

	Transient listeners (UI_ERROR_MESSAGE, MERCHANT_CLOSED) are registered only
	while a sell/repair is in flight and torn down afterwards, so the addon
	stays idle between vendor visits.
--]]

local _, ns = ...
local C, F, L = ns.C, ns.F, ns.L

local format = string.format
local ipairs = ipairs
local select = select
local wipe = wipe
local C_Item = C_Item
local C_Container = C_Container
local C_MerchantFrame = C_MerchantFrame
local C_Timer_After = C_Timer.After
local RepairAllItems = RepairAllItems
local GetRepairAllCost = GetRepairAllCost
local CanMerchantRepair = CanMerchantRepair
local CanGuildBankRepair = CanGuildBankRepair
local GetGuildBankWithdrawMoney = GetGuildBankWithdrawMoney
local GetMoney = GetMoney
local IsShiftKeyDown = IsShiftKeyDown
local PlaySound = PlaySound
local SOUNDKIT = _G["SOUNDKIT"]

-- Stop the sweep when the merchant refuses an item (full buyback / won't buy).
local ERR_VENDOR_DOESNT_BUY = _G["ERR_VENDOR_DOESNT_BUY"]
-- Numeric error type for "guild bank doesn't have enough money" (repair).
local GUILD_NOT_ENOUGH = _G["LE_GAME_ERR_GUILD_NOT_ENOUGH_MONEY"]

-- One sell per this many seconds keeps us under the server's sell rate limit.
local SELL_THROTTLE = 0.2

ns:RegisterDefaults({
	vendor = {
		active = true,
		autoSellJunk = false, -- opt-in: actually vendors your grey items
		autoSellCustomJunk = false, -- extra opt-in for user-flagged non-grey junk
		autoRepair = true,
		useGuildFunds = true, -- prefer guild funds for repair when allowed
	},
})

local Vendor = ns:NewModule("Vendor", "vendor")
Vendor.title = L["Vendor"]
Vendor.order = 30
Vendor.group = "extras"

-- ---------------------------------------------------------------------------
-- Selling (throttled sweep)
-- ---------------------------------------------------------------------------
local StartSelling, SellStep, StopSelling, OnSellError, OnMerchantClosedSell

local selling = false
local sellCache = {} -- numeric bag/slot key -> already attempted this visit

-- True when the slot holds something we should vendor: grey, or a custom-junk
-- entry when that toggle is on. Sellable means a real price and not locked.
local function ShouldSell(info, db)
	if not info or info.hasNoValue or info.isLocked then
		return false
	end
	local id = info.itemID
	if not id or F.IsSecret(id) then
		return false
	end
	local quality = info.quality
	local isGrey = F.NotSecret(quality) and quality == 0
	local custom = db.autoSellCustomJunk and ns.global and ns.global.customJunk
	local isCustom = custom and custom[id]
	if not (isGrey or isCustom) then
		return false
	end
	local price = ns.Scan and ns.Scan.GetSellPrice and ns.Scan.GetSellPrice(id)
	return price and F.NotSecret(price) and price > 0
end

function StopSelling()
	if not selling then
		return
	end
	selling = false
	ns:UnregisterEvent("UI_ERROR_MESSAGE", OnSellError)
	ns:UnregisterEvent("MERCHANT_CLOSED", OnMerchantClosedSell)
end

-- Sell exactly one qualifying item, then reschedule. Slots aren't compacted by
-- selling, so a per-slot cache lets us skip everything we've already handled and
-- never loop on the same item. Empty (sold) slots return nil and fall through.
function SellStep()
	if not selling then
		return
	end
	local db = ns.db.vendor
	for _, bag in ipairs(C.BACKPACK_BAGS) do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local key = F.SlotKey(bag, slot)
			if not sellCache[key] then
				sellCache[key] = true
				local info = C_Container.GetContainerItemInfo(bag, slot)
				if info and ShouldSell(info, db) then
					C_Container.UseContainerItem(bag, slot)
					C_Timer_After(SELL_THROTTLE, SellStep)
					return
				end
			end
		end
	end
	StopSelling()
end

function OnSellError(_, _, message)
	if message and ERR_VENDOR_DOESNT_BUY and message == ERR_VENDOR_DOESNT_BUY then
		StopSelling()
	end
end

function OnMerchantClosedSell()
	StopSelling()
end

function StartSelling(db)
	-- Native bulk clear for grey junk first: one server-side action, no client
	-- throttle, instant. Guarded by IsSellAllJunkEnabled where present.
	if C_MerchantFrame and C_MerchantFrame.SellAllJunkItems then
		if not (C_MerchantFrame.IsSellAllJunkEnabled and not C_MerchantFrame.IsSellAllJunkEnabled()) then
			C_MerchantFrame.SellAllJunkItems()
		end
	end
	if selling then
		return
	end
	selling = true
	wipe(sellCache)
	ns:RegisterEvent("UI_ERROR_MESSAGE", OnSellError)
	ns:RegisterEvent("MERCHANT_CLOSED", OnMerchantClosedSell)
	-- Throttled sweep mops up custom junk and any grey the native call missed.
	SellStep()
end

-- ---------------------------------------------------------------------------
-- Repair (guild funds first, with a personal-funds fallback)
-- ---------------------------------------------------------------------------
local DoRepair, FinishGuildRepair, OnRepairError

local guildRepairFailed = false
local guildRepairCost = 0

function OnRepairError(_, errorType)
	if GUILD_NOT_ENOUGH and errorType == GUILD_NOT_ENOUGH then
		guildRepairFailed = true
	end
end

-- 0.5s after a guild-repair attempt: if the bank couldn't cover it (error
-- caught above), repair from personal funds instead; otherwise report success.
function FinishGuildRepair()
	ns:UnregisterEvent("UI_ERROR_MESSAGE", OnRepairError)
	if guildRepairFailed then
		DoRepair(true) -- override: skip the guild path, use our own money
		return
	end
	if PlaySound and SOUNDKIT then
		PlaySound(SOUNDKIT.ITEM_REPAIR)
	end
	if F.NotSecret(guildRepairCost) then
		F.Print(format(L["Repaired with guild funds (%s)."], F.FormatMoney(guildRepairCost)))
	end
end

function DoRepair(override)
	if not (CanMerchantRepair and CanMerchantRepair()) then
		return
	end

	local cost, canRepair = GetRepairAllCost()
	-- Midnight: cost can be a secret value; never compare it without a guard.
	if not canRepair or not cost or F.IsSecret(cost) or cost <= 0 then
		return
	end

	local db = ns.db.vendor

	-- Guild funds first when permitted and within the withdraw cap (-1 means an
	-- unlimited cap). We can only know the bank is actually empty by trying and
	-- watching for the error, so arm the listener before the attempt.
	if (not override) and db.useGuildFunds and CanGuildBankRepair and CanGuildBankRepair() then
		local withdraw = GetGuildBankWithdrawMoney and GetGuildBankWithdrawMoney() or 0
		if F.NotSecret(withdraw) and (withdraw == -1 or withdraw >= cost) then
			guildRepairFailed = false
			guildRepairCost = cost
			ns:RegisterEvent("UI_ERROR_MESSAGE", OnRepairError)
			RepairAllItems(true)
			C_Timer_After(0.5, FinishGuildRepair)
			return
		end
	end

	-- Personal funds.
	local myMoney = GetMoney and GetMoney() or 0
	if F.NotSecret(myMoney) and myMoney >= cost then
		RepairAllItems()
		if PlaySound and SOUNDKIT then
			PlaySound(SOUNDKIT.ITEM_REPAIR)
		end
		F.Print(format(L["Repaired for %s."], F.FormatMoney(cost)))
	else
		F.Print(L["Not enough money to repair."])
	end
end

-- ---------------------------------------------------------------------------
-- Merchant entry point
-- ---------------------------------------------------------------------------
function Vendor:OnMerchantShow()
	local db = ns.db.vendor
	if not db.active then
		return
	end
	-- Hold Shift at the counter to suppress all automation for a manual visit.
	if IsShiftKeyDown and IsShiftKeyDown() then
		return
	end
	if db.autoSellJunk then
		StartSelling(db)
	end
	if db.autoRepair then
		DoRepair(false)
	end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function Vendor:OnEnable()
	-- Registered unconditionally so the individual toggles (and the master
	-- switch) apply live; the handler re-reads the DB on every merchant visit.
	self:RegisterEvent("MERCHANT_SHOW", self.OnMerchantShow)
end

function Vendor:OnSettingChanged(key)
	if key == "active" or key == "autoSellJunk" or key == "autoSellCustomJunk" then
		StopSelling()
	end
end

-- ---------------------------------------------------------------------------
-- Settings panel
-- ---------------------------------------------------------------------------
function Vendor:RegisterOptions(category, builder)
	local _, master = builder:Checkbox(category, self, "active", L["Enable Vendor Automation"], L["Run the actions below automatically when you open a merchant. Hold Shift as the merchant opens to skip it."])

	local _, sell = builder:Checkbox(category, self, "autoSellJunk", L["Auto Sell Junk"], L["Sell all Poor-quality (grey) items when visiting a merchant."])
	builder:DependsOn(sell, master)

	local _, sellCustom = builder:Checkbox(category, self, "autoSellCustomJunk", L["Auto Sell Custom Junk"], L["Also sell items you've marked as custom junk when Auto Sell Junk runs."])
	builder:DependsOn(sellCustom, sell)

	local _, repair = builder:Checkbox(category, self, "autoRepair", L["Auto Repair"], L["Repair all gear when visiting a merchant that can repair."])
	builder:DependsOn(repair, master)

	local _, guild = builder:Checkbox(category, self, "useGuildFunds", L["Use Guild Funds"], L["Repair from the guild bank first when your rank allows it."])
	builder:DependsOn(guild, repair)
end
