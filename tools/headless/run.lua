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

-- 14. profiler: probes install and restore, self time never exceeds total, errors pass through
do
	local Profiler = ns.Profiler
	check("profiler loaded", Profiler ~= nil)
	local meta = getmetatable(scanner).__index
	local origBuild, origRun = meta._Build, meta.Run
	local frame = BagforgeEventFrame
	local origOnEvent = frame:GetScript("OnEvent")

	Profiler:Start()
	check("start installs the scan probes", meta._Build ~= origBuild and meta.Run ~= origRun)
	check("event dispatcher is wrapped", frame:GetScript("OnEvent") ~= origOnEvent)
	check("profiler reports active", Profiler:IsActive() == true)

	Items:Scan()
	env.flushTimers()
	fire("BAG_UPDATE", 0)
	fire("BAG_UPDATE_DELAYED")
	env.flushTimers()
	local rows = Profiler:Report(true)
	local byLabel = {}
	for i = 1, #rows do
		byLabel[rows[i].label] = rows[i]
	end
	check("Scan:Run recorded", byLabel["Scan:Run"] and byLabel["Scan:Run"].calls >= 1)
	check("_Build recorded under Run", byLabel["Scan:_Build"] and byLabel["Scan:_Build"].calls >= 1)
	check("event probe recorded", byLabel["event:BAG_UPDATE"] and byLabel["event:BAG_UPDATE"].calls == 1)
	local sane = true
	for i = 1, #rows do
		if rows[i].selfMs > rows[i].totalMs + 1e-6 or rows[i].selfMs < 0 then
			sane = false
		end
	end
	check("self time never exceeds total time", sane)
	check("parent self time excludes the child", byLabel["Scan:Run"].selfMs <= byLabel["Scan:Run"].totalMs)

	Profiler:Stop(true)
	check("stop restores scan methods", meta._Build == origBuild and meta.Run == origRun)
	check("stop restores the event script", frame:GetScript("OnEvent") == origOnEvent)
	check("profiler reports stopped", Profiler:IsActive() == false)
	check("report persisted for after /reload", BagforgeDB.profile and #BagforgeDB.profile.probes > 0)

	-- a wrapper must pass values and errors through untouched, and a throw must
	-- not leave the call stack depth stuck
	local target = {
		add = function(a, b) return a + b, "ok" end,
		boom = function() error("kaboom", 0) end,
	}
	Profiler:Start()
	Profiler:Track(target, "add", "t.add")
	Profiler:Track(target, "boom", "t.boom")
	local sum, tag = target.add(2, 3)
	check("wrapper returns every value", sum == 5 and tag == "ok")
	local ok, err = pcall(target.boom)
	check("wrapper lets errors through", ok == false and err == "kaboom", err)
	Profiler:Stop(true)
	check("track restores the original", target.add ~= nil and select(1, target.add(1, 1)) == 2)

	-- Track must refuse a non-function and a double install
	Profiler:Start()
	check("track skips non-functions", Profiler:Track(target, "missing", "x") == false)
	check("track refuses to wrap twice", Profiler:Track(target, "add", "t.add") == true and Profiler:Track(target, "add", "t.add") == false)
	Profiler:Stop(true)

	-- read-only reporters must not throw with the API absent or stubbed
	check("native reader reports a missing API", select(1, Profiler:ReadNative()) == nil or true)
	C_AddOnProfiler = {
		GetAddOnMetric = function(name, metric) return name == "Bagforge" and metric + 0.5 or 0 end,
		GetOverallMetric = function(metric) return metric + 1 end,
		GetTopKAddOnsForMetric = function() return { { addOnName = "Bagforge", metricValue = 1.5 } } end,
		IsEnabled = function() return true end,
	}
	Enum.AddOnProfilerMetric = { SessionAverageTime = 0, RecentAverageTime = 1, PeakTime = 4, CountTimeOver1Ms = 5, CountTimeOver5Ms = 6, CountTimeOver10Ms = 7, CountTimeOver50Ms = 8, CountTimeOver100Ms = 9 }
	local native = Profiler:ReadNative()
	check("native reader returns metrics", native and native.addon.PeakTime == 4.5 and native.overall.PeakTime == 5, native and native.addon.PeakTime)
	check("native reader returns top addons", native and #native.top == 1 and native.top[1].name == "Bagforge")
	check("native reader flags a live API", native and native.allZero == false)
	Profiler:PrintNative()
	Profiler:PrintSources()
	Profiler:Memory(false)
	check("memory snapshot stored", BagforgeDB.profile.memory ~= nil)

	-- engine MeasureCall path: exact bytes, values pass through, stack kept for slow calls
	local measured = 0
	C_AddOnProfiler.MeasureCall = function(fn, ...)
		measured = measured + 1
		return { elapsedMilliseconds = 2, elapsedTicks = 2, allocatedBytes = 2048, deallocatedBytes = 1024 }, fn(...)
	end
	local nt = { add = function(a, b) return a + b, "ok" end }
	Profiler:Start()
	Profiler:Track(nt, "add", "n.add")
	local nsum, ntag = nt.add(4, 5)
	check("native path returns every value", nsum == 9 and ntag == "ok")
	check("native path measured through MeasureCall", measured >= 1)
	local nrows = Profiler:Report(true)
	local nrow
	for i = 1, #nrows do
		if nrows[i].label == "n.add" then
			nrow = nrows[i]
		end
	end
	check("native path records engine time", nrow and nrow.totalMs == 2 and nrow.calls == 1)
	check("native path records kept bytes", nrow and nrow.allocKB == 2 and nrow.retainedKB == 1, nrow and nrow.retainedKB)
	Profiler:Stop(true)
	C_AddOnProfiler.MeasureCall = nil
	Profiler:PrintStack("n.add")

	-- bench leaves the scanner consistent and stores results
	local before = #scanner.slots
	Profiler:Bench(3)
	env.flushTimers()
	check("bench keeps the slot count", #scanner.slots == before, #scanner.slots)
	check("bench stored results", BagforgeDB.profile.bench and #BagforgeDB.profile.bench.results >= 2)
	Profiler:HandleCommand("help")
	Profiler:HandleCommand("bogus")
	check("profiler command handler survives junk input", true)
end

-- 15. profiler window: sort and filter are pure, the window opens and refreshes
do
	local UI = ns.ProfilerUI
	check("profiler window loaded", UI ~= nil)
	local rows = {
		{ label = "b", selfMs = 2, retainedKB = nil },
		{ label = "a", selfMs = 5, retainedKB = 3 },
		{ label = "c", selfMs = 2, retainedKB = 9 },
	}
	UI.SortRows(rows, "selfMs", true)
	check("sort by number, biggest first, ties by name", rows[1].label == "a" and rows[2].label == "b" and rows[3].label == "c")
	UI.SortRows(rows, "label", false)
	check("sort by name, A to Z", rows[1].label == "a" and rows[3].label == "c")
	UI.SortRows(rows, "retainedKB", true)
	check("missing values sort last", rows[1].label == "c" and rows[3].label == "b", rows[3].label)
	UI.SortRows(rows, "retainedKB", false)
	check("missing values sort last ascending too", rows[3].label == "b", rows[3].label)
	check("filter matches a substring", #UI.FilterRows(rows, "b") == 1 and #UI.FilterRows(rows, "") == 3)
	check("number formats", UI.FormatValue("ms", 0.5) == "0.500" and UI.FormatValue("kb", nil) == "-" and UI.FormatValue("int", 7) == "7")

	ns.Profiler:Start()
	Items:Scan()
	env.flushTimers()
	local ok, err = pcall(function()
		ns.Profiler:HandleCommand("")
		UI:Refresh()
		ns.Profiler:HandleCommand("window")
		ns.Profiler:HandleCommand("")
		UI:Refresh()
	end)
	check("window opens, refreshes and toggles without throwing", ok, err)
	ns.Profiler:Stop(true)
	check("window refresh after stop", pcall(function() UI:Open() UI:Refresh() end))
end

-- 16. unbound items must not build a tooltip every time they are classified
do
	local fetches = 0
	-- Categories and ItemInfo cached the table at load, so patch it in place.
	C_TooltipInfo.GetBagItem = function()
		fetches = fetches + 1
		return { lines = { {}, { type = Enum.TooltipDataLineType.ItemBinding, bonding = 0 } } }
	end
	ns.db.filters.warbound = true
	ns.F.ClearItemInfoCache()
	Items:Scan()
	env.flushTimers()
	fetches = 0
	for i = 1, #scanner.slots do
		ns:GetModule("Categories"):GetCategory(scanner.slots[i])
	end
	check("classifying resolved items builds no tooltip", fetches == 0, fetches)
	local resolved = true
	for i = 1, #scanner.slots do
		if scanner.slots[i].bindResolved ~= true then
			resolved = false
		end
	end
	check("scan marks bind info as resolved", resolved)

	-- the paint snapshots are reused, not rebuilt per call
	local a = ns.Scan.SnapshotEntryPaint and ns.Scan.SnapshotEntryPaint(scanner.slots[1])
	local b = ns.Scan.SnapshotEntryPaint and ns.Scan.SnapshotEntryPaint(scanner.slots[2])
	check("entry paint snapshot is a shared scratch table", a ~= nil and a == b)
end

-- 17. single-slot lock refresh follows the slot, without the table API when IsLocked exists
do
	Items:Scan()
	env.flushTimers()
	local entry = scanner.slotsByKey[ns.F.SlotKey(0, 3)]
	inv[0][3].locked = true
	check("lock refresh finds the slot", scanner:RefreshLock(0, 3) == true)
	check("slot reads as locked", entry.isLocked == true)
	inv[0][3].locked = false
	scanner:RefreshLock(0, 3)
	check("slot reads as unlocked again", entry.isLocked == false)
	check("unknown slot is reported, not invented", scanner:RefreshLock(0, 99) == false)
	check("F.IsSlotLocked rejects nil", ns.F.IsSlotLocked(nil, nil) == false)
	check("clearing recent flags walks occupied slots without the table API", pcall(function() ns.Recent:ClearBackpack() end))
end

-- 18. a lock change patches the button, it does not repaint it
do
	local ItemButton = ns:GetModule("ItemButton")
	local okAcquire, parent = pcall(function() return ItemButton:Acquire() end)
	check("item button acquired headless", okAcquire and parent ~= nil, parent)
	if okAcquire and parent and parent.button then
		local paints = 0
		parent.button.SetHasItem = function() paints = paints + 1 end
		-- Headless buttons are catch-all dummies, so give the paint state real tables
		-- (an absent field would otherwise read back as a dummy, not nil).
		rawset(parent, "_paintSnap", false)
		rawset(parent, "_paintStore", {})
		local entry = scanner.slotsByKey[ns.F.SlotKey(0, 3)]
		entry.isLocked = false
		parent:SetItemEntry(entry)
		check("first paint runs", paints == 1, paints)
		parent:SetItemEntry(entry)
		check("unchanged entry does not repaint", paints == 1, paints)
		entry.isLocked = true
		parent:SetItemEntry(entry)
		check("lock change does not repaint", paints == 1, paints)
		check("lock change is remembered", parent._paintSnap.isLocked == true)
		entry.isLocked = false
		parent:SetItemEntry(entry)
		check("unlock does not repaint either", paints == 1, paints)
		entry.count = (entry.count or 1) + 1
		parent:SetItemEntry(entry)
		check("a real change still repaints", paints == 2, paints)
		entry.count = entry.count - 1

		-- clearing a button about to be pooled must not refresh context or cooldown
		local ctx, cd = 0, 0
		parent.button.UpdateItemContextMatching = function() ctx = ctx + 1 end
		parent.button.UpdateCooldown = function() cd = cd + 1 end
		parent:ClearItem()
		check("clear skips the context and cooldown refresh", ctx == 0 and cd == 0, ctx .. "," .. cd)
		parent:SetItemEntry(entry)
		check("repaint after clear still refreshes both", ctx == 1 and cd == 1, ctx .. "," .. cd)
	end
end

-- 19. bank session: item context refresh is coalesced, the panel type is set once and before Show
do
	local Session = ns.BankSession
	local triggers = 0
	ItemButtonUtil.TriggerEvent = function() triggers = triggers + 1 end
	ItemButtonUtil.Event = { ItemContextChanged = 1 }
	for _ = 1, 5 do
		Session:RefreshItemContext()
	end
	check("item context waits for the trailing pass", triggers == 0, triggers)
	env.flushTimers()
	check("five refresh requests run one pass", triggers == 1, triggers)
	Session:RefreshItemContext()
	env.flushTimers()
	check("a later request runs again", triggers == 2, triggers)

	local log, activeType = {}, nil
	local panel = BankPanel
	panel.SetAlpha, panel.EnableMouse, panel.EnableKeyboard = function() end, function() end, function() end
	panel.AutoDepositFrame, panel.Header = nil, nil
	panel.SetBankType = function(_, t) activeType = t log[#log + 1] = "type" end
	panel.GetActiveBankType = function() return activeType end
	panel.Show = function() log[#log + 1] = "show" end
	local view = { bankType = 2 }
	Session:EnsureBankPanel(view)
	check("type is set before the panel is shown", log[1] == "type" and log[2] == "show", table.concat(log, ","))
	Session:EnsureBankPanel(view)
	check("same type is not set again", #log == 3 and log[3] == "show", table.concat(log, ","))
	view.bankType = 3
	Session:EnsureBankPanel(view)
	check("a different type is set", log[4] == "type" and activeType == 3, table.concat(log, ","))
end

-- 20. IsSlotLocked must survive C_Item.IsLocked raising on an empty slot
do
	local origIsLocked, origExists = C_Item.IsLocked, C_Item.DoesItemExist
	C_Item.IsLocked = function() error("Usage: local isLocked = C_Item.IsLocked(itemLocation)", 0) end

	C_Item.DoesItemExist = function() return false end
	local ok, locked = pcall(ns.F.IsSlotLocked, 0, 99)
	check("empty slot reads unlocked, no throw", ok and locked == false, locked)

	-- the client says the item exists but IsLocked still raises: fall back to the table API
	C_Item.DoesItemExist = function() return true end
	inv[0][3].locked = true
	ok, locked = pcall(ns.F.IsSlotLocked, 0, 3)
	check("a refused location falls back to the table API", ok and locked == true, locked)
	inv[0][3].locked = false

	C_Item.IsLocked, C_Item.DoesItemExist = origIsLocked, origExists
end

-- 21. item level reads C_Item.GetCurrentItemLevel on a shared location
do
	local info = ns:GetModule("ItemInfo")
	local origLevel, origExists = C_Item.GetCurrentItemLevel, C_Item.DoesItemExist
	local asked = 0
	C_Item.GetCurrentItemLevel = function() asked = asked + 1 return 321 end
	C_Item.DoesItemExist = function() return true end
	local entry = { bag = 0, slot = 4, itemID = 102, classID = 4, hyperlink = "|cff|Hitem:102::::::::999|h[Probe Helm]|h|r" }
	check("ilvl comes from C_Item.GetCurrentItemLevel", info:GetItemLevel(entry) == 321 and asked == 1, asked)
	check("ilvl is cached per link", info:GetItemLevel(entry) == 321 and asked == 1, asked)
	C_Item.DoesItemExist = function() return false end
	local gone = { bag = 0, slot = 4, itemID = 102, classID = 4, hyperlink = "|cff|Hitem:102::::::::1000|h[Gone]|h|r" }
	local ok = pcall(info.GetItemLevel, info, gone)
	check("an empty slot does not throw", ok)
	C_Item.GetCurrentItemLevel, C_Item.DoesItemExist = origLevel, origExists
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
