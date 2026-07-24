--[[
	Bagforge - Public Plugin API
	-------------------------------------------------------------------------
	The supported surface other addons build on. Reachable as `Bagforge.API`
	(the addon's one global is `Bagforge`, which is the `ns` table). Two things
	a plugin can contribute today:

	  * Categories - a filter that routes matching items into a named bag panel,
	    modelled on BetterBags' RegisterCategoryFunction (return a name, or nil
	    to pass). Bagforge owns priority and redraws; the
	    plugin only answers "does this item belong, and where".
	  * Sort modes  - a within-category comparator that shows up as a choice in
	    the Item Sort dropdown.
	  * Corner widgets - per-item overlays (upgrade arrows, etc.) on bag buttons.
	  * Item button callbacks - full-button overlays (TransmogLootHelper, etc.);
	    see RegisterItemButtonCallback / RequestItemButtonsRefresh.
	  * Junk detectors   - third-party junk overlays (Dejunk, Scrap, etc.);
	    see RegisterJunkDetector / IsItemJunk.

	Design rules that keep this safe:
	  * Plugins never touch ns.db or internal modules - they hand us closures.
	  * Every plugin closure is pcall-guarded so a faulty plugin can't break a
	    scan, a sort or the classifier (Categories/Scan call through here).
	  * Use API:SafeSortNumber() to normalize missing numeric scan fields in custom
	    sort comparators.
	  * Each registration is attributed to a "source" (the owning plugin). The
	    settings Plugins page lists sources and lets the player toggle each one;
	    a disabled source contributes nothing.

	Example (in a separate addon that lists Bagforge as a dependency):

	    local API = Bagforge and Bagforge.API
	    if API then
	        API:RegisterCategory({
	            key = "myaddon.herbs", source = "MyAddon",
	            name = "Herbs", order = 13.5,
	            filter = function(entry) return entry.itemSubType == "Herb" end,
	        })
	        API:RegisterSortMode({
	            key = "myaddon.value", source = "MyAddon", label = "Vendor Value",
	            comparator = function(a, b)
	                local priceA = a.sellPrice or (a.itemID and ns.Scan and ns.Scan.GetSellPrice(a.itemID, a.hyperlink)) or 0
	                local priceB = b.sellPrice or (b.itemID and ns.Scan and ns.Scan.GetSellPrice(b.itemID, b.hyperlink)) or 0
	                return (priceA or 0) > (priceB or 0)
	            end,
	        })
	    end

	Registering after the player has logged in reclassifies the bags on the
	spot; the Item Sort dropdown and Plugins page are built once at login, so a
	sort/source added later only lists after a /reload.
--]]

local _, ns = ...
local F = ns.F

local type = type
local pairs = pairs
local pcall = pcall
local tsort = table.sort
local format = string.format

-- Per-source enable flags live in the profile: ns.db.plugins[sourceKey] = bool.
ns:RegisterDefaults({ plugins = {} })

local API = {}
ns.API = API
API.version = 2

local ScheduleButtonRefresh = F.DebounceNoArgs(0.05, function()
	if ns.UIRefresh then
		ns:UIRefresh({ paint = true })
	elseif ns.RefreshBags then
		ns:RefreshBags(false)
	end
end)

-- Coalesce a burst of registrations (a plugin adding several categories at once)
-- into a single rescan instead of one per call.
local ScheduleRefresh = F.DebounceNoArgs(0.05, function()
	if ns.db then
		if ns.ReclassifyBags then
			ns:ReclassifyBags()
		else
			ns:RefreshBags(true)
		end
	end
end)

-- ---------------------------------------------------------------------------
-- Registries
-- ---------------------------------------------------------------------------
local categoryDefs = {} -- array, sorted by priority then registration order
local categoryByKey = {} -- key -> def
local orderByName = {} -- category display name -> draw order
local sortDefs = {} -- array, registration order
local sortByKey = {} -- key -> def
local cornerDefs = {} -- array, sorted by priority
local cornerByKey = {} -- key -> def
local sources = {} -- sourceKey -> { key, name, categories = {key=name}, sorts = {key=label} }
local sourceOrder = {} -- array of sourceKey, first-seen order
local registerSeq = 0

-- ---------------------------------------------------------------------------
-- Sources (the owning plugin behind each registration)
-- ---------------------------------------------------------------------------
local function SanitizeKey(s)
	return (tostring(s):gsub("[^%w]", ""))
end

