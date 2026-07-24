--[[
	Bagforge - Search (saved-query engine)
	-------------------------------------------------------------------------
	A tiny, allocation-light query language used by Saved Search Categories
	(Modules/Organize) so the player can group items with rules like:

	    type:glyph                     all glyphs
	    sub:herb | sub:cloth           herbs OR cloth
	    gear ilvl>=600 !boe            equippable, ilvl 600+, not BoE
	    quality>=epic                  epic-or-better
	    dragon scale sub:cooking       name has "dragon" AND "scale" AND cooking
	    tt:use:                        tooltip line contains "use:" (cached 60s)

	Grammar (everything is case-insensitive):
	  * whitespace      = AND
	  * |               = OR (top-level groups)
	  * !token          = NOT
	  * key<op>value    = field test; op is one of  : = > >= < <=
	  * tt:text         = tooltip line substring (60s cache per slot)
	  * bareword        = a known flag (boe/new/quest/junk/gear/...) else a
	                      substring match on the item name

	Each query string compiles once to a predicate(entry) closure and is cached
	(the set of saved searches is small). Compilation is pure - it only reads
	scanned entry fields and never touches frames. ns.Search.Match(query, entry)
	is the only thing classifiers call.

	Modelled on BetterBags' search categories (search/query.lua), trimmed to the
	handful of fields a bag actually exposes instead of a full expression tree.
--]]

local _, ns = ...

local pairs = pairs
local tonumber, type = tonumber, type
local wipe = wipe
local tconcat = table.concat
local GetTime = GetTime
local sfind, slower, ssub, gmatch = string.find, string.lower, string.sub, string.gmatch

local C_TooltipInfo = C_TooltipInfo

local Search = {}
ns.Search = Search

local ITEM_CLASS = Enum.ItemClass
local ITEM_QUALITY = Enum.ItemQuality
local WEAPON, ARMOR = ITEM_CLASS.Weapon, ITEM_CLASS.Armor

-- Quality words the player can type (plus a few colour synonyms).
local QUALITY = {}
do
	local q = ITEM_QUALITY
	local map = {
		poor = q.Poor,
		common = q.Common,
		uncommon = q.Uncommon,
		rare = q.Rare,
		epic = q.Epic,
		legendary = q.Legendary,
		artifact = q.Artifact,
		heirloom = q.Heirloom,
		gray = q.Poor,
		grey = q.Poor,
		white = q.Common,
		green = q.Uncommon,
		blue = q.Rare,
		purple = q.Epic,
		orange = q.Legendary,
	}
	for word, value in pairs(map) do
		if value ~= nil then
			QUALITY[word] = value
		end
	end
end

-- ---------------------------------------------------------------------------
-- Field accessors
-- ---------------------------------------------------------------------------
local function NumField(entry, key)
	if key == "ilvl" or key == "level" or key == "itemlevel" then
		local v = entry.ilvl
		return v
	elseif key == "id" then
		local id = entry.itemID
		return id
	elseif key == "q" or key == "quality" then
		local v = entry.quality
		return v
	elseif key == "exp" or key == "expansion" then
		local v = entry.expacID
		return v
	elseif key == "count" or key == "qty" then
		local v = entry.count
		return v
	elseif key == "stack" or key == "maxstack" then
		local v = entry.maxStack
		return v
	end
	return nil
end

local function StrField(entry, key)
	local v
	if key == "name" then
		v = entry.name
	elseif key == "type" then
		v = entry.itemType
	elseif key == "sub" or key == "subtype" then
		v = entry.itemSubType
	elseif key == "equip" then
		v = entry.itemEquipLoc
	elseif key == "bind" then
		v = entry.bindLabel
	end
	return v
end

local function IsJunk(entry)
	local q = entry.quality
	if q == ITEM_QUALITY.Poor then
		return true
	end
	local cj = ns.global and ns.global.customJunk
	local id = entry.itemID
	return (cj and id and cj[id]) and true or false
end

