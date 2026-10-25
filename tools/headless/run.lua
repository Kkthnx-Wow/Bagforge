-- Headless Bagforge smoke and regression tests (Lua 5.1, no game client).
-- Usage: lua5.1 run.lua <path to the Bagforge addon folder>
-- wowenv.lua stubs the WoW API, this file fakes the bag contents and asserts on the scanner.
local addonDir = assert(arg[1], "addon dir")
package.path = arg[0]:gsub("run%.lua$", "") .. "?.lua;" .. package.path
local env = require("wowenv").install()
BagforgeDB = {}
BagforgeCharDB = {}

-- ---------------------------------------------------------------- fake bags
local inv = {} -- inv[bag][slot] = item
local sizes = { [0] = 16, [1] = 8, [2] = 8, [3] = 0, [4] = 0, [5] = 6 }
local items = {
	[100] = { name = "Linen Cloth", quality = 1, class = 7, sub = 5, stack = 200, price = 10 },
	[101] = { name = "Rusty Sword", quality = 0, class = 2, sub = 7, stack = 1, price = 5, equip = "INVTYPE_WEAPON" },
	[102] = { name = "Epic Helm", quality = 4, class = 4, sub = 1, stack = 1, price = 500, equip = "INVTYPE_HEAD" },
	[103] = { name = "Healing Potion", quality = 1, class = 0, sub = 1, stack = 20, price = 30 },
	[104] = { name = "Mystery Herb", quality = 1, class = 7, sub = 9, stack = 200, price = 2 },
	[106] = { name = "Plain Rock", quality = 1, class = 15, sub = 4, stack = 20, price = 1 },
	[105] = { name = "Fancy Ring", quality = 3, class = 4, sub = 0, stack = 1, price = 90, equip = "INVTYPE_FINGER" },
}
local function link(id, variant)
	return ("|cff1eff00|Hitem:%d::::::::80:::::%s|h[%s]|h|r"):format(id, variant or "", items[id].name)
end
local function put(bag, slot, id, count, variant)
	inv[bag] = inv[bag] or {}
	inv[bag][slot] = id and { itemID = id, count = count or 1, link = link(id, variant) } or nil
end

C_Container = {
	GetContainerNumSlots = function(bag)
		return sizes[bag] or 0
	end,
	GetContainerItemID = function(bag, slot)
		local it = inv[bag] and inv[bag][slot]
		return it and it.itemID
	end,
	GetContainerItemLink = function(bag, slot)
		local it = inv[bag] and inv[bag][slot]
		return it and it.link
	end,
	GetContainerItemInfo = function(bag, slot)
		local it = inv[bag] and inv[bag][slot]
		if not it then
			return nil
		end
		local d = items[it.itemID]
		return {
			itemID = it.itemID,
			stackCount = it.count,
			hyperlink = it.link,
			quality = d.quality,
			iconFileID = 1000 + it.itemID,
			isLocked = it.locked or false,
			isBound = false,
			hasNoValue = false,
			isReadable = false,
			isFiltered = false,
		}
	end,
	GetContainerNumFreeSlots = function(bag)
		local n = 0
		for s = 1, sizes[bag] or 0 do
			if not (inv[bag] and inv[bag][s]) then
				n = n + 1
			end
		end
		return n, 0
	end,
	GetContainerItemQuestInfo = function()
		return { isQuestItem = false, questID = nil, isActive = false }
	end,
	GetContainerItemEquipmentSetInfo = function()
		return false
	end,
	PickupContainerItem = function() end,
	ContainerIDToInventoryID = function(bag) return 30 + bag end,
	GetBagSlotFlag = function()
		return false
	end,
	GetBackpackSellJunkDisabled = function()
		return false
	end,
}
local function idOf(x)
	return type(x) == "string" and tonumber(x:match("item:(%d+)")) or x
