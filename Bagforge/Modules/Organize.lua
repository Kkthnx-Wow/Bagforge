--[[
	Bagforge - Organize (custom categories, pinned order, stack merging)
	-------------------------------------------------------------------------
	Three user-facing organisation features layered on top of the scanner /
	classifier, all persisted in one profile table (ns.db.organize):

	  * Custom categories - the player assigns an itemID to a named category.
	    Stored as a flat itemID -> name map for O(1) lookup at classify time
	    (Categories.GetCategory checks it before any built-in rule). Mirrors
	    BetterBags' customCategoryIndex.
	  * Pinned ordering    - an order override for ANY category (built-in or
	    custom). Categories.GetOrder consults it first.
	  * Stack merging      - a toggle the scanner reads to collapse identical
	    stacks into one button (see Core/Scan.lua _MergeStacks).
	  * Custom junk        - an account-wide itemID set the player marks as junk;
	    grouped into the Junk panel (Categories.IsJunk) and optionally sold by
	    the merchant automation (Vendor.lua), exactly like NDui's CustomJunkList.

	Two click "modes" (NDui's SelectToggleButton style, mutually exclusive): an
	"assign" mode opens the category menu on a clicked item, a "junk" mode toggles
	the clicked item in/out of the junk list. Arming one disarms the other.

	This module owns the *data and the management UX* (slash + options + the
	drag-to-panel drop handler in Container.lua calls AssignItem here). The
	classifier, scanner and vendor only ever *read* ns.db.organize, so they don't
	hold a reference to this module.
--]]

local _, ns = ...
local L, F = ns.L, ns.F
local format = string.format
local tonumber = tonumber
local pairs = pairs
local wipe = wipe
local select = select
local tsort = table.sort

local C_Item = C_Item
local CursorHasItem = CursorHasItem
local GetCursorInfo = GetCursorInfo
local MerchantFrame = _G["MerchantFrame"]
local MenuUtil = _G["MenuUtil"]
local StaticPopup_Show = StaticPopup_Show
local StaticPopupDialogs = StaticPopupDialogs
local ACCEPT = _G["ACCEPT"]
local CANCEL = _G["CANCEL"]

ns:RegisterDefaults({
	organize = {
		customEnable = true, -- honour custom assignments when classifying
		searchEnable = true, -- honour saved search categories when classifying
		searchHideNonMatches = false, -- hide (true) vs dim (false) non-matching search results
		stackMerge = false, -- collapse identical stacks into one button
		itemSort = "quality", -- within-category sort: quality|name|ilvl|expansion
		assignments = {}, -- [itemID] = categoryName  (O(1) classify lookup)
		order = {}, -- [categoryName] = number  (pinned draw-order override)
		colors = {}, -- [categoryName] = { r, g, b }  (panel header tint)
		searches = {}, -- [name] = { query=, order=, groupBy=, enabled= }
		sortLocks = {}, -- ["bag:slot"] = true  (excluded from deposit/vendor transfers)
	},
})
ns:RegisterDefaults({
	customJunk = {}, -- [itemID] = true (account-wide; matches NDuiADB CustomJunkList)
}, "global")

local Organize = ns:NewModule("Organize", "organize")
Organize.title = L["Custom Categories"]
Organize.order = 25
Organize.group = "filters"

-- ---------------------------------------------------------------------------
-- Data helpers
-- ---------------------------------------------------------------------------
local function DB()
	return ns.db and ns.db.organize
end

local function JunkDB()
	return ns.global and ns.global.customJunk
end

function Organize:OnInitialize()
	local o = DB()
	local junk = JunkDB()
	-- Early builds briefly stored custom junk in the profile table. Move those
	-- entries into the account-wide table so custom junk behaves like NDui and is
	-- available on every character/profile without losing anything already marked.
	if o and o.junk and junk then
		for itemID, enabled in pairs(o.junk) do
			if enabled then
				junk[itemID] = true
			end
		end
		o.junk = nil
	end

	-- Prime the scanner's within-category sort from the saved choice before the
	-- first scan (swaps a comparator pointer; no per-compare setting lookup).
	if o and ns.Scan and ns.Scan.SetSortMode then
		ns.Scan.SetSortMode(o.itemSort)
	end
end

--- Pull an itemID out of free-form text: a pasted item link first, else the
--- item currently held on the cursor. Returns itemID, cleanedName (the text
--- with any link stripped out and trimmed).
local function ParseItemAndName(rest)
	rest = rest or ""
	local itemID
	local link = rest:match("|c%x+|Hitem:.-|h.-|h|r") or rest:match("|Hitem:.-|h.-|h|r")
	if link then
		itemID = C_Item.GetItemInfoInstant(link)
		rest = rest:gsub("|c%x+|Hitem:.-|h.-|h|r", ""):gsub("|Hitem:.-|h.-|h|r", "")
	end
	if not itemID and CursorHasItem() then
		local infoType, a, b = GetCursorInfo()
		if infoType == "item" then
			itemID = (type(a) == "number" and a) or (b and C_Item.GetItemInfoInstant(b))
		end
	end
	local name = rest:gsub("^%s+", ""):gsub("%s+$", "")
	return itemID, name
end

local function ItemLabel(itemID)
	if itemID and F.IsSecret(itemID) then
		return L["(unknown item)"]
	end
	local name = C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(itemID)
	return name or format(L["item:%s"], itemID)
end

-- Distinct custom-category names, sorted, for the assign menu. Scratch tables
-- reused across opens (the menu is rebuilt every time it pops).
local nameScratch = {}
local seenScratch = {}
local function CollectCustomNames(o)
	wipe(nameScratch)
	wipe(seenScratch)
	for _, name in pairs(o.assignments) do
		if not seenScratch[name] then
			seenScratch[name] = true
			nameScratch[#nameScratch + 1] = name
		end
	end
	tsort(nameScratch)
	return nameScratch
end

-- ---------------------------------------------------------------------------
-- Public API (also called by the drag-to-panel handler in Container.lua)
-- ---------------------------------------------------------------------------
--- Assign `itemID` to the custom category `name`, then reclassify + redraw.
function Organize:AssignItem(itemID, name)
	local o = DB()
	if not (o and itemID and F.NotSecret(itemID)) then
		return false
	end
	name = name and name:gsub("^%s+", ""):gsub("%s+$", "")
	if not name or name == "" then
		return false
	end
	o.assignments[itemID] = name
	F.Print(format(L["Assigned %s to category '%s'."], ItemLabel(itemID), name))
	ns:RefreshBags(true)
	return true
end

--- Drop a custom assignment for `itemID` (item returns to automatic sorting).
function Organize:UnassignItem(itemID)
	local o = DB()
	if not (o and itemID and F.NotSecret(itemID) and o.assignments[itemID]) then
		return false
	end
	o.assignments[itemID] = nil
	F.Print(format(L["Removed %s from its custom category."], ItemLabel(itemID)))
	ns:RefreshBags(true)
	return true
end

-- ---------------------------------------------------------------------------
-- Saved search categories (BetterBags-style query rules)
--   Stored as ns.db.organize.searches[name] = { query, order, groupBy, enabled }.
--   The classifier (Categories.GetSearchCategory) reads them; this module owns
--   creation/editing. Any change drops the compiled-query cache and rescans.
-- ---------------------------------------------------------------------------
local function CleanName(name)
	name = name and name:gsub("^%s+", ""):gsub("%s+$", "")
	return (name and name ~= "") and name or nil
end

--- Create or update a saved search. `opts` may carry order/groupBy/enabled;
--- omitted fields keep their previous (or default) value. Returns true on save.
function Organize:SetSearch(name, query, opts)
	local o = DB()
	name = CleanName(name)
	if not (o and name) then
		return false
	end
	opts = opts or {}
	local def = o.searches[name] or { enabled = true }
	if query ~= nil then
		def.query = query
	end
	if opts.order ~= nil then
		def.order = opts.order
	end
	if opts.groupBy ~= nil then
		def.groupBy = opts.groupBy
	end
	if opts.enabled ~= nil then
		def.enabled = opts.enabled and true or false
	end
	def.query = def.query or ""
	o.searches[name] = def
	if ns.Search then
		ns.Search.Invalidate()
	end
	ns:RefreshBags(true)
	return true
end

--- Delete a saved search (and any order/colour overrides it carried).
function Organize:RemoveSearch(name)
	local o = DB()
	name = CleanName(name)
	if not (o and name and o.searches[name]) then
		return false
	end
	o.searches[name] = nil
	o.order[name] = nil
	o.colors[name] = nil
	if ns.Search then
		ns.Search.Invalidate()
	end
	ns:RefreshBags(true)
	return true
end

function Organize:SetSearchEnabled(name, enabled)
	return self:SetSearch(name, nil, { enabled = enabled })
end

function Organize:SetSearchQuery(name, query)
	return self:SetSearch(name, query or "")
end

function Organize:SetSearchGroupBy(name, groupBy)
	return self:SetSearch(name, nil, { groupBy = groupBy })
end

-- ---------------------------------------------------------------------------
-- Per-category header colour (custom + search panels)
-- ---------------------------------------------------------------------------
--- Tint a category panel's header. Display-only, so repaint (no rescan); the
--- draw epoch bump in RefreshBags(false) forces panels to relayout their header.
function Organize:SetColor(name, r, g, b)
	local o = DB()
	name = CleanName(name)
	if not (o and name) then
		return false
	end
	o.colors[name] = { r, g, b }
	ns:RefreshBags(false)
	return true
end

function Organize:ClearColor(name)
	local o = DB()
	name = CleanName(name)
	if not (o and name) then
		return false
	end
	o.colors[name] = nil
	ns:RefreshBags(false)
	return true
end

-- ---------------------------------------------------------------------------
-- Draw-order pin (shared with built-ins via Categories.GetOrder)
-- ---------------------------------------------------------------------------
--- Pin a category's draw order (lower = drawn first). nil clears the override.
function Organize:SetOrder(name, value)
	local o = DB()
	name = CleanName(name)
	if not (o and name) then
		return false
	end
	o.order[name] = value
	ns:RefreshBags(true)
	return true
end

local function BuildVisibleCategoryOrder(owner, categoryName)
	local categories = ns:GetModule("Categories")
	local source = owner and owner.visibleCategoryOrder
	if not (source and categoryName) then
		return
	end

	local list = {}
	local foundIndex
	for i = 1, #source do
		local name = source[i]
		if name and not (categories and categories:IsMainPanel(name)) then
			list[#list + 1] = name
			if name == categoryName then
				foundIndex = #list
			end
		end
	end
	return list, foundIndex
end

-- Sparse / fractional indexing for the bag's right-click reorder. A move writes
-- ONLY the moved category's draw order - a midpoint between the orders of its new
-- neighbours - so it never rewrites the other panels. That keeps this on the same
-- continuous order-space the Category Manager uses (Organize:ApplyManagedOrder),
-- instead of the old integer 1..n scale that clobbered built-in defaults and the
-- manager's custom band. The two reorder systems now share one ns.db.organize.order
-- scale and compose as "last action wins" with nothing stranded. Lower order draws
-- first (nearer the main bag panel); EPS only matters when neighbours are tied.
local ORDER_EPS = 0.001

local function CategoryEntries(owner, categoryName)
	local scanner = owner and owner.scanner
	if not scanner then
		local items = ns:GetModule("Items")
		scanner = items and items.scanner
	end
	local section = scanner and scanner.sectionsByName and scanner.sectionsByName[categoryName]
	return section and section.items
end

local function IsBackpackOwner(owner)
	return not (owner and owner.bankType)
end

function Organize:MoveVisibleCategory(owner, categoryName, direction)
	categoryName = CleanName(categoryName)
	if not categoryName then
		return false
	end
	local list, index = BuildVisibleCategoryOrder(owner, categoryName)
	if not (list and index) then
		return false
	end
	local n = #list
	if n < 2 then
		return false
	end

	local categories = ns:GetModule("Categories")
	local function OrderOf(name)
		return (categories and categories:GetOrder(name)) or 4
	end

	-- The visible list is ascending by draw order, so a higher number sits nearer
	-- the top of the stack: "up" raises the order, "down" lowers it.
	local newOrder
	if direction == "up" then
		if index >= n then
			return false
		end
		local lo = OrderOf(list[index + 1]) -- neighbour now just above
		local above = list[index + 2]
		if above then
			local hi = OrderOf(above)
			newOrder = (hi - lo > ORDER_EPS) and (lo + hi) / 2 or (lo + ORDER_EPS)
		else
			newOrder = lo + 1
		end
	elseif direction == "down" then
		if index <= 1 then
			return false
		end
		local hi = OrderOf(list[index - 1]) -- neighbour now just below
		local below = list[index - 2]
		if below then
			local lo = OrderOf(below)
			newOrder = (hi - lo > ORDER_EPS) and (lo + hi) / 2 or (hi - ORDER_EPS)
		else
			newOrder = hi - 1
		end
	elseif direction == "top" then
		if index >= n then
			return false
		end
		newOrder = OrderOf(list[n]) + 1
	elseif direction == "bottom" then
		if index <= 1 then
			return false
		end
		newOrder = OrderOf(list[1]) - 1
	else
		return false
	end

	local o = DB()
	if not o then
		return false
	end
	local order = o.order or {}
	o.order = order
	order[categoryName] = newOrder
	ns:RefreshBags(true)
	return true
end

--- Clear every draw-order override so the whole stack (built-in and custom panels
--- alike) returns to its default ordering. Reorder moves now pin only the category
--- that moved, but a single action that wipes the lot is the clearest "put it all
--- back" - and it also clears any order set through the Category Manager.
function Organize:ResetCategoryOrder()
	local o = DB()
	if not o then
		return false
	end
	wipe(o.order)
	ns:RefreshBags(true)
	return true
end

function Organize:OpenCategoryOrderMenu(ownerFrame, categoryName, owner)
	local categories = ns:GetModule("Categories")
	categoryName = CleanName(categoryName)
	if not (MenuUtil and MenuUtil.CreateContextMenu and ownerFrame and categoryName) then
		return
	end
	if categories and categories:IsMainPanel(categoryName) then
		return
	end

	local list, index = BuildVisibleCategoryOrder(owner, categoryName)
	if not (list and index) then
		return
	end

	MenuUtil.CreateContextMenu(ownerFrame, function(_, root)
		root:CreateTitle(categoryName)
		if index < #list then
			root:CreateButton(L["Move Up"], function()
				self:MoveVisibleCategory(owner, categoryName, "up")
			end)
		end
		if index > 1 then
			root:CreateButton(L["Move Down"], function()
				self:MoveVisibleCategory(owner, categoryName, "down")
			end)
		end
		if index < #list then
			root:CreateButton(L["Move to Top"], function()
				self:MoveVisibleCategory(owner, categoryName, "top")
			end)
		end
		if index > 1 then
			root:CreateButton(L["Move to Bottom"], function()
				self:MoveVisibleCategory(owner, categoryName, "bottom")
			end)
		end
		root:CreateButton(L["Reset All Order"], function()
			self:ResetCategoryOrder()
		end)
		local transfers = ns:GetModule("Transfers")
		local entries = CategoryEntries(owner, categoryName)
		if transfers and entries and #entries > 0 and IsBackpackOwner(owner) then
			if MerchantFrame and MerchantFrame:IsShown() then
				root:CreateButton(L["Vendor Category"], function()
					transfers:VendorCategory(categoryName, entries)
				end)
			end
			local bank = ns:GetModule("Bank")
			if bank and bank.OpenView and bank:OpenView() then
				root:CreateButton(L["Deposit Category to Bank"], function()
					transfers:DepositCategory(categoryName, entries)
				end)
			end
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Manager support (used by Modules/CategoryManager)
--   These operate on the same ns.db.organize tables the classifier reads.
-- ---------------------------------------------------------------------------
local CUSTOM_ORDER_BASE = 4 -- mirrors Categories' CUSTOM_CATEGORY_ORDER

--- Build a sorted list of the player-managed categories (custom assignments and
--- saved searches) for the manager window. Each row is
---   { name, kind = "custom"|"search", count?, def? }
--- sorted by effective draw order then name.
function Organize:GetManagedCategories()
	local o = DB()
	local list = {}
	if not o then
		return list
	end

	local counts = {}
	for _, name in pairs(o.assignments) do
		counts[name] = (counts[name] or 0) + 1
	end
	for name, count in pairs(counts) do
		list[#list + 1] = { name = name, kind = "custom", count = count }
	end
	for name, def in pairs(o.searches) do
		list[#list + 1] = { name = name, kind = "search", def = def }
	end

	local categories = ns:GetModule("Categories")
	tsort(list, function(a, b)
		local oa = categories and categories:GetOrder(a.name) or 0
		local ob = categories and categories:GetOrder(b.name) or 0
		if oa ~= ob then
			return oa < ob
		end
		return a.name < b.name
	end)
	return list
end

--- Rename a custom or search category, carrying its order/colour overrides.
--- Returns false on a no-op or a name clash with an existing search.
function Organize:RenameCategory(oldName, newName, kind)
	local o = DB()
	oldName, newName = CleanName(oldName), CleanName(newName)
	if not (o and oldName and newName) or oldName == newName then
		return false
	end

	if kind == "search" then
		if not o.searches[oldName] or o.searches[newName] then
			return false
		end
		o.searches[newName] = o.searches[oldName]
		o.searches[oldName] = nil
	else
		for itemID, name in pairs(o.assignments) do
			if name == oldName then
				o.assignments[itemID] = newName
			end
		end
	end

	if o.order[oldName] ~= nil then
		o.order[newName], o.order[oldName] = o.order[oldName], nil
	end
	if o.colors[oldName] ~= nil then
		o.colors[newName], o.colors[oldName] = o.colors[oldName], nil
	end

	if ns.Search then
		ns.Search.Invalidate()
	end
	ns:RefreshBags(true)
	return true
end

--- Delete a custom category (all its assignments) or a saved search, plus any
--- order/colour overrides it carried.
function Organize:DeleteCategory(name, kind)
	local o = DB()
	name = CleanName(name)
	if not (o and name) then
		return false
	end

	if kind == "search" then
		o.searches[name] = nil
	else
		for itemID, n in pairs(o.assignments) do
			if n == name then
				o.assignments[itemID] = nil
			end
		end
	end
	o.order[name] = nil
	o.colors[name] = nil

	if ns.Search then
		ns.Search.Invalidate()
	end
	ns:RefreshBags(true)
	return true
end

--- Persist an explicit top-to-bottom order for the managed categories. Writes
--- evenly-spaced fractional weights in the band just below the Recent panel so they
--- cluster together without disturbing the built-in panels. Shares the same
--- ns.db.organize.order scale as the bag right-click reorder (MoveVisibleCategory):
--- both write fractional weights, so the two systems compose cleanly - whichever
--- acted last on a given category wins, with no stranded mixed-scale values.
function Organize:ApplyManagedOrder(orderedNames)
	local o = DB()
	if not (o and orderedNames) then
		return
	end
	for i = 1, #orderedNames do
		o.order[orderedNames[i]] = CUSTOM_ORDER_BASE + i * 0.01
	end
	ns:RefreshBags(true)
end

-- ---------------------------------------------------------------------------
-- Item sort + category manager window
-- ---------------------------------------------------------------------------
local SORT_MODES = { quality = true, name = true, ilvl = true, expansion = true }

-- Valid if it's one of ours or an enabled plugin sort (Bagforge.API). Unknown or
-- disabled modes fall back to quality so the scanner always has a real comparator.
local function IsValidSort(mode)
	if SORT_MODES[mode] then
		return true
	end
	return (ns.API and ns.API.IsSortActive and ns.API:IsSortActive(mode)) or false
end

--- Apply a within-category sort choice (swaps the scanner's comparator pointer).
function Organize:SetSortMode(mode)
	local o = DB()
	if not o then
		return
	end
	if not IsValidSort(mode) then
		mode = "quality"
	end
	o.itemSort = mode
	if ns.Scan and ns.Scan.SetSortMode then
		ns.Scan.SetSortMode(mode)
	end
	ns:RefreshBags(true)
end

--- Re-validate the saved item sort and re-point the scanner without rescanning.
--- Used when a plugin sort's source is toggled off (the Plugins page calls this
--- before refreshing): a now-unusable mode reverts to quality.
function Organize:ValidateSortMode()
	local o = DB()
	if not o then
		return
	end
	if not IsValidSort(o.itemSort) then
		o.itemSort = "quality"
	end
	if ns.Scan and ns.Scan.SetSortMode then
		ns.Scan.SetSortMode(o.itemSort)
	end
end

function Organize:OpenManager()
	local manager = ns:GetModule("CategoryManager")
	if manager and manager.Toggle then
		manager:Toggle()
	end
end

-- ---------------------------------------------------------------------------
-- Sort slot locks (Ctrl+right-click on an item; Blizzard bag sort may still move)
-- ---------------------------------------------------------------------------
function Organize:SortLockKey(bag, slot)
	return bag .. ":" .. slot
end

function Organize:IsSortLocked(bag, slot)
	local o = DB()
	if not (o and o.sortLocks) then
		return false
	end
	return o.sortLocks[self:SortLockKey(bag, slot)] and true or false
end

function Organize:ToggleSortLock(bag, slot)
	local o = DB()
	if not (o and bag and slot) then
		return false
	end
	o.sortLocks = o.sortLocks or {}
	local key = self:SortLockKey(bag, slot)
	if o.sortLocks[key] then
		o.sortLocks[key] = nil
	else
		o.sortLocks[key] = true
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Category export / import (JSON via C_EncodingUtil)
-- ---------------------------------------------------------------------------
local C_EncodingUtil = C_EncodingUtil
local EXPORT_VERSION = 1

local function UniqueCategoryName(existing, name)
	if not existing[name] then
		return name
	end
	local base = name
	local n = 2
	while existing[base .. " (" .. n .. ")"] do
		n = n + 1
	end
	return base .. " (" .. n .. ")"
end

function Organize:ExportCategories()
	local o = DB()
	if not o then
		return ""
	end
	local managed = {}
	local list = self:GetManagedCategories()
	for i = 1, #list do
		managed[i] = list[i].name
	end
	local assignments = {}
	for itemID, catName in pairs(o.assignments) do
		if F.NotSecret(itemID) then
			assignments[tostring(itemID)] = catName
		end
	end
	local junkOut
	local junk = JunkDB()
	if junk then
		junkOut = {}
		for itemID in pairs(junk) do
			if F.NotSecret(itemID) then
				junkOut[tostring(itemID)] = true
			end
		end
		if not next(junkOut) then
			junkOut = nil
		end
	end
	local export = {
		version = EXPORT_VERSION,
		addon = "Bagforge",
		kind = "categories",
		searches = CopyTable(o.searches or {}),
		assignments = assignments,
		order = CopyTable(o.order or {}),
		colors = CopyTable(o.colors or {}),
		managedOrder = managed,
		customJunk = junkOut,
	}
	if C_EncodingUtil and C_EncodingUtil.SerializeJSON then
		return C_EncodingUtil.SerializeJSON(export)
	end
	return nil
end

--- Merge categories from a JSON export. Returns success, message.
function Organize:ImportCategories(json)
	local o = DB()
	if not o then
		return false, L["Database not ready."]
	end
	if not (C_EncodingUtil and C_EncodingUtil.DeserializeJSON) then
		return false, L["JSON import is unavailable on this client."]
	end
	if not (json and json:gsub("%s", "") ~= "") then
		return false, L["Nothing to import."]
	end
	local ok, data = pcall(C_EncodingUtil.DeserializeJSON, json)
	if not ok or type(data) ~= "table" or data.kind ~= "categories" then
		return false, L["Invalid category import data."]
	end

	o.searches = o.searches or {}
	local existingSearches = o.searches
	local renamed = 0
	if type(data.searches) == "table" then
		for name, def in pairs(data.searches) do
			if type(name) == "string" and type(def) == "table" then
				local target = name
				if existingSearches[target] then
					target = UniqueCategoryName(existingSearches, name)
					renamed = renamed + 1
				end
				existingSearches[target] = CopyTable(def)
			end
		end
	end

	if type(data.assignments) == "table" then
		for idStr, catName in pairs(data.assignments) do
			local itemID = tonumber(idStr)
			if itemID and F.NotSecret(itemID) and type(catName) == "string" then
				o.assignments[itemID] = catName
			end
		end
	end
	if type(data.order) == "table" then
		for name, ord in pairs(data.order) do
			if type(name) == "string" and type(ord) == "number" and F.NotSecret(ord) then
				o.order[name] = ord
			end
		end
	end
	if type(data.colors) == "table" then
		for name, color in pairs(data.colors) do
			if type(name) == "string" and type(color) == "table" then
				o.colors[name] = { color[1], color[2], color[3] }
			end
		end
	end
	if type(data.managedOrder) == "table" and #data.managedOrder > 0 then
		self:ApplyManagedOrder(data.managedOrder)
	end

	local junk = JunkDB()
	if junk and type(data.customJunk) == "table" then
		for idStr, enabled in pairs(data.customJunk) do
			local itemID = tonumber(idStr)
			if itemID and F.NotSecret(itemID) and enabled then
				junk[itemID] = true
			end
		end
	end

	if ns.Search then
		ns.Search.Invalidate()
	end
	ns:RefreshBags(true)
	local msg = L["Categories imported."]
	if renamed > 0 then
		msg = format(L["Categories imported. %d search(es) renamed to avoid clashes."], renamed)
	end
	return true, msg
end

-- ---------------------------------------------------------------------------
-- Click modes (NDui's SelectToggleButton: mutually-exclusive toolbar toggles)
--   "assign" - left-click an item to open its category menu
--   "junk"   - left-click an item to toggle it in/out of the junk list
-- ---------------------------------------------------------------------------
--- Backpack registers each toolbar toggle here so SetMode can keep their locked
--- highlights in sync (the armed mode glows, the others don't).
function Organize:RegisterModeButton(mode, button)
	self.modeButtons = self.modeButtons or {}
	self.modeButtons[mode] = button
end

--- Lazily attach the "armed" glow (Blizzard's bags-newitem flash) to a toggle.
local function EnsureModeGlow(button)
	if button.bfModeGlow then
		return button.bfModeGlow
	end
	local glow = button:CreateTexture(nil, "OVERLAY")
	glow:SetAtlas("bags-newitem")
	glow:SetBlendMode("ADD")
	glow:SetPoint("TOPLEFT", button, "TOPLEFT", -2, 2)
	glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
	glow:Hide()
	button.bfModeGlow = glow
	return glow
end

--- Switch to `mode` (or nil to disarm). The armed toggle gets the bags-newitem
--- glow (and a locked highlight); every other registered toggle is cleared, so
--- only one mode is ever active at a time.
function Organize:SetMode(mode)
	self.mode = mode
	if self.modeButtons then
		for m, button in pairs(self.modeButtons) do
			local active = (m == mode)
			if active then
				button:LockHighlight()
			else
				button:UnlockHighlight()
			end
			EnsureModeGlow(button):SetShown(active)
		end
	end
end

function Organize:ToggleMode(mode)
	if self.mode == mode then
		self:SetMode(nil)
		F.Print(L["Edit mode off."])
	else
		self:SetMode(mode)
		if mode == "junk" then
			F.Print(L["Junk mode on - left-click an item to toggle it as junk."])
		elseif mode == "delete" then
			F.Print(L["Delete mode on - Ctrl+Alt left-click eligible items to delete them."])
		else
			F.Print(L["Assign mode on - left-click an item to set its category."])
		end
	end
end

--- Prompt for a brand-new category name, then assign `itemID` to it.
function Organize:PromptNewCategory(itemID)
	if not (StaticPopup_Show and itemID) then
		return
	end
	local dialog = StaticPopup_Show("BAGFORGE_NEW_CATEGORY")
	if dialog then
		dialog.data = itemID
	end
end

--- Open the assign dropdown for `entry`, anchored to `ownerButton`. Lists the
--- existing custom categories (radio-checked on the current one), a remove
--- option, and a "new category" prompt. Falls back to the new-category prompt
--- on a client without the modern Menu API.
function Organize:OpenAssignMenu(ownerButton, entry)
	local o = DB()
	if not (o and entry and entry.itemID) then
		return
	end
	local id = entry.itemID
	if F.IsSecret(id) then
		return
	end

	if not (MenuUtil and MenuUtil.CreateContextMenu) then
		self:PromptNewCategory(id)
		return
	end

	MenuUtil.CreateContextMenu(ownerButton, function(_, root)
		root:CreateTitle(ItemLabel(id))
		if o.assignments[id] then
			root:CreateButton(L["Remove from Category"], function()
				self:UnassignItem(id)
			end)
		end
		local names = CollectCustomNames(o)
		for i = 1, #names do
			local name = names[i]
			root:CreateRadio(name, function()
				return o.assignments[id] == name
			end, function()
				self:AssignItem(id, name)
			end)
		end
		root:CreateButton(L["New Category..."], function()
			self:PromptNewCategory(id)
		end)
	end)
end

-- ---------------------------------------------------------------------------
-- Custom junk (NDui CustomJunkList): mark items as junk to group + auto-sell
-- ---------------------------------------------------------------------------
--- Vendor sell price of an itemID (GetItemInfo field 11), secret-guarded.
local function SellPrice(itemID)
	local price = select(11, C_Item.GetItemInfo(itemID))
	if price and F.NotSecret(price) then
		return price
	end
	return 0
end

--- Toggle whether `itemID` is treated as junk. Only items with a vendor price
--- qualify (selling worthless items is pointless, and it matches NDui).
function Organize:SetJunk(itemID, junked)
	local junk = JunkDB()
	if not (junk and itemID) or F.IsSecret(itemID) then
		return false
	end
	if junked and SellPrice(itemID) <= 0 then
		F.Print(L["That item has no vendor value."])
		return false
	end
	junk[itemID] = junked or nil
	F.Print(format(junked and L["%s is now marked as junk."] or L["%s is no longer junk."], ItemLabel(itemID)))
	ns:RefreshBags(true)
	return true
end

--- Flip an item's junk state (used by the junk click mode).
function Organize:ToggleJunk(entry)
	local id = entry and entry.itemID
	local junk = JunkDB()
	if not (junk and id) or F.IsSecret(id) then
		return
	end
	self:SetJunk(id, not junk[id])
end

--- Wipe the entire custom junk list (confirmed via the popup).
function Organize:ClearJunk()
	local junk = JunkDB()
	if not junk then
		return
	end
	wipe(junk)
	F.Print(L["Custom junk list cleared."])
	ns:RefreshBags(true)
end

-- ---------------------------------------------------------------------------
-- Slash: /bf cat <sub> ...
-- ---------------------------------------------------------------------------
function Organize:PrintHelp()
	F.Print(L["Custom Categories (/bf cat)"])
	F.Print("  " .. L["add <name> [item link] - Assign an item (or the one on your cursor)"])
	F.Print("  " .. L["remove [item link] - Unassign an item"])
	F.Print("  " .. L["clear <name> - Delete a custom category"])
	F.Print("  " .. L["order <name> <number> - Pin a category's draw order"])
	F.Print("  " .. L["unorder <name> - Clear a category's order override"])
	F.Print("  " .. L["search <name> | <query> - Save a search category"])
	F.Print("  " .. L["unsearch <name> - Delete a search category"])
	F.Print("  " .. L["manage - Open the category manager window"])
	F.Print("  " .. L["list - List custom categories and pins"])
end

function Organize:PrintList()
	local o = DB()
	if not o then
		return
	end

	local counts = {}
	for _, name in pairs(o.assignments) do
		counts[name] = (counts[name] or 0) + 1
	end

	F.Print(L["Custom Categories"] .. ":")
	local any = false
	for name, count in pairs(counts) do
		any = true
		F.Print(format(L["  %s (%d)"], name, count))
	end
	if not any then
		F.Print("  " .. L["(none)"])
	end

	local pinned = false
	for name, value in pairs(o.order) do
		if not pinned then
			F.Print(L["Pinned order"] .. ":")
			pinned = true
		end
		F.Print(format(L["  %s = %s"], name, tostring(value)))
	end
end

function Organize:CmdAdd(rest)
	local itemID, name = ParseItemAndName(rest)
	if not itemID or name == "" then
		F.Print(L["Usage: /bf cat add <name> [item link], or hold an item on the cursor."])
		return
	end
	self:AssignItem(itemID, name)
end

function Organize:CmdRemove(rest)
	local itemID = ParseItemAndName(rest)
	if not itemID then
		F.Print(L["Usage: /bf cat remove <item link>, or hold an item on the cursor."])
		return
	end
	if not self:UnassignItem(itemID) then
		F.Print(L["That item has no custom category."])
	end
end

function Organize:CmdClear(rest)
	local o = DB()
	local name = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if not o or name == "" then
		F.Print(L["Usage: /bf cat clear <name>"])
		return
	end
	local removed = 0
	for itemID, assigned in pairs(o.assignments) do
		if assigned == name then
			o.assignments[itemID] = nil
			removed = removed + 1
		end
	end
	o.order[name] = nil
	F.Print(format(L["Cleared custom category '%s' (%d items)."], name, removed))
	ns:RefreshBags(true)
end

function Organize:CmdOrder(rest)
	local o = DB()
	if not o then
		return
	end
	-- "<name...> <number>": lazy name, then a trailing (possibly decimal) number.
	local name, value = (rest or ""):match("^(.-)%s+(%-?%d+%.?%d*)%s*$")
	local num = value and tonumber(value)
	if not name or name == "" or not num then
		F.Print(L["Usage: /bf cat order <name> <number>"])
		return
	end
	o.order[name] = num
	F.Print(format(L["Pinned '%s' to order %s."], name, tostring(num)))
	ns:RefreshBags(true)
end

function Organize:CmdUnorder(rest)
	local o = DB()
	local name = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if not o or name == "" then
		F.Print(L["Usage: /bf cat unorder <name>"])
		return
	end
	o.order[name] = nil
	F.Print(format(L["Cleared the order override for '%s'."], name))
	ns:RefreshBags(true)
end

function Organize:HandleCommand(value)
	value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local sub, rest = value:match("^(%S+)%s*(.*)$")
	sub = sub and sub:lower() or ""
	rest = rest or ""

	if sub == "" or sub == "help" then
		self:PrintHelp()
	elseif sub == "list" then
		self:PrintList()
	elseif sub == "add" then
		self:CmdAdd(rest)
	elseif sub == "remove" or sub == "rem" then
		self:CmdRemove(rest)
	elseif sub == "clear" or sub == "delete" then
		self:CmdClear(rest)
	elseif sub == "order" or sub == "pin" then
		self:CmdOrder(rest)
	elseif sub == "unorder" or sub == "unpin" then
		self:CmdUnorder(rest)
	elseif sub == "search" then
		self:CmdSearch(rest)
	elseif sub == "unsearch" then
		self:CmdUnsearch(rest)
	elseif sub == "manage" or sub == "manager" then
		self:OpenManager()
	else
		self:PrintHelp()
	end
end

--- "/bf cat search <name> | <query>" - save a search category. The name and the
--- query are split on a literal pipe so both may contain spaces.
function Organize:CmdSearch(rest)
	local name, query = (rest or ""):match("^(.-)%s*|%s*(.*)$")
	name = name and name:gsub("^%s+", ""):gsub("%s+$", "")
	if not name or name == "" or not query or query == "" then
		F.Print(L["Usage: /bf cat search <name> | <query>"])
		return
	end
	if self:SetSearch(name, query) then
		F.Print(format(L["Saved search category '%s'."], name))
	end
end

function Organize:CmdUnsearch(rest)
	local name = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then
		F.Print(L["Usage: /bf cat unsearch <name>"])
		return
	end
	if self:RemoveSearch(name) then
		F.Print(format(L["Deleted search category '%s'."], name))
	else
		F.Print(L["No such search category."])
	end
end

-- ---------------------------------------------------------------------------
-- Slash: /bf junk <sub> ...
-- ---------------------------------------------------------------------------
function Organize:PrintJunkHelp()
	F.Print(L["Custom Junk"] .. " (|cffffd200/bf junk|r):")
	F.Print("  " .. L["add [item link] - Mark an item (or the one on your cursor) as junk"])
	F.Print("  " .. L["remove [item link] - Unmark an item"])
	F.Print("  " .. L["clear - Wipe the junk list"])
	F.Print("  " .. L["list - List junked items"])
end

function Organize:PrintJunkList()
	local junk = JunkDB()
	if not junk then
		return
	end
	F.Print(L["Custom Junk"] .. ":")
	local any = false
	for itemID in pairs(junk) do
		any = true
		F.Print("  " .. ItemLabel(itemID))
	end
	if not any then
		F.Print("  " .. L["(none)"])
	end
end

function Organize:HandleJunkCommand(value)
	value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local sub, rest = value:match("^(%S+)%s*(.*)$")
	sub = sub and sub:lower() or ""
	rest = rest or ""

	if sub == "" or sub == "help" then
		self:PrintJunkHelp()
	elseif sub == "list" then
		self:PrintJunkList()
	elseif sub == "add" then
		local itemID = ParseItemAndName(rest)
		if itemID then
			self:SetJunk(itemID, true)
		else
			F.Print(L["Usage: /bf junk add <item link>, or hold an item on the cursor."])
		end
	elseif sub == "remove" or sub == "rem" then
		local itemID = ParseItemAndName(rest)
		if itemID then
			self:SetJunk(itemID, false)
		else
			F.Print(L["Usage: /bf junk remove <item link>, or hold an item on the cursor."])
		end
	elseif sub == "clear" or sub == "wipe" then
		if StaticPopup_Show then
			StaticPopup_Show("BAGFORGE_WIPE_JUNK")
		else
			self:ClearJunk()
		end
	else
		self:PrintJunkHelp()
	end
end

-- ---------------------------------------------------------------------------
-- Settings + live apply
-- ---------------------------------------------------------------------------
function Organize:OnSettingChanged(key)
	-- Item sort swaps the scanner's comparator pointer; the binding already wrote
	-- the new value, so just validate + re-point and rescan. Every other toggle
	-- here changes item membership / display structure, so it rescans too.
	if key == "itemSort" then
		self:ValidateSortMode()
	end
	ns:RefreshBags(true)
end

function Organize:RegisterOptions(category, builder)
	builder:Checkbox(category, self, "customEnable", L["Enable Custom Categories"], L["Honour items you've assigned to your own categories (/bf cat add)."])
	builder:Checkbox(category, self, "searchEnable", L["Enable Search Categories"], L["Honour your saved search-query categories when sorting items."])
	builder:Checkbox(category, self, "searchHideNonMatches", L["Hide Search Non-Matches"], L["Hide items that don't match the search box. Off dims them instead (Blizzard default)."])
	builder:Checkbox(category, self, "stackMerge", L["Merge Stacks"], L["Show identical stackable items as a single button with the combined count."])

	builder:Header(L["Item Sort"])
	local sortChoices = {
		{ value = "quality", label = L["Quality"] },
		{ value = "name", label = L["Name"] },
		{ value = "ilvl", label = L["Item Level"] },
		{ value = "expansion", label = L["Expansion"] },
	}
	-- Append any enabled plugin sort modes (Bagforge.API:RegisterSortMode).
	if ns.API and ns.API.GetSortChoices then
		local extra = ns.API:GetSortChoices()
		for i = 1, #extra do
			sortChoices[#sortChoices + 1] = extra[i]
		end
	end
	builder:Dropdown(category, self, "itemSort", L["Item Sort"], L["How items are ordered inside each category panel."], sortChoices)

	builder:Header(L["Category Manager"])
	-- Empty left label: Blizzard's button row is the control; the header above
	-- already names the section (same pattern as Edit Mode / Cooldown Manager).
	builder:Button("", L["Open"], function()
		self:OpenManager()
	end, L["Rename, recolour, reorder, enable and delete your custom and search categories."])
end

-- New-category prompt used by the assign menu's "New Category..." entry.
local function GetPopupEditText(popup)
	local editBox = popup and (popup.EditBox or popup.editBox)
	return editBox and editBox:GetText() or ""
end

if StaticPopupDialogs then
	StaticPopupDialogs["BAGFORGE_NEW_CATEGORY"] = {
		text = L["Enter a category name:"],
		button1 = ACCEPT or "Accept",
		button2 = CANCEL or "Cancel",
		hasEditBox = true,
		maxLetters = 64,
		OnAccept = function(self, data)
			local organize = ns:GetModule("Organize")
			if organize then
				organize:AssignItem(data, GetPopupEditText(self))
			end
		end,
		EditBoxOnEnterPressed = function(self)
			local parent = self:GetParent()
			local organize = ns:GetModule("Organize")
			if organize then
				organize:AssignItem(parent.data, self:GetText())
			end
			parent:Hide()
		end,
		EditBoxOnEscapePressed = function(self)
			self:GetParent():Hide()
		end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
	}

	-- Confirm before wiping the whole custom junk list (NDui's wipe popup).
	StaticPopupDialogs["BAGFORGE_WIPE_JUNK"] = {
		text = L["Wipe the entire custom junk list?"],
		button1 = _G["YES"] or "Yes",
		button2 = _G["NO"] or "No",
		OnAccept = function()
			local organize = ns:GetModule("Organize")
			if organize then
				organize:ClearJunk()
			end
		end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
	}
end
