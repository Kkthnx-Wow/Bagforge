-- Minimal WoW client stub for headless Bagforge smoke tests (Lua 5.1).
local M = {}

local timers = {}
function M.flushTimers(maxRounds)
	for _ = 1, (maxRounds or 20) do
		if #timers == 0 then return end
		local batch = timers
		timers = {}
		for i = 1, #batch do
			if not batch[i].cancelled then batch[i].fn() end
		end
	end
end

-- Universal dummy: any index or call yields another dummy.
local dummyMT = {}
local function newDummy()
	return setmetatable({}, dummyMT)
end
dummyMT.__index = function(t, k)
	if k == "GetObjectType" then return function() return "Frame" end end
	local d = newDummy()
	rawset(t, k, d)
	return d
end
dummyMT.__call = function() return newDummy() end
dummyMT.__newindex = rawset
M.newDummy = newDummy

local frames = {}
local function newFrame(name)
	local f = newDummy()
	rawset(f, "__scripts", {})
	rawset(f, "__events", {})
	rawset(f, "SetScript", function(self, k, fn) self.__scripts[k] = fn end)
	rawset(f, "GetScript", function(self, k) return self.__scripts[k] end)
	rawset(f, "HookScript", function() end)
	rawset(f, "RegisterEvent", function(self, e) self.__events[e] = true end)
	rawset(f, "UnregisterEvent", function(self, e) self.__events[e] = nil end)
	rawset(f, "IsShown", function(self) return self.__shown and true or false end)
	rawset(f, "Show", function(self) self.__shown = true end)
	rawset(f, "Hide", function(self) self.__shown = false end)
	rawset(f, "SetShown", function(self, v) self.__shown = v and true or false end)
	rawset(f, "GetName", function() return name end)
	rawset(f, "GetWidth", function() return 100 end)
	rawset(f, "GetTextWidth", function() return 50 end)
	rawset(f, "GetStringWidth", function() return 50 end)
	rawset(f, "GetHeight", function() return 100 end)
	rawset(f, "GetFrameLevel", function() return 1 end)
	rawset(f, "GetText", function(self) return self.__text or "" end)
	rawset(f, "SetText", function(self, t) self.__text = t end)
	rawset(f, "GetID", function(self) return self.__id or 0 end)
	rawset(f, "SetID", function(self, i) self.__id = i end)
	rawset(f, "GetParent", function(self) return self.__parent end)
	rawset(f, "SetParent", function(self, p) self.__parent = p end)
	frames[#frames + 1] = f
	return f
end
M.frames = frames

function M.install(opts)
	opts = opts or {}
	local G = _G
	-- plain Lua helpers WoW provides
	G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	G.tinsert, G.tremove = table.insert, table.remove
	G.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
	G.strsplit = function(d, s) local r = {} for p in (s .. d):gmatch("(.-)" .. d:gsub("%p", "%%%0")) do r[#r + 1] = p end return unpack(r) end
	G.format, G.strfind, G.strmatch, G.gsub = string.format, string.find, string.match, string.gsub
	G.bit = G.bit or { band = function(a, b) local r, bitv = 0, 1 while a > 0 and b > 0 do if a % 2 == 1 and b % 2 == 1 then r = r + bitv end a, b, bitv = math.floor(a / 2), math.floor(b / 2), bitv * 2 end return r end }
	G.CopyTable = function(t) local r = {} for k, v in pairs(t) do r[k] = type(v) == "table" and G.CopyTable(v) or v end return r end
	G.geterrorhandler = function() return function(e) error(e, 0) end end
	G.hooksecurefunc = function() end
	G.issecretvalue = function() return false end
	G.canaccessvalue = function() return true end
	local now = 100
	G.GetTime = function() return now end
	G.GetTimePreciseSec = function() return now end
	M.advance = function(dt) now = now + dt end

	G.CreateFrame = function(_, name) local f = newFrame(name) if name then G[name] = f end return f end
	G.UIParent = newFrame("UIParent")
	G.C_Timer = {
		After = function(_, fn) timers[#timers + 1] = { fn = fn } end,
		NewTimer = function(_, fn)
			local t = { fn = fn }
			t.Cancel = function(self) self.cancelled = true end
			timers[#timers + 1] = t
			return t
		end,
	}
	G.InCombatLockdown = function() return false end
	G.IsShiftKeyDown = function() return false end
	G.IsAltKeyDown = function() return false end
	G.IsControlKeyDown = function() return false end
	G.IsLoggedIn = function() return true end
	G.GetLocale = function() return "enUS" end
	G.GetBuildInfo = function() return "12.1.5", "70575", "x", 120105 end
	G.UnitClass = function() return "Mage", "MAGE" end
	G.UnitClassBase = function() return "MAGE" end
	G.UnitName = function() return "Tester" end
	G.UnitLevel = function() return 80 end
	G.GetRealmName = function() return "Realm" end
	G.WOW_PROJECT_ID, G.WOW_PROJECT_MAINLINE = 1, 1
	G.LE_EXPANSION_LEVEL_CURRENT = 11
	G.C_AddOns = {
		GetAddOnMetadata = function(_, k) return k == "Version" and "1.3.2" or "Bagforge" end,
		IsAddOnLoaded = function() return true end,
		LoadAddOn = function() return true end,
	}

	G.Enum = {
		BagIndex = { Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5,
			CharacterBankTab_1 = 6, CharacterBankTab_2 = 7, CharacterBankTab_3 = 8, CharacterBankTab_4 = 9, CharacterBankTab_5 = 10, CharacterBankTab_6 = 11,
			AccountBankTab_1 = 12, AccountBankTab_2 = 13, AccountBankTab_3 = 14, AccountBankTab_4 = 15, AccountBankTab_5 = 16 },
		BankType = { Character = 0, Guild = 1, Account = 2 },
		ItemClass = { Consumable = 0, Container = 1, Weapon = 2, Gem = 3, Armor = 4, Reagent = 5, Projectile = 6, Tradegoods = 7, ItemEnhancement = 8, Recipe = 9, Quiver = 11, Questitem = 12, Key = 13, Miscellaneous = 15, Glyph = 16, Battlepet = 17, WoWToken = 18, Profession = 19 },
		ItemQuality = { Poor = 0, Common = 1, Uncommon = 2, Good = 2, Rare = 3, Superior = 3, Epic = 4, Legendary = 5, Artifact = 6, Heirloom = 7 },
		ItemMiscellaneousSubclass = { Junk = 0, Reagent = 1, CompanionPet = 2, Holiday = 3, Other = 4, Mount = 5 },
		ItemWeaponSubclass = setmetatable({}, { __index = function() return 99 end }),
		ItemArmorSubclass = setmetatable({}, { __index = function() return 98 end }),
		BagSlotFlags = setmetatable({}, { __index = function(_, k) return 2 ^ (#k % 10) end }),
		TooltipDataLineType = { SellPrice = 11, ItemBinding = 20, ItemLevel = 22 },
		TooltipDataItemBinding = { BindOnEquip = 2, BindOnUse = 3, Account = 4, AccountUntilEquipped = 6 },
		ItemBind = { OnEquip = 2, OnUse = 3, ToWoWAccount = 7, ToBnetAccount = 8, ToBnetAccountUntilEquipped = 9 },
		PlayerInteractionType = { TradePartner = 1, Merchant = 5, MailInfo = 17, Auctioneer = 21, ScrappingMachine = 40, AccountBanker = 68 },
	}
	G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) print("[chat] " .. m) end }
	G.Item = { CreateFromBagAndSlot = function() return { IsValid = function() return false end } end }
	G.ITEM_QUALITY_COLORS = {}
	for q = 0, 7 do G.ITEM_QUALITY_COLORS[q] = { r = 1, g = 1, b = 1 } end

	-- Everything else: dummy-on-demand, so file-scope captures like
	-- `local X = SomeBlizzardGlobal` never fail.
	setmetatable(G, { __index = function(t, k)
		local tables = { SOUNDKIT = true, NORMAL_FONT_COLOR = true, HIGHLIGHT_FONT_COLOR = true, RED_FONT_COLOR = true, GREEN_FONT_COLOR = true, GRAY_FONT_COLOR = true, RAID_CLASS_COLORS = true, UISpecialFrames = true }
		if type(k) == "string" and k:match("^[A-Z][A-Z0-9_]+$") and not tables[k] then
			return nil -- string constants stay nil so "or fallback" code paths run
		end
		if type(k) == "string" and (k:match("^[A-Z]") or k:match("^C_")) then
			local d = newDummy()
			rawset(t, k, d)
			return d
		end
	end })
	return M
end

return M
