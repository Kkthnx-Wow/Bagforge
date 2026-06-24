--[[
	Bagforge - Engine
	-------------------------------------------------------------------------
	The engine owns the addon namespace, the module system, a single shared
	event dispatcher and the load lifecycle. Every other file consumes the
	namespace handed to it by WoW via `local addonName, ns = ...`.

	Design goals (lifted wholesale from NexEnhance, which got them right):
	  * One global only (`_G.Bagforge`) - everything else lives on `ns`.
	  * One event frame for the whole addon; modules subscribe through it
	    instead of each spawning their own frame and double-registering.
	  * Clear lifecycle: OnInitialize (DB ready) -> OnEnable (world ready).
--]]

local addonName, ns = ...

-- One global handle for debugging and inter-addon access. That's the budget.
_G.Bagforge = ns

local CreateFrame = CreateFrame
local IsLoggedIn = IsLoggedIn
local tinsert = table.insert
local format = string.format
local C_AddOns = C_AddOns

-- ---------------------------------------------------------------------------
-- Metadata
-- ---------------------------------------------------------------------------
ns.name = addonName
ns.title = C_AddOns.GetAddOnMetadata(addonName, "Title") or addonName
ns.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "0.0.0"

-- Sub-namespaces populated by the other core files. Declared here so load
-- order never produces a nil index.
ns.C = ns.C or {} -- Constants
ns.F = ns.F or {} -- Functions
ns.L = ns.L or setmetatable({}, {
	__index = function(_, key)
		return key
	end,
}) -- Locale (fallback to the key itself)

-- ---------------------------------------------------------------------------
-- Module registry
-- ---------------------------------------------------------------------------
local modules = {} -- ordered list (preserves registration order for OnEnable)
local moduleByName = {} -- name -> module lookup

ns.modules = modules

local moduleMeta = {}
moduleMeta.__index = moduleMeta

--- Register an event against this module. The handler may be a function or
--- the name of a method on the module. When omitted, a method named exactly
--- after the event is used (the common WoW convention).
function moduleMeta:RegisterEvent(event, handler)
	handler = handler or self[event]
	if type(handler) == "string" then
		handler = self[handler]
	end
	assert(type(handler) == "function", ("Bagforge: no handler for event '%s' on module '%s'"):format(event, self.name))

	-- Bind `self` once at registration time so the dispatch path stays cheap.
	ns:RegisterEvent(event, function(_, ...)
		handler(self, ...)
	end)
end

--- Whether this module is enabled in the active profile. Modules that opt into
--- the toggle convention store `enable` under `db[dbKey]`.
function moduleMeta:IsEnabled()
	if not ns.db then
		return false
	end
	local settings = self.dbKey and ns.db[self.dbKey]
	if settings and settings.enable ~= nil then
		return settings.enable
	end
	return true
end

--- Create (or fetch) a module. `dbKey` ties the module to a settings table in
--- the active profile so `module:IsEnabled()` works out of the box.
function ns:NewModule(name, dbKey)
	assert(not moduleByName[name], ("Bagforge: module '%s' already exists"):format(name))

	local module = setmetatable({ name = name, dbKey = dbKey }, moduleMeta)
	moduleByName[name] = module
	tinsert(modules, module)
	return module
end

function ns:GetModule(name)
	return moduleByName[name]
end

-- ---------------------------------------------------------------------------
-- Central event dispatcher
--   One frame for the whole addon. Each event maps to an array of callbacks
--   invoked in registration order. Arrays (not hash sets) keep dispatch
--   allocation-free and ordered. Tombstoned slots make it mid-dispatch safe:
--   a callback may unregister itself or others while firing.
-- ---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "BagforgeEventFrame")
local eventCallbacks = {} -- event -> { callback, callback, ... }

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local callbacks = eventCallbacks[event]
	if not callbacks then
		return
	end
	for i = 1, #callbacks do
		local callback = callbacks[i]
		if callback then
			callback(event, ...)
		end
	end
end)