end
C_Item = {
	GetItemInfo = function(id)
		id = idOf(id)
		local d = items[id]
		if not d then
			return nil
		end
		return d.name, link(id), d.quality, 50, 1, "Type", "Sub", d.stack, d.equip or "", 1000 + id, d.price, d.class, d.sub, 0, 10, nil, false, "desc"
	end,
	GetItemInfoInstant = function(id)
		id = idOf(id)
		local d = items[id]
		if not d then
			return nil
		end
		return id, "Type", "Sub", d.equip or "", 1000 + id, d.class, d.sub
	end,
	IsItemDataCachedByID = function()
		return true
	end,
	RequestLoadItemDataByID = function() end,
	GetItemInventoryTypeByID = function(id)
		return items[id] and items[id].equip and 1 or 0
	end,
	GetItemMaxStackSizeByID = function(id)
		return items[id] and items[id].stack
	end,
	GetItemQualityByID = function()
		return 1
	end,
	IsAnimaItemByID = function()
		return false
	end,
	IsDecorItem = function()
		return false
	end,
	IsEquippableItem = function(id)
		id = idOf(id)
		return items[id] and items[id].equip ~= nil
	end,
	GetItemFamily = function()
		return 0
	end,
	DoesItemExist = function()
		return false
	end,
}
C_ToyBox = {
	GetToyInfo = function()
		return nil
	end,
}
C_NewItems = {
	IsNewItem = function()
		return false
	end,
	RemoveNewItem = function() end,
}
C_TooltipInfo = {
	GetBagItem = function()
		return nil
	end,
	GetItemByID = function()
		return nil
	end,
}
ItemLocation = {
	CreateEmpty = function()
		return { SetBagAndSlot = function() end }
	end,
	CreateFromBagAndSlot = function()
		return {}
	end,
}

-- ---------------------------------------------------------------- load addon
local ns = {}
local function load(rel)
	local path = addonDir .. "/" .. rel:gsub("\\", "/")
	local chunk, err = loadfile(path)
	assert(chunk, err)
	local ok, e = pcall(chunk, "Bagforge", ns)
	if not ok then
		error("load " .. rel .. ": " .. tostring(e), 0)
	end
end
for line in io.lines(addonDir .. "/Bagforge.toc") do
	line = line:gsub("\r", "")
	if line:match("%.lua$") and not line:match("^#") then
		load(line)
	end
end

local function fire(event, ...)
	local f = _G.BagforgeEventFrame
	f.__scripts.OnEvent(f, event, ...)
end
fire("ADDON_LOADED", "Bagforge")
fire("PLAYER_LOGIN")
env.flushTimers()

-- ---------------------------------------------------------------- test kit
local passed, failed = 0, 0
local function check(name, cond, extra)
	if cond then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL: " .. name .. (extra ~= nil and (" -> " .. tostring(extra)) or ""))
	end
end
local function secs(scanner)
	local out = {}
	for i = 1, #scanner.sections do
		out[scanner.sections[i].name] = #scanner.sections[i].items
	end
	return out
end

local Items = ns:GetModule("Items")
local scanner = Items.scanner
local L = ns.L

