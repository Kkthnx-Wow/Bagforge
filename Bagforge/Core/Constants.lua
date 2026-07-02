--[[
	Bagforge - Constants
	-------------------------------------------------------------------------
	Static, read-mostly data: client/player info, the bag index tables we walk
	to scan inventory, the quality colour palette and a few layout numbers.
	Anything looked up once at login and reused everywhere lives here so modules
	never re-query the API for values that cannot change mid-session.
--]]

local _, ns = ...
local C = ns.C

local UnitName = UnitName
local UnitClass = UnitClass
local GetRealmName = GetRealmName
local GetLocale = GetLocale
local GetBuildInfo = GetBuildInfo
local ITEM_QUALITY_COLORS = _G["ITEM_QUALITY_COLORS"]

-- ---------------------------------------------------------------------------
-- Client / player information
-- ---------------------------------------------------------------------------
do
	local version, build, _, interface = GetBuildInfo()
	C.Client = {
		version = version, -- e.g. "12.0.5"
		build = build, -- e.g. "61491"
		interface = interface, -- e.g. 120005
		locale = GetLocale(),
		isRetail = WOW_PROJECT_ID == WOW_PROJECT_MAINLINE,
		isMidnight = interface >= 120000,
	}
end

C.Player = {}

function C.RefreshPlayer()
	local className, classFile = UnitClass("player")
	C.Player.name = UnitName("player") or "Unknown"
	C.Player.realm = GetRealmName() or "Unknown"
	C.Player.class = classFile -- "MAGE", "WARRIOR", ...
	C.Player.className = className
	-- "Name - Realm" key, handy for per-character profile selection.
	C.Player.key = C.Player.name .. " - " .. C.Player.realm
	return C.Player
end

-- ---------------------------------------------------------------------------
-- Brand / colours
-- ---------------------------------------------------------------------------
C.BrandHex = "ffFD9B20" -- forge amber, matches the title's "forge"

C.Colors = {
	red = { 0.90, 0.30, 0.30 },
	green = { 0.40, 0.78, 0.40 },
	yellow = { 1.00, 0.82, 0.00 },
	gray = { 0.55, 0.55, 0.55 },
	white = { 1.00, 1.00, 1.00 },
	brand = { 0.99, 0.61, 0.13 }, -- #FD9B20 forge amber
}

-- ---------------------------------------------------------------------------
-- Bag indices
--   Enum.BagIndex gives us stable, patch-proof bag ids. The backpack set is
--   everything the player carries on their person; the reagent bag rides along
--   with it. We keep both a hash (for O(1) "is this a backpack bag?" tests) and
--   an ordered list (for deterministic scan order).
-- ---------------------------------------------------------------------------
local BagIndex = Enum.BagIndex

C.BACKPACK_BAGS = {
	Enum.BagIndex.Backpack,
	Enum.BagIndex.Bag_1,
	Enum.BagIndex.Bag_2,
	Enum.BagIndex.Bag_3,
	Enum.BagIndex.Bag_4,
}

