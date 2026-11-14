--[[
	Bagforge - Profiler
	-------------------------------------------------------------------------
	A profiling mode for Bagforge itself. Nothing in the shipped code paths is
	instrumented: Start() swaps timing wrappers onto the functions that matter
	and Stop() puts the originals back, so the cost while profiling is off is
	exactly zero.

	Why this and not only the client's own profiler
	  * C_AddOnProfiler (always on, no CVar) reports per-addon cost per tick. It
	    answers "how much does Bagforge cost", but not "which function". It also
	    does not attribute OnEnter, OnClick or /run work. Read through
	    /bf profile native and /bf profile sources.
	  * The legacy scriptProfile CPU counters are a CVar and a /reload away and
	    read 0 on some clients. /bf profile sources tells you which of these
	    sources actually answers on the client you are running.
	  * The probes here answer "which function, how often, how long, how many
	    bytes", with self time (children subtracted) and inclusive time.

	Usage
	  /bf profile start [seconds]  install probes, optionally stop after N seconds
	  /bf profile stop             remove probes and print the report
	  /bf profile report           print the current numbers without stopping
	  /bf profile reset            zero the counters
	  /bf profile bench [n]        fixed workloads against the live bags
	  /bf profile native           client profiler: Bagforge vs all addons
	  /bf profile mem [gc]         memory, pools and scanners (gc runs a full collect)
	  /bf profile sources          which measurement sources work on this client
	  /bf profile run [seconds]    start, bench, report in one go (out of combat)

	Everything is also written to BagforgeDB.profile so a report can be read from
	disk after /reload, the same way /bf diag does it.

	Accuracy notes
	  * debugprofilestop is a wall clock, so a frame hitch while a probe is open
	    is charged to it. Compare peaks with averages before trusting one number.
	  * alloc is the sum of positive collectgarbage("count") deltas, so it is a
	    lower bound (a GC step inside the call hides some of it).
	  * Probes only see calls made through the table, which is how every method
	    here is invoked. A local alias captured at file scope bypasses a probe.
--]]

local _, ns = ...
local F = ns.F
local format = string.format
local sort = table.sort
local wipe = wipe
local type = type
local pairs = pairs
local pcall = pcall
local rawget = rawget
local collectgarbage = collectgarbage
local debugprofilestop = debugprofilestop

local Profiler = {}
ns.Profiler = Profiler

local MAX_REPORT_ROWS = 12
local MAX_REPORT_EVENTS = 8
local SLOW_MS = 1

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local probes = {} -- label -> stats
local patched = {} -- { tbl, key, orig, wrapper }
local patchedKeys = setmetatable({}, { __mode = "k" }) -- tbl -> { key = true }
local active = false
local startedAt
local runGen = 0 -- invalidates a pending auto-stop when profiling restarts

-- Call stack bookkeeping so a probe can subtract the time spent in probes it
-- called. childMs[d] collects the inclusive time of every probe closed at d+1.
local depth = 0
local childMs = {}

local eventFrame, origOnEvent, eventWrapper

local function Print(msg)
	F.Print(msg)
end

local function GetProbe(label)
	local p = probes[label]
	if not p then
		p = { label = label, calls = 0, total = 0, self = 0, peak = 0, slow = 0, alloc = 0, freed = 0 }
		probes[label] = p
	end
	return p
end

-- ---------------------------------------------------------------------------
-- Probe wrapper
-- ---------------------------------------------------------------------------
-- Engine-side measurement. C_AddOnProfiler.MeasureCall runs a function and
-- hands back the elapsed time plus the bytes it allocated and released, which
-- is exact where the collectgarbage deltas below are only a lower bound. It is
-- picked at Start when the client has it and the profiler reports itself on;
-- otherwise the wall-clock path is used.
local measure

local function ClosePeak(p, elapsed, skipStack)
	if elapsed > p.peak then
		p.peak = elapsed
		-- Who made the slowest call so far. Only captured on a new peak that is
		-- slow enough to matter, so the cost stays off the common path.
		if elapsed >= SLOW_MS and not skipStack and debugstack then
			p.peakStack = debugstack(3, 20, 0)
		end
	end
end

local function Account(p, myDepth, elapsed, allocKB, freedKB)
	local child = childMs[myDepth] or 0
	childMs[myDepth] = nil
	depth = myDepth - 1
	if depth > 0 then
		childMs[depth] = (childMs[depth] or 0) + elapsed
	end
	local own = elapsed - child
	if own < 0 then
		own = 0
	end
	p.calls = p.calls + 1
	p.total = p.total + elapsed
	p.self = p.self + own
	ClosePeak(p, elapsed)
	if elapsed >= SLOW_MS then
		p.slow = p.slow + 1
	end
	if allocKB and allocKB > 0 then
		p.alloc = p.alloc + allocKB
	end
	if freedKB then
		p.freed = (p.freed or 0) + freedKB
	end
