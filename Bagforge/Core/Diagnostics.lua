--[[
	Bagforge - Diagnostics
	-------------------------------------------------------------------------
	Captures the live scanner index state into SavedVariables so the
	incremental scan path can be verified from disk instead of from pixels.
	Everything stored is plain data (numbers, strings, booleans, arrays), so
	it survives SavedVariables serialisation.

	Usage:
	  /bf diag         snapshot every live scanner, report to chat, store in
	                   BagforgeDB.diag (written to disk on /reload or logout)
	  /bf diag clear   drop the stored snapshot

	  Shape: BagforgeDB.diag = { diagVersion, stamp, at, player, ok, scanners, failing, results }

	Checked invariants - the ones the incremental diff depends on:
	  - slotsByKey holds exactly one key per slot and each key resolves back
	    to the same entry object
	  - no two slots share a slot key
	  - entriesByItemID indexes every slot that has an itemID exactly once
	  - no itemID array repeats an entry, and every entry's itemID matches
	    the key it is filed under
	  - _idUsed and the live index agree in size (no stale pooled ids)
	  - every live index array is the pool's array for that itemID

	Timing
	------
	Each scanner records the wall-clock cost of its last rebuild, plus the peak
	and the running average since load (Scan.lua RunBuild). Diagnostics only
	reports those numbers and asserts nothing about them: a slow rebuild is a
	performance question, not a broken index.
--]]

local _, ns = ...
local F = ns.F
local format = string.format

-- Keep the chat report readable; the full list is still written to disk.
local MAX_REPORTED_FAILURES = 25

local function NewReport(label)
	return {
		label = label,
		ok = true,
		failureCount = 0,
		failures = {},
	}
end