-- A registration's owning plugin: explicit `source`, else the leading token of
-- its key ("myaddon.herbs" -> "myaddon"), else the key itself.
local function DeriveSource(def)
	if type(def.source) == "string" and def.source ~= "" then
		return def.source
	end
	local key = def.key or ""
	return key:match("^([%w]+)[%.%-_]") or key
end

local function EnsureSource(displayName)
	local srcKey = SanitizeKey(displayName)
	if srcKey == "" then
		srcKey = "Plugin"
	end
	local src = sources[srcKey]
	if not src then
		src = { key = srcKey, name = displayName, categories = {}, sorts = {} }
		sources[srcKey] = src
		sourceOrder[#sourceOrder + 1] = srcKey
		-- Seed the per-source enable flag (default on) so the settings checkbox
		-- has a real boolean to bind to (Settings.RegisterAddOnSetting needs a
		-- typed default). Touch both the defaults tree and the live profile so a
		-- profile switch picks it up too; never clobber a saved choice.
		local defaults = ns.defaults and ns.defaults.profile and ns.defaults.profile.plugins
		if defaults and defaults[srcKey] == nil then
			defaults[srcKey] = true
		end
		if ns.db and ns.db.plugins and ns.db.plugins[srcKey] == nil then
			ns.db.plugins[srcKey] = true
		end
	end
	return src
end

--- Whether a plugin source is currently enabled (defaults to true).
function API:IsSourceEnabled(srcKey)
	local p = ns.db and ns.db.plugins
	if p and p[srcKey] ~= nil then
		return p[srcKey] and true or false
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Categories
-- ---------------------------------------------------------------------------
local function SortCategoryDefs()
	tsort(categoryDefs, function(a, b)
		local pa, pb = a.priority or 100, b.priority or 100
		if pa ~= pb then
			return pa < pb
		end
		return a._seq < b._seq
	end)
end

--- Register a bag category contributed by a plugin. `def`:
---   key       (string, required, unique) - identifier, e.g. "myaddon.herbs"
---   name      (string, required)         - panel name shown in the bag
---   filter    (function(entry)->boolean, required)
---   order     (number, optional)         - draw order (lower = nearer main bag)
---   priority  (number, optional)         - resolution order, lower wins (default 100)
---   enabled   (function->boolean, optional) - dynamic gate
---   source    (string, optional)         - owning plugin display name
--- Returns true on success.
function API:RegisterCategory(def)
	if type(def) ~= "table" or type(def.key) ~= "string" or def.key == "" then
		F.Print("|cffff5555API:|r RegisterCategory needs a unique string 'key'.")
		return false
	end
	if type(def.name) ~= "string" or def.name == "" or type(def.filter) ~= "function" then
		F.Print(format("|cffff5555API:|r category '%s' needs a 'name' and a 'filter' function.", def.key))
		return false
	end

	local existing = categoryByKey[def.key]
	if existing then
		-- Re-registration updates in place, keeping its slot.
		def._seq = existing._seq
		for i = 1, #categoryDefs do
			if categoryDefs[i] == existing then
				categoryDefs[i] = def
				break
			end
		end
	else
		registerSeq = registerSeq + 1
		def._seq = registerSeq
		categoryDefs[#categoryDefs + 1] = def
	end
	categoryByKey[def.key] = def

	local src = EnsureSource(DeriveSource(def))
	def._source = src.key
	src.categories[def.key] = def.name

	if type(def.order) == "number" then
		orderByName[def.name] = def.order
	end

	SortCategoryDefs()

	-- Reclassify so the new category takes effect once the world is ready.
	if ns.db then
		ScheduleRefresh()
	end
	return true
end

--- Classify `entry` through the registered plugin categories. Returns a category
--- name or nil. Each closure is pcall-guarded (a faulty plugin must not break the
--- scan) and skipped while its source is disabled. Called by Categories:GetCategory
--- after the player's own custom/search categories but before the built-in filters.
function API:GetItemCategory(entry)
	local defs = categoryDefs
	for i = 1, #defs do
		local def = defs[i]
		if self:IsSourceEnabled(def._source) then
			local active = true
			local gate = def.enabled
			if gate then
				local ok, res = pcall(gate)
				active = ok and res and true or false
			end
			if active then
				local ok, res = pcall(def.filter, entry)
				if ok and res then
					return def.name
				end
			end
		end
	end
	return nil
end

--- Draw order for a plugin category name, or nil. Consulted by Categories:GetOrder
--- after pinned/built-in/search orders, so the player can still pin a plugin panel.
function API:GetCategoryOrder(name)
	return orderByName[name]
end

function API:HasCategories()
	return #categoryDefs > 0
end

-- ---------------------------------------------------------------------------
-- Sort modes
-- ---------------------------------------------------------------------------
--- Register a within-category item sort mode. `def`:
---   key        (string, required, unique)
---   label      (string, required)  - shown in the Item Sort dropdown
---   comparator (function(a, b)->boolean, required) - a strict weak ordering
---   source     (string, optional)  - owning plugin display name
--- The scanner wraps the comparator (non-boolean/erroring results fall back to a
--- stable itemID tiebreak), and a bad ordering can never abort a scan.
function API:RegisterSortMode(def)
	if type(def) ~= "table" or type(def.key) ~= "string" or def.key == "" then
		F.Print("|cffff5555API:|r RegisterSortMode needs a unique string 'key'.")
		return false
	end
	if type(def.label) ~= "string" or def.label == "" or type(def.comparator) ~= "function" then
		F.Print(format("|cffff5555API:|r sort '%s' needs a 'label' and a 'comparator' function.", def.key))
		return false
	end

	if sortByKey[def.key] then
		for i = 1, #sortDefs do
			if sortDefs[i].key == def.key then
				sortDefs[i] = def
				break
			end
		end
	else
		sortDefs[#sortDefs + 1] = def
	end
	sortByKey[def.key] = def

	local src = EnsureSource(DeriveSource(def))
	def._source = src.key
	src.sorts[def.key] = def.label

	if ns.Scan and ns.Scan.RegisterWithin then
		ns.Scan.RegisterWithin(def.key, def.comparator)
	end

	-- If this is the player's saved sort (registered late, after OnInitialize
	-- already fell back to quality), apply it now.
	local o = ns.db and ns.db.organize
	if o and o.itemSort == def.key and ns.Scan and ns.Scan.SetSortMode then
		ns.Scan.SetSortMode(def.key)
		ScheduleRefresh()
	end
	return true
end

--- A sort mode is usable only while its source is enabled. Organize consults this
--- to validate the saved choice and to build the dropdown.
function API:IsSortActive(key)
	local def = sortByKey[key]
	return def ~= nil and self:IsSourceEnabled(def._source)
end

--- Dropdown choices (value/label) for the Item Sort control - enabled sources only.
function API:GetSortChoices()
	local out = {}
	for i = 1, #sortDefs do
		local def = sortDefs[i]
		if self:IsSourceEnabled(def._source) then
			out[#out + 1] = { value = def.key, label = def.label }
		end
	end
	return out
end

--- Numeric read with a fallback for plugin sort comparators.
function API:SafeSortNumber(value, fallback)
	if ns.Scan and ns.Scan.SafeSortNumber then
		return ns.Scan.SafeSortNumber(value, fallback or 0)
	end
	if value == nil then
		return fallback or 0
	end
	return value
end

-- ---------------------------------------------------------------------------
-- Corner widgets (per-item button overlays)
-- ---------------------------------------------------------------------------
local VALID_CORNERS = {
	topleft = true,
	topright = true,
	bottomleft = true,
	bottomright = true,
	left = true,
	right = true,
	top = true,
	bottom = true,	
	center = true,
}

local function SortCornerDefs()
	tsort(cornerDefs, function(a, b)
		local pa, pb = a.priority or 100, b.priority or 100
		if pa ~= pb then
			return pa < pb
		end
		return a._seq < b._seq
	end)
end

--- Register a corner overlay on bag item buttons. `def`:
---   key      (string, required, unique)
---   corner   (string, required) - topleft|topright|bottomleft|bottomright|left|right|center
---   update   (function(button, entry) -> show, atlas?, width?, height?, r?, g?, b?, a?)
---   priority (number, optional) - lower wins when multiple widgets share a corner
---   source   (string, optional)
function API:RegisterCornerWidget(def)
	if type(def) ~= "table" or type(def.key) ~= "string" or def.key == "" then
		F.Print("|cffff5555API:|r RegisterCornerWidget needs a unique string 'key'.")
		return false
	end
	local corner = def.corner and string.lower(def.corner)
	if not (corner and VALID_CORNERS[corner]) then
		F.Print(format("|cffff5555API:|r corner widget '%s' needs a valid 'corner'.", def.key))
		return false
	end
	if type(def.update) ~= "function" then
		F.Print(format("|cffff5555API:|r corner widget '%s' needs an 'update' function.", def.key))
		return false
	end
	def.corner = corner

	local existing = cornerByKey[def.key]
	if existing then
		def._seq = existing._seq
		for i = 1, #cornerDefs do
			if cornerDefs[i] == existing then
				cornerDefs[i] = def
				break
			end
		end
	else
		registerSeq = registerSeq + 1
		def._seq = registerSeq
		cornerDefs[#cornerDefs + 1] = def
	end
	cornerByKey[def.key] = def

	local src = EnsureSource(DeriveSource(def))
	def._source = src.key

	SortCornerDefs()
	if ns.db then
		ScheduleRefresh()
	end
	return true
end

function API:HasCornerWidget(key)
	return cornerByKey[key] ~= nil
end

--- Paint registered corner widgets on `button` for `entry`.
function API:UpdateCornerWidgets(button, entry, ensureTexture)
	if not (button and entry and ensureTexture) then
		return
	end
	local shown = {}
	for i = 1, #cornerDefs do
		local def = cornerDefs[i]
		local corner = def.corner
		if not shown[corner] and self:IsSourceEnabled(def._source) then
			local ok, show, atlas, width, height, r, g, b, a = pcall(def.update, button, entry)
			if ok and show then
				local tex = ensureTexture(button, corner)
				tex:SetAtlas(atlas or "bags-greenarrow")
				tex:SetSize(width or 16, height or 16)
				if r then
					tex:SetVertexColor(r, g or 1, b or 1, a or 1)
				else
					tex:SetVertexColor(1, 1, 1, 1)
				end
				tex:Show()
				shown[corner] = true
			end
		end
	end
	if button.bfCorners then
		for corner, tex in pairs(button.bfCorners) do
			if not shown[corner] then
				tex:Hide()
			end
		end
	end
end

local itemButtonCallbacks = {}
local junkDefs = {} -- array
local junkByKey = {}

-- ---------------------------------------------------------------------------
-- Junk detectors (Dejunk / Scrap / SellJunk-style third-party junk overlays)
-- ---------------------------------------------------------------------------

--- Register a junk detector. `def`:
---   key    (string, required, unique)
---   isJunk (function(bag, slot, entry) -> boolean, required)
---   source (string, optional) - owning plugin display name
function API:RegisterJunkDetector(def)
	if type(def) ~= "table" or type(def.key) ~= "string" or def.key == "" then
		F.Print("|cffff5555API:|r RegisterJunkDetector needs a unique string 'key'.")
		return false
	end
	if type(def.isJunk) ~= "function" then
		F.Print(format("|cffff5555API:|r junk detector '%s' needs an 'isJunk' function.", def.key))
		return false
	end

	local existing = junkByKey[def.key]
	if existing then
		def._seq = existing._seq
		for i = 1, #junkDefs do
			if junkDefs[i] == existing then
				junkDefs[i] = def
				break
			end
		end
	else
		registerSeq = registerSeq + 1
		def._seq = registerSeq
		junkDefs[#junkDefs + 1] = def
	end
	junkByKey[def.key] = def

	local src = EnsureSource(DeriveSource(def))
	def._source = src.key
	src.junk = src.junk or {}
	src.junk[def.key] = true

	if ns.db then
		ScheduleButtonRefresh()
	end
	return true
end

--- Remove a junk detector registered by `key` (plugin / JunkPlugins OnDisable).
function API:UnregisterJunkDetector(key)
	if type(key) ~= "string" or key == "" then
		return false
	end
	local existing = junkByKey[key]
	if not existing then
		return false
	end
	junkByKey[key] = nil
	for i = #junkDefs, 1, -1 do
		if junkDefs[i] == existing or (junkDefs[i] and junkDefs[i].key == key) then
			table.remove(junkDefs, i)
		end
	end
	if existing._source then
		local src = sources and sources[existing._source]
		if src and src.junk then
			src.junk[key] = nil
		end
	end
	if ns.db then
		ScheduleButtonRefresh()
	end
	return true
end

--- Whether `entry` should show the junk coin (built-in grey/custom junk + plugins).
function API:IsItemJunk(entry)
	if not entry then
		return false
	end
	local id = entry.itemID
	if not id then
		return false
	end
	local categories = ns:GetModule("Categories")
	if categories and categories.IsPetTrashItem and categories:IsPetTrashItem(id) then
		return false
	end
	local junkList = ns.global and ns.global.customJunk
	if junkList and junkList[id] then
		return true
	end
	local quality = entry.quality
	if quality == 0 and not entry.noValue then
		return true
	end
	for i = 1, #junkDefs do
		local def = junkDefs[i]
		if self:IsSourceEnabled(def._source) then
			local ok, res = pcall(def.isJunk, entry.bag, entry.slot, entry)
			if ok and res then
				return true
			end
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Item button callbacks (full-button overlays, e.g. TransmogLootHelper)
-- ---------------------------------------------------------------------------

--- Register a callback invoked whenever a bag item button is populated or cleared.
--- `func(button, bagID, slotID, entry)` — entry is nil when the slot is empty.
--- Mirrors OneWoW_Bags:RegisterItemButtonCallback for third-party overlay addons.
function API:RegisterItemButtonCallback(key, func)
	if type(key) ~= "string" or key == "" then
		F.Print("|cffff5555API:|r RegisterItemButtonCallback needs a unique string key.")
		return false
	end
	if type(func) ~= "function" then
		F.Print(format("|cffff5555API:|r item button callback '%s' needs a function.", key))
		return false
	end
	for i = 1, #itemButtonCallbacks do
		if itemButtonCallbacks[i].key == key then
			itemButtonCallbacks[i].func = func
			return true
		end
	end
	itemButtonCallbacks[#itemButtonCallbacks + 1] = { key = key, func = func }
	return true
end

--- Remove a previously registered item-button overlay callback.
function API:UnregisterItemButtonCallback(key)
	if type(key) ~= "string" or key == "" then
		return false
	end
	for i = #itemButtonCallbacks, 1, -1 do
		if itemButtonCallbacks[i].key == key then
			table.remove(itemButtonCallbacks, i)
			return true
		end
	end
	return false
end

--- Ask Bagforge to redraw visible item buttons (display-only; no rescan).
--- Optional `reason` mirrors Baganator RefreshReason / ns.C.RefreshReason:
---   paint | headers | layout | reclassify | chrome (default paint, debounced).
function API:RequestItemButtonsRefresh(reason)
	local paint = (ns.C and ns.C.RefreshReason and ns.C.RefreshReason.paint) or "paint"
	reason = reason or paint
	if reason == paint then
		ScheduleButtonRefresh()
		return
	end
	if ns.UIRefresh then
		ns:UIRefresh({ [reason] = true })
	else
		ScheduleButtonRefresh()
	end
end

function API:_FireItemButtonCallbacks(button, bagID, slotID, entry)
	for i = 1, #itemButtonCallbacks do
		local cb = itemButtonCallbacks[i]
		local ok, err = pcall(cb.func, button, bagID, slotID, entry)
		if not ok and F.Print then
			F.Print(format("|cffff5555API:|r item button callback '%s' failed: %s", cb.key, tostring(err)))
		end
	end
end

-- ---------------------------------------------------------------------------
-- Introspection (settings Plugins page)
-- ---------------------------------------------------------------------------
function API:HasPlugins()
	for i = 1, #sourceOrder do
		local src = sources[sourceOrder[i]]
		if src and (next(src.categories) or next(src.sorts) or (src.junk and next(src.junk))) then
			return true
		end
	end
	return false
end

--- Snapshot of installed plugin sources for the settings page. Each entry:
---   { key, name, enabled, categories = { sorted names }, sorts = { sorted labels } }
--- Corner widgets and item-button callbacks do not create Plugins entries.
function API:GetSources()
	local out = {}
	for i = 1, #sourceOrder do
		local src = sources[sourceOrder[i]]
		if src then
			local cats, srt, junk = {}, {}, {}
			for _, name in pairs(src.categories) do
				cats[#cats + 1] = name
			end
			for _, label in pairs(src.sorts) do
				srt[#srt + 1] = label
			end
			if src.junk then
				for key in pairs(src.junk) do
					junk[#junk + 1] = key
				end
			end
			if #cats == 0 and #srt == 0 and #junk == 0 then
				-- Overlay-only registrations (e.g. built-in Pawn arrows) belong on
				-- Item Display, not the Plugins source toggle list.
			else
				tsort(cats)
				tsort(srt)
				tsort(junk)
				out[#out + 1] = {
					key = src.key,
					name = src.name,
					enabled = self:IsSourceEnabled(src.key),
					categories = cats,
					sorts = srt,
					junk = junk,
				}
			end
		end
	end
	return out
end