-- 1. initial scan
put(0, 1, 100, 50)
put(0, 2, 100, 30)
put(0, 3, 101)
put(0, 4, 102)
put(0, 5, 103, 5)
put(0, 6, 104, 10)
put(0, 7, 105)
Items:Scan()
env.flushTimers()
local s = secs(scanner)
check("initial slot count", #scanner.slots == 7, #scanner.slots)
check("junk category", s[L["Junk"]] == 1, tostring(s[L["Junk"]]))
check("equipment category", s[L["Equipment"]] == 2, tostring(s[L["Equipment"]]))
check("free slot tally uses client counts", scanner.freeSlots == (16 + 8 + 8 + 6) - 7, scanner.freeSlots)

-- 2. incremental diff: new item in an empty slot
put(1, 1, 103, 3)
local keys = ns.Scan.CollectDirtySlotKeys(scanner, ns.C.BACKPACK_BAGS, { [1] = true }, {})
check("dirty key found for added item", keys and keys[ns.F.SlotKey(1, 1)], keys)
Items:Scan({ [1] = true }, keys)
env.flushTimers()
check("incremental add -> 8 slots", #scanner.slots == 8, #scanner.slots)
check("changeset flagged added", #scanner.lastChangeset.added == 1)

-- 3. same itemID, different instance (link) must be detected
put(0, 5, 103, 5, "999")
keys = ns.Scan.CollectDirtySlotKeys(scanner, ns.C.BACKPACK_BAGS, { [0] = true }, {})
check("swapped instance (same itemID) detected", keys ~= nil and keys[ns.F.SlotKey(0, 5)], keys)
put(0, 5, 103, 5) -- restore
Items:Scan()
env.flushTimers()

-- 4. unchanged non-stackable slot is not reported
keys = ns.Scan.CollectDirtySlotKeys(scanner, ns.C.BACKPACK_BAGS, { [0] = true }, {})
check("no false positives on quiet bag", keys == nil, keys and next(keys))

-- 5. stack merge + stale _mergedSlots on pooled reuse
ns.db.organize.stackMerge = true
Items:Scan()
env.flushTimers()
local mergedRoot
for i = 1, #scanner.slots do
	if scanner.slots[i].itemID == 100 then
		mergedRoot = scanner.slots[i]
	end
end
check("stacks merged", mergedRoot and mergedRoot.count == 80 and mergedRoot._mergedSlots and #mergedRoot._mergedSlots == 2)
ns.db.organize.stackMerge = false
Items:Scan()
env.flushTimers()
local stale = false
for i = 1, #scanner.slots do
	if scanner.slots[i]._mergedSlots then
		stale = true
	end
end
check("merge off clears _mergedSlots on reused entries", not stale)

-- 6. SafeCompare no longer hits a nil global
do
	local fn
	for i = 1, 80 do
		local name, val = debug.getupvalue(getmetatable(scanner).RefreshSortOrder, i)
		if not name then
			break
		end
		if name == "SafeCompare" then
			fn = val
		end
	end
	check("SafeCompare reachable", fn ~= nil)
	if fn then
		local a = { categoryOrder = 1, category = "x", bag = 0, slot = 1 }
		local b = { categoryOrder = 1, category = "x", bag = 0, slot = 2 }
		local ok, res = pcall(fn, a, b)
		check("SafeCompare tiebreak without itemID", ok and res == true, res)
	end
end

-- 7. pooled entry must not leak the previous item's search blob into classification
do
	local o = ns.db.organize
	o.searches["Herbs"] = { enabled = true, query = "herb" }
	ns.Search.Invalidate()
	ns:GetModule("Categories"):InvalidateSearchCache()
	Items:Scan()
	env.flushTimers()
	local herbs = {}
	for i = 1, #scanner.slots do
		local e = scanner.slots[i]
		if e.category == "Herbs" then
			herbs[#herbs + 1] = e.name
		end
	end
	check("bareword search matches only the herb", #herbs == 1 and herbs[1] == "Mystery Herb", table.concat(herbs, ","))
	put(0, 6, 100, 10)
	put(0, 1, 104, 10)
	Items:Scan()
	env.flushTimers()
	herbs = {}
	for i = 1, #scanner.slots do
		local e = scanner.slots[i]
		if e.category == "Herbs" then
			herbs[#herbs + 1] = e.name .. "@" .. e.slot
		end
	end
	check("after reshuffle still exactly one herb at slot 1", #herbs == 1 and herbs[1] == "Mystery Herb@1", table.concat(herbs, ","))
	-- a never-before-seen item lands on the pooled entry that last held the herb
	put(0, 1, 100, 10)
	put(0, 6, 106)
	Items:Scan()
	env.flushTimers()
	herbs = {}
	for i = 1, #scanner.slots do
		local e = scanner.slots[i]
		if e.category == "Herbs" then
			herbs[#herbs + 1] = e.name .. "@" .. e.slot
		end
	end
	check("new item on a recycled entry is not pulled into the herb search", #herbs == 0, table.concat(herbs, ","))
	o.searches["Herbs"] = nil
	ns.Search.Invalidate()
	ns:GetModule("Categories"):InvalidateSearchCache()
end

-- 8. BucketEvent keeps per-bucket args
do
	local gotA, gotB
	ns.F.BucketEvent("EVENT_A", 0.1, function(...)
		gotA = { ... }
	end)
	ns.F.BucketEvent("EVENT_B", 0.1, function(...)
		gotB = { ... }
	end)
	fire("EVENT_A", "a1", "a2")
	fire("EVENT_B", "b1")
	env.flushTimers()
	check("bucket A args intact", gotA and gotA[2] == "a1" and gotA[3] == "a2", gotA and gotA[2])
	check("bucket B args intact", gotB and gotB[2] == "b1" and gotB[3] == nil, gotB and gotB[2])
end

-- 9. sort gate survives a throwing flush part
do
	ns._bagSortActive = nil
	check("BeginBagSort", ns:BeginBagSort())
	ns:ScheduleBagSortFlush("boom", function()
		error("boom")
	end)
	local handlerCalls = 0
	local old = geterrorhandler
	_G.geterrorhandler = function()
		return function()
			handlerCalls = handlerCalls + 1
		end
	end
	local okFlush = pcall(env.flushTimers)
	_G.geterrorhandler = old
	check("sort flush did not throw out of the timer", okFlush)
	check("sort gate released after error", ns._bagSortActive == false and ns._wasSortFlush == nil, tostring(ns._bagSortActive))
	check("error reported once", handlerCalls == 1, handlerCalls)
end

-- 10. slash aliases do not recurse
do
	local ok, err = pcall(SlashCmdList["BAGFORGE"], "resetwarbank")
	check("/bf resetwarbank runs", ok, err)
	ok, err = pcall(SlashCmdList["BAGFORGE"], "warbankreset")
	check("/bf warbankreset runs", ok, err)
end

-- 11. item record cache hands back the same table, invalidation refreshes
do
	local a = ns.F.GetItemInfoRecord(100)
	local b = ns.F.GetItemInfoRecord(100)
	check("record cached by itemID", a == b)
	ns.F.InvalidateItemInfo(100)
	check("record rebuilt after invalidate", ns.F.GetItemInfoRecord(100) ~= a)
	local l1 = ns.F.GetItemInfoRecord(link(100))
	check("link lookups bypass the cache", l1 ~= ns.F.GetItemInfoRecord(link(100)))
end

-- 12. dirty bag flush smoke (no window open)
do
	fire("BAG_UPDATE", 0)
	fire("BAG_UPDATE_DELAYED")
	env.flushTimers()
	check("bag update flush does not throw", true)
end

-- 13. auto sell honours the per-bag "ignore junk selling" switches
do
	local sold = {}
	C_Container.UseContainerItem = function(bag, slot)
		sold[#sold + 1] = bag .. ":" .. slot
	end
	local flagged = {}
	C_Container.GetBagSlotFlag = function(bag)
		return flagged[bag] or false
	end
	local backpackOff = false
	C_Container.GetBackpackSellJunkDisabled = function()
		return backpackOff
	end
	put(1, 2, 101) -- grey sword in bag 1 (backpack slot 3 already holds one)
	local vendor = ns:GetModule("Vendor")
	ns.db.vendor.autoSellJunk = true
	ns.db.vendor.autoRepair = false

	local function visit()
		wipe(sold)
		vendor:OnMerchantShow()
		env.flushTimers(60)
		table.sort(sold)
		return table.concat(sold, ",")
	end
	check("sells grey junk from every bag by default", visit() == "0:3,1:2", visit())
	backpackOff = true
	check("skips the backpack when its junk switch is off", visit() == "1:2")
	backpackOff = false
	flagged[1] = true
	check("skips a bag flagged ignore-junk", visit() == "0:3")
	flagged[1] = nil
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