-- Bareword flags: token == flag name, no value.
local FLAGS = {
	boe = function(e)
		return e.bindLabel == "BoE"
	end,
	bou = function(e)
		return e.bindLabel == "BoU"
	end,
	boa = function(e)
		return e.bindLabel == "BoA"
	end,
	wue = function(e)
		return e.bindLabel == "WuE"
	end,
	new = function(e)
		return e.isNewItem == true
	end,
	quest = function(e)
		return e.quest == true or e.questID ~= nil
	end,
	junk = IsJunk,
	gear = function(e)
		local classID = e.classID
		return classID == WEAPON or classID == ARMOR
	end,
	equipment = function(e)
		local classID = e.classID
		return classID == WEAPON or classID == ARMOR
	end,
	stackable = function(e)
		local maxStack = e.maxStack
		return maxStack ~= nil and maxStack > 1
	end,
	bound = function(e)
		return e.isBound == true
	end,
	unbound = function(e)
		return e.isBound ~= true
	end,
}

local NUM_KEYS = {
	ilvl = true,
	level = true,
	itemlevel = true,
	id = true,
	q = true,
	quality = true,
	exp = true,
	expansion = true,
	count = true,
	qty = true,
	stack = true,
	maxstack = true,
}
local STR_KEYS = { name = true, type = true, sub = true, subtype = true, equip = true, bind = true }

-- ---------------------------------------------------------------------------
-- Tooltip text cache (tt: / tooltip: search tokens)
-- ---------------------------------------------------------------------------
local TOOLTIP_CACHE_TTL = 60
local tooltipCache = {}
local tooltipLinesScratch = {}

local function TooltipKey(entry)
	return entry.bag .. ":" .. entry.slot
end

local function ReadTooltipText(entry)
	if not (entry and entry.bag and entry.slot) then
		return nil
	end
	if not (C_TooltipInfo and C_TooltipInfo.GetBagItem) then
		return nil
	end
	local key = TooltipKey(entry)
	local now = GetTime()
	local cached = tooltipCache[key]
	if cached and (now - cached.time) < TOOLTIP_CACHE_TTL then
		return cached.text
	end
	local ok, data = pcall(C_TooltipInfo.GetBagItem, entry.bag, entry.slot)
	if not ok or not data or not data.lines then
		return nil
	end
	local lines = tooltipLinesScratch
	wipe(lines)
	local lineCount = 0
	for i = 1, #data.lines do
		local line = data.lines[i]
		local text = line and line.leftText
		if text then
			lineCount = lineCount + 1
			lines[lineCount] = slower(text)
		end
	end
	if lineCount == 0 then
		return nil
	end
	local text = tconcat(lines, "\n", 1, lineCount)
	tooltipCache[key] = { time = now, text = text }
	return text
end

local function TooltipContains(needle)
	needle = slower(needle or "")
	if needle == "" then
		return function()
			return false
		end
	end
	return function(entry)
		local text = ReadTooltipText(entry)
		return text ~= nil and sfind(text, needle, 1, true) ~= nil
	end
end

-- ---------------------------------------------------------------------------
-- Compilation
-- ---------------------------------------------------------------------------
-- Longest operators first so ">=" isn't mis-read as ">".
local OPS = { ">=", "<=", ">", "<", "=", ":" }