end

local function Finish(p, myDepth, kb0, t0, ...)
	local elapsed = debugprofilestop() - t0
	Account(p, myDepth, elapsed, collectgarbage("count") - kb0)
	return ...
end

local function FinishNative(p, myDepth, result, ...)
	if type(result) == "table" and type(result.elapsedMilliseconds) == "number" then
		Account(p, myDepth, result.elapsedMilliseconds, (result.allocatedBytes or 0) / 1024,
			(result.deallocatedBytes or 0) / 1024)
	else
		-- Unexpected shape: keep the call counted rather than lose it.
		Account(p, myDepth, 0, 0, 0)
	end
	return ...
end

local function MakeWrapper(p, orig)
	return function(...)
		if not active then
			return orig(...)
		end
		local myDepth = depth + 1
		depth = myDepth
		childMs[myDepth] = 0
		if measure then
			return FinishNative(p, myDepth, measure(orig, ...))
		end
		-- Arguments evaluate left to right, so the clock reads happen before orig.
		return Finish(p, myDepth, collectgarbage("count"), debugprofilestop(), orig(...))
	end
end

--- Put a timing wrapper on tbl[key]. Returns true when a probe was installed.
--- Public so a plugin or a future module can add its own probe point.
function Profiler:Track(tbl, key, label)
	if type(tbl) ~= "table" then
		return false
	end
	local orig = rawget(tbl, key)
	if type(orig) ~= "function" then
		return false
	end
	local keys = patchedKeys[tbl]
	if keys and keys[key] then
		return false
	end
	local wrapper = MakeWrapper(GetProbe(label or key), orig)
	tbl[key] = wrapper
	patched[#patched + 1] = { tbl, key, orig, wrapper }
	if not keys then
		keys = {}
		patchedKeys[tbl] = keys
	end
	keys[key] = true
	return true
end

local function TrackGroup(tbl, prefix, keys)
	local n = 0
	if type(tbl) ~= "table" then
		return 0
	end
	for i = 1, #keys do
		if Profiler:Track(tbl, keys[i], prefix .. keys[i]) then
			n = n + 1
		end
	end
	return n
end

-- ---------------------------------------------------------------------------
-- Targets
--   One list, resolved at Start. A target that does not exist on this build
--   (a module that is off, a window that was never opened) is skipped quietly
--   and shows up as a lower count in the Start message.
-- ---------------------------------------------------------------------------
local function ScanMethods()
	if not (ns.Scan and ns.Scan.New) then
		return nil
	end
	local meta = getmetatable(ns.Scan.New())
	return meta and meta.__index
end

-- Blizzard's own item button methods, called from our paint and clear paths.
-- Opt-in ("start deep") because it wraps them on every pooled button.
local BLIZZARD_BUTTON_METHODS = {
	"SetHasItem", "UpdateExtended", "UpdateQuestItem", "UpdateNewItem", "UpdateItemContextMatching",
	"SetMatchesSearch", "UpdateCooldown", "SetReadable", "UpdateJunkItem",
}

local function InstallTargets(deep)
	local n = 0

	n = n + TrackGroup(ScanMethods(), "Scan:", {
		"Run", "_Build", "_BuildSlotDiff", "_FinalizeBuild", "_MergeStacks", "_BuildSections",
		"RefreshAfterSort", "RefreshDisplayFields", "RefreshLocks", "PatchSlot",
	})
	n = n + TrackGroup(ns.Scan, "Scan.", {
		"RefreshDisplayFieldsAll", "RefreshUnusableAll", "ClearItemCaches", "CollectDirtySlotKeys",
	})
	n = n + TrackGroup(ns, "ns:", {
		"RefreshBags", "ApplyScannerRefresh", "ReclassifyBags", "ResortBags", "UIRefresh",
		"RefreshRecentFlags", "RefreshItemCategory", "BeginBagSort", "ScheduleBagSortFlush", "TriggerCallback",
	})
	n = n + TrackGroup(ns.CombineStacks, "CombineStacks.", { "Run", "RunThen" })
	n = n + TrackGroup(ns:GetModule("Items"), "Items:", { "Scan", "ScanAfterSort", "Sort" })
	n = n + TrackGroup(ns:GetModule("ItemInfo"), "ItemInfo:", {
		"IsUnusable", "GetItemLevel", "GetBindLabel", "Apply",
	})
	n = n + TrackGroup(ns:GetModule("Categories"), "Categories:", { "GetCategory", "GetOrder" })
	n = n + TrackGroup(ns.Search, "Search.", { "Match", "IndexEntry", "Invalidate", "InvalidateTooltips" })
	n = n + TrackGroup(ns.Recent, "Recent:", { "Scan", "ClearBackpack", "ClearAll" })
	n = n + TrackGroup(ns:GetModule("Bank"), "Bank:", {
		"OpenBanking", "CloseAll", "ShowView", "PickView", "EnsureBankPanel", "RefreshItemContext",
		"RefreshQuestState", "RefreshTabBars", "RefreshSlotLock",
	})
	n = n + TrackGroup(ns.BankSession, "BankSession:", {
		"EnsureBankPanel", "RefreshItemContext", "CloseAll", "SuppressBlizzardBankFrame", "RestoreBlizzardBankFrame",
	})

	n = n + TrackGroup(ns.Container, "Container.", { "StackCategories", "GridWidth" })
	n = n + TrackGroup(ns.Container and ns.Container.Methods, "Container:", {
		"Layout", "_AdvanceLayoutBatch", "PatchDisplayEntries", "PatchEntry", "RefreshHeader",
		"ReleaseButtons", "SetItemGridsHidden", "Reset",
	})

	local windowKeys = {
		"Draw", "DrawCategorized", "PatchChangedEntries", "InvalidateItemLayouts",
		"RefreshCategoryHeaders", "RefreshIfOpen", "Open", "UpdateCurrencyBar", "UpdateMoneyFrame",
		"LayoutFooter", "Close", "DrawLayout", "UpdateChrome", "ApplyTabBarState", "UpdateBankFooter",
		"ConfigureSecureBankButtons", "EnsureShellSize", "RefreshFiltered",
	}
	n = n + TrackGroup(ns:GetModule("Backpack"), "Backpack:", windowKeys)
	n = n + TrackGroup(ns.BankView and ns.BankView.View, "BankView:", windowKeys)

	local itemButton = ns:GetModule("ItemButton")
	n = n + TrackGroup(itemButton, "ItemButton:", {
		"RefreshSlot", "RefreshItemID", "RefreshLock", "RefreshQuests", "RefreshCooldowns",
		"Acquire", "ReleaseAll", "ApplyOverlayLayout", "UpdateCornerWidgets", "InvalidatePaint",
	})
	-- The paint methods live on each pooled button, not on a shared table. Buttons
	-- created after Start are not covered, which is why the pool is pre-warmed.
	local pool = itemButton and itemButton.pool
	if pool and pool.objects then
		for i = 1, #pool.objects do
			local button = pool.objects[i]
			if Profiler:Track(button, "SetItemEntry", "ItemButton.SetItemEntry") then
				n = n + 1
			end
			if Profiler:Track(button, "ClearItem", "ItemButton.ClearItem") then
				n = n + 1
			end
			if deep then
				n = n + TrackGroup(button.button, "Blizzard:", BLIZZARD_BUTTON_METHODS)
			end
		end
	end

	return n
end

--- Time every game event the shared dispatcher hands out, per event name.
local function InstallEventProbe()
	eventFrame = _G.BagforgeEventFrame
	if not (eventFrame and eventFrame.GetScript) then
		return false
	end
	origOnEvent = eventFrame:GetScript("OnEvent")
	if type(origOnEvent) ~= "function" then
		origOnEvent = nil
		return false
	end
	local orig = origOnEvent
	eventWrapper = function(self, event, ...)
		if not active then
			return orig(self, event, ...)
		end
		-- An event can fire from inside a probed call (ITEM_LOCK_CHANGED arrives
		-- during C_Container.SortBags), so it nests like any other probe. Forcing
		-- depth to 1 here used to wipe the outer probe's child time.
		local myDepth = depth + 1
		depth = myDepth
		childMs[myDepth] = 0
		local p = GetProbe("event:" .. event)
		if measure then
			return FinishNative(p, myDepth, measure(orig, self, event, ...))
		end
		return Finish(p, myDepth, collectgarbage("count"), debugprofilestop(), orig(self, event, ...))
	end
	eventFrame:SetScript("OnEvent", eventWrapper)
	return true
end

local function RemoveEventProbe()
	if eventFrame and eventWrapper and eventFrame:GetScript("OnEvent") == eventWrapper then
		eventFrame:SetScript("OnEvent", origOnEvent)
	end
	eventFrame, origOnEvent, eventWrapper = nil, nil, nil
end

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------
local function Elapsed()
	if not startedAt then
		return 0
	end
	local now = GetTimePreciseSec and GetTimePreciseSec() or GetTime()
	return now - startedAt
end

local usedNative = false -- whether the last run measured through MeasureCall

local function Snapshot()
	local rows = {}
	local seconds = math.max(Elapsed(), 0.001)
	for _, p in pairs(probes) do
		if p.calls > 0 then
			rows[#rows + 1] = {
				label = p.label,
				calls = p.calls,
				totalMs = p.total,
				selfMs = p.self,
				avgMs = p.total / p.calls,
				peakMs = p.peak,
				slow = p.slow,
				allocKB = p.alloc,
				retainedKB = usedNative and (p.alloc - (p.freed or 0)) or nil,
				callsPerSec = p.calls / seconds,
				peakStack = p.peakStack,
			}
		end
	end
	sort(rows, function(a, b)
		if a.selfMs ~= b.selfMs then
			return a.selfMs > b.selfMs
		end
		return a.label < b.label
	end)
	return rows
end

local function PrintRow(row)
	local memory = row.retainedKB and format("alloc %.0fK net %.0fK", row.allocKB, row.retainedKB)
		or format("alloc %.0fK", row.allocKB)
	Print(format("  %-34s %6d calls %6.1f/s  self %8.2f  total %8.2f  avg %6.3f  peak %7.2f  >%dms %d  %s",
		row.label, row.calls, row.callsPerSec, row.selfMs, row.totalMs, row.avgMs, row.peakMs, SLOW_MS, row.slow,
		memory))
end

--- Run `fn`, and treat a throw as a result instead of an abort.
local function Try(fn, ...)
	local ok, result = pcall(fn, ...)
	if ok then
		return result
	end
	return nil, tostring(result)
end

local store = {}
local overheadUs -- cost of one probe wrapper, measured at Start

-- Saved variables are written on every reload, so keep only the heaviest rows.
local MAX_PERSISTED_ROWS = 100

local function PersistedRows()
	local rows = store.probes
	if not rows or #rows <= MAX_PERSISTED_ROWS then
		return rows
	end
	local kept = {}
	for i = 1, MAX_PERSISTED_ROWS do
		kept[i] = rows[i]
	end
	return kept
end

local function Persist()
	local root = _G.BagforgeDB
	if not root then
		return
	end
	local _, build, _, toc = GetBuildInfo()
	root.profile = {
		version = 1,
		stamp = date and date("%Y-%m-%d %H:%M:%S") or nil,
		at = time and time() or nil,
		addonVersion = ns.version,
		build = build,
		interface = toc,
		seconds = Elapsed(),
		probeOverheadUs = overheadUs,
		engineMeasured = usedNative,
		probes = PersistedRows(),
		bench = store.bench,
		native = store.native,
		memory = store.memory,
		sources = store.sources,
	}
end

--- Live rows for the profiler window, unsorted.
function Profiler:GetRows()
	return Snapshot()
end

function Profiler:GetStatus()
	local count = 0
	for _, p in pairs(probes) do
		if p.calls > 0 then
			count = count + 1
		end
	end
	return {
		active = active,
		engine = usedNative,
		probeCount = count,
		seconds = Elapsed(),
		overheadUs = overheadUs,
	}
end

function Profiler:Report(quiet)
	local rows = Snapshot()
	local funcs, events = {}, {}
	for i = 1, #rows do
		if rows[i].label:find("^event:") then
			events[#events + 1] = rows[i]
		else
			funcs[#funcs + 1] = rows[i]
		end
	end
	store.probes = rows
	Persist()

	if quiet then
		return rows
	end
	if #rows == 0 then
		Print("Profiler: nothing recorded yet. Use /bf profile start, open and use the bags, then /bf profile report.")
		return rows
	end
	Print(format("Profiler: %d probes over %.1fs, %s, %s. Ranked by self time (ms).", #rows, Elapsed(),
		active and "running" or "stopped",
		usedNative and "engine MeasureCall (exact bytes)" or "wall clock (alloc is a lower bound)"))
	if overheadUs then
		Print(format("  Each probe adds about %.2f us per call, already inside these numbers. Very hot, very short functions read high.", overheadUs))
	end
	for i = 1, math.min(#funcs, MAX_REPORT_ROWS) do
		PrintRow(funcs[i])
	end
	if #events > 0 then
		Print("  Events:")
		for i = 1, math.min(#events, MAX_REPORT_EVENTS) do
			PrintRow(events[i])
		end
	end
	Print("Slowest call stack for a probe: /bf profile stack <name>. Full list in BagforgeDB.profile.")
	return rows
end

-- ---------------------------------------------------------------------------
-- Start / stop
-- ---------------------------------------------------------------------------
function Profiler:IsActive()
	return active
end

function Profiler:Reset()
	-- Zero the records in place. Every installed wrapper holds its own record, so
	-- emptying the map would leave them counting into tables nothing reads.
	for _, p in pairs(probes) do
		p.calls, p.total, p.self, p.peak, p.slow, p.alloc, p.freed = 0, 0, 0, 0, 0, 0, 0
		p.peakStack = nil
	end
	depth = 0
	wipe(childMs)
	startedAt = GetTimePreciseSec and GetTimePreciseSec() or GetTime()
end

--- Price one wrapper against a bare call so the report can say how much of a
--- very hot probe is the probe itself.
local function Calibrate()
	local runs = 2000
	local noop = function() end
	local wrapped = MakeWrapper({ label = "calibrate", calls = 0, total = 0, self = 0, peak = 0, slow = 0, alloc = 0 }, noop)
	local t0 = debugprofilestop()
	for _ = 1, runs do
		noop()
	end
	local bare = debugprofilestop() - t0
	t0 = debugprofilestop()
	for _ = 1, runs do
		wrapped()
	end
	local with = debugprofilestop() - t0
	depth = 0
	wipe(childMs)
	overheadUs = math.max(with - bare, 0) / runs * 1000
end

function Profiler:Start(seconds, deep)
	if active then
		Print("Profiler is already running. /bf profile report, /bf profile stop.")
		return
	end
	if not debugprofilestop then
		Print("debugprofilestop is not available on this client, probes cannot run.")
		return
	end
	self:Reset()
	active = true
	local api = _G.C_AddOnProfiler
	measure = nil
	if api and type(api.MeasureCall) == "function" and (not api.IsEnabled or Try(api.IsEnabled) ~= false) then
		measure = api.MeasureCall
	end
	usedNative = measure ~= nil
	Calibrate()
	local n = InstallTargets(deep)
	local events = InstallEventProbe()
	runGen = runGen + 1
	local gen = runGen
	Print(format("Profiler started: %d probes%s, %s. Use the bags, then /bf profile stop.", n,
		events and " + event timing" or "", usedNative and "engine MeasureCall" or "wall clock"))
	if seconds and seconds > 0 then
		C_Timer.After(seconds, function()
			if active and runGen == gen then
				self:Stop()
			end
		end)
	end
end

function Profiler:Stop(quiet)
	if not active then
		if not quiet then
			Print("Profiler is not running.")
		end
		return
	end
	active = false
	measure = nil
	for i = #patched, 1, -1 do
		local p = patched[i]
		-- Only restore what is still our wrapper, never clobber a later hook.
		if rawget(p[1], p[2]) == p[4] then
			p[1][p[2]] = p[3]
		end
		patched[i] = nil
	end
	wipe(patchedKeys)
	RemoveEventProbe()
	depth = 0
	wipe(childMs)
	if not quiet then
		self:Report()
	else
		self:Report(true)
	end
end

-- ---------------------------------------------------------------------------
-- Client profiler sources
-- ---------------------------------------------------------------------------
local NATIVE_METRICS = {
	{ "SessionAverageTime", "session avg" },
	{ "LastTime", "last tick" },
	{ "RecentAverageTime", "recent avg" },
	{ "EncounterAverageTime", "encounter avg" },
	{ "PeakTime", "peak" },
	{ "CountTimeOver1Ms", ">1ms ticks" },
	{ "CountTimeOver5Ms", ">5ms ticks" },
	{ "CountTimeOver10Ms", ">10ms ticks" },
	{ "CountTimeOver50Ms", ">50ms ticks" },
	{ "CountTimeOver100Ms", ">100ms ticks" },
}

--- Read C_AddOnProfiler for this addon and for everything combined. Every call
--- is guarded because a client may not ship the API, may stub it, or may change
--- a signature.
function Profiler:ReadNative()
	local api = _G.C_AddOnProfiler
	local enum = Enum and Enum.AddOnProfilerMetric
	if not (api and api.GetAddOnMetric and enum) then
		return nil, "C_AddOnProfiler is not available on this client"
	end
	local out = { addon = {}, overall = {}, top = {} }
	if api.IsEnabled then
		out.enabled = Try(api.IsEnabled)
	end
	local anyValue = false
	for i = 1, #NATIVE_METRICS do
		local field = NATIVE_METRICS[i][1]
		local metric = enum[field]
		if metric ~= nil then
			local mine = Try(api.GetAddOnMetric, ns.name, metric)
			if type(mine) == "number" then
				out.addon[field] = mine
				if mine ~= 0 then
					anyValue = true
				end
			end
			if api.GetOverallMetric then
				local all = Try(api.GetOverallMetric, metric)
				if type(all) == "number" then
					out.overall[field] = all
					if all ~= 0 then
						anyValue = true
					end
				end
			end
		end
	end
	if api.GetTopKAddOnsForMetric and enum.RecentAverageTime ~= nil then
		local top = Try(api.GetTopKAddOnsForMetric, enum.RecentAverageTime, 5)
		if type(top) == "table" then
			for i = 1, #top do
				local row = top[i]
				if type(row) == "table" and type(row.addOnName) == "string" then
					out.top[#out.top + 1] = { name = row.addOnName, value = row.metricValue }
				end
			end
		end
	end
	out.allZero = not anyValue
	return out
end

function Profiler:PrintNative()
	local data, err = self:ReadNative()
	if not data then
		Print(err .. ". Use /bf profile start instead.")
		return
	end
	store.native = data
	Persist()
	Print(format("Client profiler (C_AddOnProfiler)%s. Times in ms per tick.",
		data.enabled == false and ", reports itself disabled" or ""))
	for i = 1, #NATIVE_METRICS do
		local field, label = NATIVE_METRICS[i][1], NATIVE_METRICS[i][2]
		local mine, all = data.addon[field], data.overall[field]
		if mine ~= nil or all ~= nil then
			Print(format("  %-13s Bagforge %9.3f    all addons %9.3f", label, mine or 0, all or 0))
		end
	end
	if #data.top > 0 then
		Print("  Heaviest by recent average:")
		for i = 1, #data.top do
			Print(format("    %d. %-28s %.3f", i, data.top[i].name, data.top[i].value or 0))
		end
	end
	if data.allZero then
		Print("  Every value is 0. Either nothing ran yet or this client stubs the API. Trust /bf profile start over this.")
	end
end

local function ResolveFn(...)
	local ns_ = C_AddOns
	for i = 1, select("#", ...) do
		local name = select(i, ...)
		if ns_ and type(ns_[name]) == "function" then
			return ns_[name]
		end
		if type(_G[name]) == "function" then
			return _G[name]
		end
	end
end

local PROFILER_NAME_HINTS = { "cpu", "profil", "perf", "pulse", "usage", "tomodiag", "taskmanager" }

function Profiler:PrintSources()
	local sources = {}
	Print("Measurement sources on this client:")

	-- 1. Native
	local native = self:ReadNative()
	if native then
		sources.native = native.allZero and "present, all zero" or "present, reporting"
	else
		sources.native = "missing"
	end
	Print(format("  C_AddOnProfiler        %s", sources.native))

	local api = _G.C_AddOnProfiler
	sources.measureCall = (api and type(api.MeasureCall) == "function") and "present" or "missing"
	Print("  MeasureCall            " .. sources.measureCall .. " (exact per-call bytes when present)")

	-- 2. Legacy CPU counters
	local cvar
	if C_CVar and C_CVar.GetCVar then
		cvar = Try(C_CVar.GetCVar, "scriptProfile")
	elseif GetCVar then
		cvar = Try(GetCVar, "scriptProfile")
	end
	local getCpu = ResolveFn("GetAddOnCPUUsage")
	local updateCpu = ResolveFn("UpdateAddOnCPUUsage")
	local cpuValue
	if getCpu then
		if updateCpu then
			Try(updateCpu)
		end
		cpuValue = Try(getCpu, ns.name)
	end
	sources.legacyCpu = format("scriptProfile=%s, %s, Bagforge=%s", tostring(cvar),
		getCpu and "GetAddOnCPUUsage present" or "no GetAddOnCPUUsage", tostring(cpuValue))
	Print("  Legacy CPU counters    " .. sources.legacyCpu)

	-- 3. Memory
	local getMem = ResolveFn("GetAddOnMemoryUsage")
	sources.memory = getMem and "GetAddOnMemoryUsage present" or "missing"
	Print("  Memory counters        " .. sources.memory)

	-- 4. Internal probes
	sources.probes = debugprofilestop and "debugprofilestop present" or "missing"
	Print("  Internal probes        " .. sources.probes .. " (/bf profile start)")

	-- 5. Other profilers the player has installed (name heuristic only).
	local found = {}
	if C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetAddOnInfo then
		for i = 1, C_AddOns.GetNumAddOns() do
			local name = C_AddOns.GetAddOnInfo(i)
			if type(name) == "string" then
				local lower = name:lower()
				for j = 1, #PROFILER_NAME_HINTS do
					if lower:find(PROFILER_NAME_HINTS[j], 1, true) then
						found[#found + 1] = name
						break
					end
				end
			end
		end
	end
	sources.installed = found
	Print("  Installed profilers    " .. (#found > 0 and table.concat(found, ", ") or "none recognised"))

	store.sources = sources
	Persist()
end

-- ---------------------------------------------------------------------------
-- Memory
-- ---------------------------------------------------------------------------
function Profiler:Memory(runGC)
	local luaKB = collectgarbage("count")
	local getMem = ResolveFn("GetAddOnMemoryUsage")
	local updateMem = ResolveFn("UpdateAddOnMemoryUsage")

	local function AddonKB()
		if not getMem then
			return nil
		end
		if updateMem then
			Try(updateMem)
		end
		return Try(getMem, ns.name)
	end

	local mem = { luaKB = luaKB, addonKB = AddonKB() }
	if runGC then
		collectgarbage("collect")
		mem.luaKBAfterGC = collectgarbage("count")
		mem.addonKBAfterGC = AddonKB()
	end

	local function ScannerStats(label, scanner)
		if not scanner then
			return nil
		end
		return {
			label = label,
			slots = scanner.slots and #scanner.slots or 0,
			sections = scanner.sections and #scanner.sections or 0,
			entryPool = scanner._entryCount or 0,
			entryPoolCapacity = scanner._entryPool and #scanner._entryPool or 0,
		}
	end
	mem.scanners = {}
	local items = ns:GetModule("Items")
	mem.scanners[#mem.scanners + 1] = ScannerStats("backpack", items and items.scanner)
	local bank = ns:GetModule("Bank")
	if bank and bank.views then
		for i = 1, #bank.views do
			mem.scanners[#mem.scanners + 1] = ScannerStats(tostring(bank.views[i].name or bank.views[i].frameName or ("bank" .. i)),
				bank.views[i].scanner)
		end
	end

	local itemButton = ns:GetModule("ItemButton")
	local pool = itemButton and itemButton.pool
	if pool and pool.objects then
		local inUse = 0
		for _ in pairs(pool.active) do
			inUse = inUse + 1
		end
		mem.buttons = { total = #pool.objects, active = inUse, free = pool.numFree or 0 }
	end

	store.memory = mem
	Persist()

	Print(format("Memory: Lua heap %.0fK total%s.", luaKB,
		mem.addonKB and format(", Bagforge %.0fK", mem.addonKB) or ""))
	if runGC then
		Print(format("  after full GC: Lua heap %.0fK%s (the drop was garbage, the rest is retained)",
			mem.luaKBAfterGC, mem.addonKBAfterGC and format(", Bagforge %.0fK", mem.addonKBAfterGC) or ""))
	elseif getMem then
		Print("  Add 'gc' to run a full collect and split garbage from retained memory.")
	end
	if mem.buttons then
		Print(format("  item buttons: %d pooled, %d in use, %d free", mem.buttons.total, mem.buttons.active,
			mem.buttons.free))
	end
	for i = 1, #mem.scanners do
		local s = mem.scanners[i]
		if s then
			Print(format("  scanner %-10s %4d slots, %3d sections, entry pool %d/%d", s.label, s.slots, s.sections,
				s.entryPool, s.entryPoolCapacity))
		end
	end
end

-- ---------------------------------------------------------------------------
-- Bench
--   Fixed workloads against whatever is in the bags right now. They answer
--   "what does one rescan cost" without having to play the game for a while.
-- ---------------------------------------------------------------------------
local function Measure(label, n, fn)
	local times = {}
	local alloc = 0
	for i = 1, n do
		local kb0 = collectgarbage("count")
		local t0 = debugprofilestop()
		fn(i)
		times[i] = debugprofilestop() - t0
		local grown = collectgarbage("count") - kb0
		if grown > 0 then
			alloc = alloc + grown
		end
	end
	sort(times)
	local sum = 0
	for i = 1, n do
		sum = sum + times[i]
	end
	return {
		label = label,
		runs = n,
		minMs = times[1],
		medianMs = times[math.floor((n + 1) / 2)],
		avgMs = sum / n,
		maxMs = times[n],
		allocKBPerRun = alloc / n,
	}
end

local BENCH_QUERIES = { "a", "e", "rare", "ilvl>1" }

function Profiler:Bench(n)
	if InCombatLockdown() then
		Print("Bench refused in combat.")
		return
	end
	n = math.max(1, math.min(tonumber(n) or 20, 200))

	local items = ns:GetModule("Items")
	local scanner = items and items.scanner
	if not (scanner and scanner.slots) then
		Print("Bench: the backpack scanner is not ready.")
		return
	end
	local bags = ns.C and ns.C.BACKPACK_BAGS
	local results = {}
	local function Add(result, err)
		if result then
			results[#results + 1] = result
		else
			results[#results + 1] = { label = "error", error = err }
			Print("  bench step failed: " .. tostring(err))
		end
	end

	local slotCount = #scanner.slots
	Print(format("Bench: %d runs per workload, %d occupied slots in the backpack.", n, slotCount))

	if bags then
		Add(Try(Measure, "rescan full", n, function()
			scanner:_Build(bags)
		end))
		if slotCount > 0 and scanner._BuildSlotDiff then
			Add(Try(Measure, "rescan one dirty bag", n, function()
				scanner:_BuildSlotDiff(bags, { [0] = true }, nil)
			end))
		end
	end

	local slots = scanner.slots
	local categories = ns:GetModule("Categories")
	if categories and categories.GetCategory and slotCount > 0 then
		Add(Try(Measure, "classify every slot", n, function()
			for i = 1, #slots do
				categories:GetCategory(slots[i])
			end
		end))
	end

	local search = ns.Search
	if search and search.Match and slotCount > 0 then
		for i = 1, #BENCH_QUERIES do
			local query = BENCH_QUERIES[i]
			if not search.IsValid or search.IsValid(query) then
				Add(Try(Measure, "search '" .. query .. "' over all slots", n, function()
					for j = 1, #slots do
						search.Match(query, slots[j])
					end
				end))
			end
		end
	end

	for i = 1, #results do
		local r = results[i]
		if r.runs then
			local perSlot = slotCount > 0 and (r.medianMs / slotCount * 1000) or 0
			Print(format("  %-34s min %7.3f  median %7.3f  avg %7.3f  max %7.3f ms   %6.1fK/run   %5.1f us/slot",
				r.label, r.minMs, r.medianMs, r.avgMs, r.maxMs, r.allocKBPerRun, perSlot))
		end
	end

	store.bench = { at = time and time() or nil, runs = n, slots = slotCount, results = results }
	Persist()

	-- The workloads above overwrote the scanner's changeset, so rebuild it the
	-- normal way and let the windows redraw from a consistent state.
	if items.Scan then
		items:Scan()
	end
end

--- Start, bench, report. For comparing a change: run it before and after.
function Profiler:Run(runs)
	local wasActive = active
	if not wasActive then
		self:Start()
	end
	self:Bench(tonumber(runs))
	if not wasActive then
		self:Stop()
	end
end

-- ---------------------------------------------------------------------------
-- Command
-- ---------------------------------------------------------------------------
function Profiler:PrintStack(name)
	name = (name or ""):lower()
	if name == "" then
		Print("Usage: /bf profile stack <part of a probe name>")
		return
	end
	local best
	for label, p in pairs(probes) do
		if label:lower():find(name, 1, true) and p.peakStack and (not best or p.peak > best.peak) then
			best = p
		end
	end
	if not best then
		Print("No slow call recorded for '" .. name .. "'. A stack is kept for calls over " .. SLOW_MS .. "ms.")
		return
	end
	Print(format("Slowest call of %s: %.3f ms. Called from:", best.label, best.peak))
	local lines = 0
	for line in best.peakStack:gmatch("[^\n]+") do
		Print("    " .. line)
		lines = lines + 1
		if lines >= 14 then
			break
		end
	end
end

local function PrintHelp()
	Print("Profile (/bf profile opens the window):")
	Print("  start [seconds] [deep] - install probes, optionally stop after N seconds, deep also times Blizzard's button methods")
	Print("  stop / report / reset")
	Print("  stack <name> - where the slowest call of a probe came from")
	Print("  bench [n] - fixed workloads against the live bags")
	Print("  run [n] - start, bench and report in one step")
	Print("  native - the client's own profiler, Bagforge vs all addons")
	Print("  mem [gc] - memory, pools and scanners")
	Print("  sources - which measurement sources work on this client")
end

function Profiler:HandleCommand(value)
	local sub, arg = (value or ""):match("^(%S*)%s*(.-)$")
	sub = (sub or ""):lower()
	if sub == "" or sub == "window" or sub == "ui" or sub == "show" then
		if ns.ProfilerUI then
			ns.ProfilerUI:Toggle()
		else
			PrintHelp()
		end
	elseif sub == "help" then
		PrintHelp()
	elseif sub == "start" then
		self:Start(tonumber(arg:match("%d+")), arg:lower():find("deep", 1, true) ~= nil)
	elseif sub == "stop" then
		self:Stop()
	elseif sub == "report" then
		self:Report()
	elseif sub == "stack" then
		self:PrintStack(arg)
	elseif sub == "reset" then
		self:Reset()
		Print("Profiler counters reset.")
	elseif sub == "bench" then
		self:Bench(tonumber(arg))
	elseif sub == "run" then
		self:Run(arg)
	elseif sub == "native" then
		self:PrintNative()
	elseif sub == "mem" or sub == "memory" then
		self:Memory(arg:lower() == "gc")
	elseif sub == "sources" then
		self:PrintSources()
	else
		PrintHelp()
	end
end