-- The reagent bag only exists on retail; guard so Classic flavours don't choke.
if BagIndex.ReagentBag then
	C.BACKPACK_BAGS[#C.BACKPACK_BAGS + 1] = BagIndex.ReagentBag
end

-- Hash form for membership tests.
C.IS_BACKPACK_BAG = {}
for _, bag in ipairs(C.BACKPACK_BAGS) do
	C.IS_BACKPACK_BAG[bag] = true
end

-- Character bank tabs are also bag IDs in Midnight. `C_Bank` reports the
-- purchased/viewable subset at runtime; this table is the full stable range.
C.CHARACTER_BANK_BAGS = {}
for i = 1, 6 do
	local bag = BagIndex["CharacterBankTab_" .. i]
	if bag then
		C.CHARACTER_BANK_BAGS[#C.CHARACTER_BANK_BAGS + 1] = bag
	end
end

C.IS_CHARACTER_BANK_BAG = {}
for _, bag in ipairs(C.CHARACTER_BANK_BAGS) do
	C.IS_CHARACTER_BANK_BAG[bag] = true
end

-- Account (warband) bank tabs, same deal: stable bag-ID range, with the
-- purchased/viewable subset reported by C_Bank at runtime.
C.ACCOUNT_BANK_BAGS = {}
for i = 1, 5 do
	local bag = BagIndex["AccountBankTab_" .. i]
	if bag then
		C.ACCOUNT_BANK_BAGS[#C.ACCOUNT_BANK_BAGS + 1] = bag
	end
end

C.IS_ACCOUNT_BANK_BAG = {}
for _, bag in ipairs(C.ACCOUNT_BANK_BAGS) do
	C.IS_ACCOUNT_BANK_BAG[bag] = true
end

-- ---------------------------------------------------------------------------
-- Item quality colours
--   ITEM_QUALITY_COLORS is Blizzard's own table (ColorMixin entries). We flatten
--   to {r,g,b} so the item border code never has to care about the mixin shape.
-- ---------------------------------------------------------------------------
C.QualityColors = {}
do
	local quality = Enum.ItemQuality
	for _, q in pairs(quality) do
		local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
		if color then
			C.QualityColors[q] = { color.r, color.g, color.b }
		end
	end
end

-- ---------------------------------------------------------------------------
-- Layout
--   Pixel numbers the backpack window uses. Tuned to feel like a modern bag
--   without being configurable yet - that comes once the bones are solid.
-- ---------------------------------------------------------------------------
C.Layout = {
	ITEM_SIZE = 37, -- width/height of one item button
	ITEM_PADDING = 4, -- gap between item buttons
	COLUMNS = 12, -- items per row
	MIN_COLUMNS = 6,
	MAX_COLUMNS = 18,

	-- Per-category panel (the cargBags-style "container"). Each category is its
	-- own SettingsFrameTemplate frame; these numbers govern that panel.
	PANEL_PADDING = 10, -- vertical inset (top/bottom) from panel edge to its grid
	PANEL_PADDING_X = 11, -- horizontal inset; just clears the NineSlice side border (tighter = columns/margins sit closer)
	-- The SettingsFrameTemplate NineSlice border is thicker on the left, so an
	-- evenly-anchored grid looks shoved left. This shifts the whole grid (and the
	-- left-aligned chrome) right by a few px without changing the panel width, so
	-- the left margin grows and the right margin shrinks by the same amount.
	PANEL_BIAS_X = 3,
	PANEL_HEADER_HEIGHT = 22, -- clearance for the template's title bar strip
	PANEL_GAP = 2, -- gap between adjacent panels (vertical and between columns)

	-- The main "Bag" panel doubles as the window: title strip (PANEL_HEADER_HEIGHT),
	-- then search/sort row, then the item grid. GetChromeInsets() places the search
	-- row; MAIN_CHROME_TOP is the inset below the title before items start.
	MAIN_CHROME_TITLE_GAP = 0, -- search row sits directly under the title strip
	MAIN_CHROME_ROW_LIFT = 4, -- pull the chrome band up toward the title
	MAIN_CHROME_ROW_HEIGHT = 24, -- search box height (border art stretched in ContainerWindow)
	MAIN_CHROME_SEARCH_OFFSET = 0, -- search top within the chrome band
	MAIN_CHROME_BTN_OFFSET = 1, -- fine-tune icon buttons vs search row (+ = up)
	MAIN_CHROME_ROW_GAP = 6, -- gap between search row bottom and first item row
	MAIN_CHROME_TOP = 26, -- ROW_HEIGHT + ROW_GAP - ROW_LIFT (title gap is 0)
	MAIN_CHROME_BOTTOM = 34,
	MAIN_CHROME_BOTTOM_WITH_CURRENCY = 34, -- single footer row: currencies left, money right
	-- Footer: money bottom-right, watched currencies bottom-left on the same baseline.
	FOOTER_OFFSET_Y = 10,
	FOOTER_GAP = 16, -- min horizontal space between the currency cluster and money
	CURRENCY_FOOTER_OFFSET_Y = 8, -- nudged down to align with SmallMoneyFrame text baseline
	CURRENCY_BAR_OFFSET_Y = 10, -- alias of CURRENCY_FOOTER_OFFSET_Y
	MONEY_OFFSET_Y = 10,

	-- Bank footer: gold bottom-right (warband = account gold; character = wallet gold).
	WARBAND_FOOTER_OFFSET_Y = 8,
	WARBAND_MONEY_ROW_HEIGHT = 24,
	WARBAND_FOOTER_HEIGHT = 32,
	-- wrap into a new column to the left once a column holds this many panels.
	DEFAULT_CATEGORIES_PER_COLUMN = 5,
	MIN_CATEGORIES_PER_COLUMN = 1,
	MAX_CATEGORIES_PER_COLUMN = 12,
	-- Bank panels: place item buttons in chunks per frame to avoid open hitch.
	BANK_LAYOUT_BATCH = 80,
	BACKPACK_LAYOUT_BATCH = 80,
	-- Secure item buttons pre-created at login (backpack + bank while both open).
	ITEM_BUTTON_POOL_PREWARM = 400,
	ITEM_BUTTON_POOL_MAX = 900,

	-- Blizzard BankFrame UIPanel slot (area=left; UIParent LEFT_OFFSET=16, TOP_OFFSET=-116).
	BANK_DEFAULT_POINT = "LEFT",
	BANK_DEFAULT_REL_POINT = "LEFT",
	BANK_DEFAULT_X = 16,
	BANK_DEFAULT_Y = -116,
}

--- Estimate how many secure item buttons to pre-warm from the player's actual
--- bag slot counts (Baganator/BetterBags: avoid pool exhaustion when bank opens).
function C.EstimateItemButtonPoolSize()
	local C_Container = C_Container
	if not C_Container or not C_Container.GetContainerNumSlots then
		return C.Layout.ITEM_BUTTON_POOL_PREWARM or 400
	end
	local total = 0
	for _, bag in ipairs(C.BACKPACK_BAGS) do
		total = total + (C_Container.GetContainerNumSlots(bag) or 0)
	end
	for _, bag in ipairs(C.CHARACTER_BANK_BAGS) do
		total = total + (C_Container.GetContainerNumSlots(bag) or 98)
	end
	local floor = C.Layout.ITEM_BUTTON_POOL_PREWARM or 400
	local cap = C.Layout.ITEM_BUTTON_POOL_MAX or 900
	return math.min(math.max(total, floor), cap)
end