local function SplitOp(token)
	for i = 1, #OPS do
		local op = OPS[i]
		local at = sfind(token, op, 1, true)
		if at and at > 1 then
			return ssub(token, 1, at - 1), op, ssub(token, at + #op)
		end
	end
	return nil
end

local function NumMatcher(op, n)
	if op == ">" then
		return function(v)
			return v ~= nil and v > n
		end
	elseif op == ">=" then
		return function(v)
			return v ~= nil and v >= n
		end
	elseif op == "<" then
		return function(v)
			return v ~= nil and v < n
		end
	elseif op == "<=" then
		return function(v)
			return v ~= nil and v <= n
		end
	end
	return function(v)
		return v ~= nil and v == n
	end -- "=" / ":"
end

local function BuildField(key, op, value)
	if NUM_KEYS[key] then
		local n
		if (key == "q" or key == "quality") and QUALITY[value] then
			n = QUALITY[value]
		else
			n = tonumber(value)
		end
		if not n then
			return nil
		end
		local cmp = NumMatcher(op, n)
		return function(entry)
			return cmp(NumField(entry, key))
		end
	elseif key == "tt" or key == "tooltip" then
		return TooltipContains(value)
	elseif STR_KEYS[key] then
		return function(entry)
			local s = StrField(entry, key)
			return s ~= nil and sfind(slower(s), value, 1, true) ~= nil
		end
	end
	return nil
end

local function NameContains(needle)
	return function(entry)
		local idx = entry.searchIndex
		if idx and sfind(idx, needle, 1, true) then
			return true
		end
		local n = entry.name
		if not n then
			return false
		end
		return sfind(slower(n), needle, 1, true) ~= nil
	end
end

local function BuildToken(token)
	local negate = false
	if ssub(token, 1, 1) == "!" then
		negate = true
		token = ssub(token, 2)
	end
	if token == "" then
		return nil
	end

	local matcher
	local key, op, value = SplitOp(token)
	if key then
		matcher = BuildField(key, op, value)
	end
	if not matcher then
		matcher = FLAGS[token] or NameContains(token)
	end

	if negate then
		return function(entry)
			return not matcher(entry)
		end
	end
	return matcher
end

-- A group is the AND of its tokens.
local function CompileGroup(groupStr)
	local matchers = {}
	for tok in gmatch(groupStr, "%S+") do
		local m = BuildToken(tok)
		if m then
			matchers[#matchers + 1] = m
		end
	end
	local count = #matchers
	if count == 0 then
		return nil
	end
	if count == 1 then
		return matchers[1]
	end
	return function(entry)
		for i = 1, count do
			if not matchers[i](entry) then
				return false
			end
		end
		return true
	end
end

-- A query is the OR of its groups. Empty / all-invalid compiles to "never".
local function Compile(query)
	query = slower(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if query == "" then
		return false
	end

	local groups = {}
	for grp in gmatch(query .. "|", "([^|]*)|") do
		local g = CompileGroup(grp)
		if g then
			groups[#groups + 1] = g
		end
	end

	local count = #groups
	if count == 0 then
		return false
	end
	if count == 1 then
		return groups[1]
	end
	return function(entry)
		for i = 1, count do
			if groups[i](entry) then
				return true
			end
		end
		return false
	end
end

-- ---------------------------------------------------------------------------
-- Public API (compiled-predicate cache; cleared when a saved search changes)
-- ---------------------------------------------------------------------------
-- Cache value `false` means "compiled to a never-match predicate" (distinct
-- from nil = "not compiled yet"), so an empty/garbage query is only parsed once.
local cache = {}

local function GetPredicate(query)
	local pred = cache[query]
	if pred == nil then
		pred = Compile(query)
		cache[query] = pred
	end
	return pred
end

--- True when `entry` satisfies `query`. Safe on an empty/invalid query (false).
function Search.Match(query, entry)
	local pred = GetPredicate(query)
	return type(pred) == "function" and pred(entry) or false
end

--- True when `query` parses to at least one usable rule (for UI validation).
function Search.IsValid(query)
	return type(GetPredicate(query)) == "function"
end

--- Drop the compiled cache (call after a saved search is edited/removed).
function Search.Invalidate()
	wipe(cache)
end

--- Drop cached bag-item tooltip text (call on bag membership changes).
function Search.InvalidateTooltips()
	wipe(tooltipCache)
end

--- Pre-build a lowercase search blob on each entry at scan time (name, category,
--- type, bind, ilvl) so bareword saved-search tokens avoid re-querying fields.
function Search.IndexEntry(entry)
	if not entry then
		return
	end
	local parts = {}
	local function add(s)
		if s then
			parts[#parts + 1] = slower(s)
		end
	end
	add(entry.name)
	add(entry.category)
	add(entry.itemType)
	add(entry.itemSubType)
	add(entry.bindLabel)
	add(entry.itemEquipLoc)
	local ilvl = entry.ilvl
	if ilvl then
		parts[#parts + 1] = tostring(ilvl)
	end
	entry.searchIndex = #parts > 0 and tconcat(parts, "\0") or nil
end