local function Fail(report, message)
	report.ok = false
	report.failureCount = report.failureCount + 1
	if #report.failures < MAX_REPORTED_FAILURES then
		report.failures[#report.failures + 1] = message
	end
end

local function CountKeys(tbl)
	local n = 0
	for _ in pairs(tbl) do
		n = n + 1
	end
	return n
end

local function CheckScanner(scanner, label)
	local report = NewReport(label)
	if not scanner then
		Fail(report, "scanner missing")
		return report
	end

	local slots = scanner.slots or {}
	local byKey = scanner.slotsByKey or {}
	local byID = scanner.entriesByItemID or {}
	local used = scanner._idUsed
	local lists = scanner._idLists

	report.slots = #slots
	report.freeSlots = scanner.freeSlots or 0
	report.totalSlots = scanner.totalSlots or 0
	report.sections = scanner.sections and #scanner.sections or 0
	report.entryPool = scanner._entryCount or 0
	report.sectionPool = scanner._sectionCount or 0

	-- Rebuild cost, recorded by the scanner itself (Scan.lua RunBuild).
	report.rebuildCount = scanner.rebuildCount or 0
	report.lastRebuildMs = scanner.lastRebuildMs
	report.lastRebuildKind = scanner.lastRebuildKind
	report.rebuildPeakMs = scanner.rebuildPeakMs
	if report.rebuildCount > 0 then
		report.rebuildAvgMs = (scanner.rebuildTotalMs or 0) / report.rebuildCount
	end
	-- Where that rebuild time went on the last full build.
	local phases = scanner._phaseMs
	if phases then
		report.phases = {
			scan = phases.scan,
			count = phases.count,
			merge = phases.merge,
			sort = phases.sort,
			sections = phases.sections,
			lookup = phases.lookup,
			tooltips = phases.tooltips,
		}
	end

	-- slotsByKey: one key per slot, resolving back to the same object.
	local keyCount = CountKeys(byKey)
	report.slotsByKey = keyCount
	if keyCount ~= #slots then
		Fail(report, format("slotsByKey holds %d keys for %d slots", keyCount, #slots))
	end

	local seenKey = {}
	for i = 1, #slots do
		local entry = slots[i]
		local key = entry and entry.key
		if key == nil then
			Fail(report, format("slot %d has no key", i))
		elseif seenKey[key] then
			Fail(report, format("duplicate slot key %s", tostring(key)))
		else
			seenKey[key] = true
			if byKey[key] ~= entry then
				Fail(report, format("slotsByKey[%s] does not point at its slot", tostring(key)))
			end
		end
	end

	-- entriesByItemID: every indexed slot exactly once, filed under its own id.
	local expected = 0
	for i = 1, #slots do
		if slots[i] and slots[i].itemID then
			expected = expected + 1
		end
	end

	local indexed = 0
	local idCount = 0
	for id, list in pairs(byID) do
		idCount = idCount + 1
		local n = #list
		indexed = indexed + n
		local seen = {}
		for i = 1, n do
			local entry = list[i]
			if not entry then
				Fail(report, format("itemID %s has a hole at index %d", tostring(id), i))
			elseif seen[entry] then
				Fail(report, format("itemID %s lists the same entry twice", tostring(id)))
			else
				seen[entry] = true
				if entry.itemID ~= id then
					Fail(report, format("itemID %s holds an entry whose id is %s", tostring(id), tostring(entry.itemID)))
				end
			end
		end
	end

	report.itemIDs = idCount
	report.indexedEntries = indexed
	report.expectedIndexed = expected
	if indexed ~= expected then
		Fail(report, format("itemID index holds %d entries for %d indexed slots", indexed, expected))
	end

	-- Pooled per-itemID arrays.
	if lists and used then
		report.pooledIDs = #used
		local seenID = {}
		for i = 1, #used do
			local id = used[i]
			if seenID[id] then
				Fail(report, format("itemID %s appears twice in _idUsed", tostring(id)))
			end
			seenID[id] = true
			local list = lists[id]
			if not list then
				Fail(report, format("_idUsed lists %s with no pooled array", tostring(id)))
			elseif byID[id] ~= list then
				Fail(report, format("itemID %s index is not its pooled array", tostring(id)))
			end
		end
		if #used ~= idCount then
			Fail(report, format("_idUsed has %d ids but the index has %d", #used, idCount))
		end
	else
		report.pooledIDs = 0
	end

	-- Section membership is reported, not asserted: stack merging can legally
	-- collapse several slots into one section entry.
	local sections = scanner.sections
	if sections then
		local sectionItems = 0
		for i = 1, #sections do
			local items = sections[i] and sections[i].items
			sectionItems = sectionItems + (items and #items or 0)
		end
		report.sectionItems = sectionItems
	end

	local changeset = scanner.lastChangeset
	if changeset then
		report.lastChangeset = {
			added = changeset.added and #changeset.added or 0,
			removed = changeset.removed and #changeset.removed or 0,
			updated = changeset.updated and #changeset.updated or 0,
			incremental = changeset.incremental and true or false,
			structureChanged = changeset.structureChanged and true or false,
			needsFinalize = changeset.needsFinalize and true or false,
		}
	end

	return report
end

local function AddScanner(results, scanner, label)
	if scanner then
		results[#results + 1] = CheckScanner(scanner, label)
	end
end

--- Snapshot every live scanner into BagforgeDB.diag and report to chat.
function ns:RunScannerDiagnostics()
	local root = _G.BagforgeDB
	if not root then
		F.Print("BagforgeDB is not initialised; try again once the addon has loaded.")
		return nil
	end

	local results = {}
	local items = ns:GetModule("Items")
	AddScanner(results, items and items.scanner, "backpack")

	local bank = ns:GetModule("Bank")
	local views = bank and bank.views
	if views then
		for i = 1, #views do
			local view = views[i]
			local label = view.name or view.frameName or ("bank" .. i)
			AddScanner(results, view.scanner, tostring(label))
		end
	end

	local failed = 0
	for i = 1, #results do
		if not results[i].ok then
			failed = failed + 1
		end
	end

	root.diag = {
		stamp = date and date("%Y-%m-%d %H:%M:%S") or nil,
		at = time and time() or nil,
		player = ns.C and ns.C.Player and ns.C.Player.key or nil,
		ok = failed == 0,
		scanners = #results,
		failing = failed,
		results = results,
	}
	root.diagVersion = 2

	F.Print(format("Scanner diagnostics: %d scanner(s), %d failing. Stored in BagforgeDB.diag.",
		#results, failed))
	for i = 1, #results do
		local r = results[i]
		F.Print(format("  %s: %s - %d slots, %d itemIDs, %d index entries, %d pooled",
			tostring(r.label), r.ok and "ok" or "FAIL",
			r.slots or 0, r.itemIDs or 0, r.indexedEntries or 0, r.pooledIDs or 0))
		if r.rebuildCount and r.rebuildCount > 0 then
			F.Print(format("    rebuild: %.3fms %s, peak %.3fms, avg %.3fms over %d build(s)",
				r.lastRebuildMs or 0, tostring(r.lastRebuildKind or "?"),
				r.rebuildPeakMs or 0, r.rebuildAvgMs or 0, r.rebuildCount))
		else
			F.Print("    rebuild: no rebuild recorded yet")
		end
		if r.phases then
			F.Print(format("    phases: scan %.2f, sort %.2f, sections %.2f, lookup %.2f, tooltips %d",
				r.phases.scan or 0, r.phases.sort or 0,
				r.phases.sections or 0, r.phases.lookup or 0, r.phases.tooltips or 0))
		end
		for j = 1, #r.failures do
			F.Print("    " .. r.failures[j])
		end
	end

	return root.diag
end

--- Remove the stored snapshot.
function ns:ClearScannerDiagnostics()
	local root = _G.BagforgeDB
	if root then
		root.diag = nil
	end
	F.Print("Scanner diagnostics cleared.")
end