function ns:RegisterEvent(event, callback)
	local callbacks = eventCallbacks[event]
	if not callbacks then
		callbacks = {}
		eventCallbacks[event] = callbacks
		eventFrame:RegisterEvent(event)
	end
	-- Refill a tombstoned slot if one exists so add/remove cycles don't grow
	-- the array; this never shifts indices, so it's safe mid-dispatch.
	for i = 1, #callbacks do
		if not callbacks[i] then
			callbacks[i] = callback
			return callback
		end
	end
	callbacks[#callbacks + 1] = callback
	return callback
end

function ns:UnregisterEvent(event, callback)
	local callbacks = eventCallbacks[event]
	if not callbacks then
		return
	end

	local anyLive = false
	for i = 1, #callbacks do
		if callbacks[i] == callback then
			callbacks[i] = false
		elseif callbacks[i] then
			anyLive = true
		end
	end

	if not anyLive then
		eventCallbacks[event] = nil
		eventFrame:UnregisterEvent(event)
	end
end

-- ---------------------------------------------------------------------------
-- Internal signal bus (pub/sub)
--   The dispatcher above is for *WoW game events*. This bus is for *internal*
--   addon signals so modules can react to one another without holding hard
--   references - e.g. Items broadcasts "Items.Updated" and Backpack redraws.
-- ---------------------------------------------------------------------------
local signalCallbacks = {} -- signal -> { { callback, owner, isMethod }, ... }

function ns:RegisterCallback(signal, callback, owner)
	local list = signalCallbacks[signal]
	if not list then
		list = {}
		signalCallbacks[signal] = list
	end
	list[#list + 1] = { callback, owner, type(callback) == "string" }
	return callback
end

function ns:TriggerCallback(signal, ...)
	local list = signalCallbacks[signal]
	if not list then
		return
	end
	for i = 1, #list do
		local cb = list[i]
		if cb then
			if cb[3] then
				cb[2][cb[1]](cb[2], ...) -- owner:method(...)
			elseif cb[2] then
				cb[1](cb[2], ...) -- func(owner, ...)
			else
				cb[1](...) -- func(...)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
--   ADDON_LOADED -> Initialize() : saved variables are ready, build the DB
--                                  and run each module's OnInitialize.
--   PLAYER_LOGIN  -> Enable()    : the world is ready, run each enabled
--                                  module's OnEnable.
--   The flags keep both paths idempotent and handle a late (LoadOnDemand)
--   load where PLAYER_LOGIN has already fired.
-- ---------------------------------------------------------------------------
local initialized, enabled = false, false

local function RunCallback(module, method)
	local fn = module[method]
	if type(fn) ~= "function" then
		return
	end

	-- Isolate module faults so one broken module can't abort the rest.
	local ok, err = pcall(fn, module)
	if not ok then
		ns.F.Print(format(ns.L["Error in %s (%s):"], module.name, method), err)
	end
end

local function Enable()
	if enabled or not initialized then
		return
	end
	enabled = true

	for i = 1, #modules do
		local module = modules[i]
		if module:IsEnabled() then
			RunCallback(module, "OnEnable")
		end
	end
end

local function Initialize()
	if initialized then
		return
	end
	initialized = true

	-- Saved variables are guaranteed to exist by ADDON_LOADED, so the DB is
	-- built here, before any module touches `ns.db`.
	if ns.SetupDatabase then
		ns:SetupDatabase()
	end

	for i = 1, #modules do
		RunCallback(modules[i], "OnInitialize")
	end

	-- Late load (after login): PLAYER_LOGIN will not fire again, enable now.
	if IsLoggedIn() then
		Enable()
	end
end

local onAddonLoaded
onAddonLoaded = function(_, loadedAddon)
	if loadedAddon ~= addonName then
		return
	end
	ns:UnregisterEvent("ADDON_LOADED", onAddonLoaded) -- one-shot
	Initialize()
end

ns:RegisterEvent("ADDON_LOADED", onAddonLoaded)
ns:RegisterEvent("PLAYER_LOGIN", Enable)
