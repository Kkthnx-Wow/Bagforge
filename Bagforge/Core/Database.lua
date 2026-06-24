--[[
	Bagforge - Database
	-------------------------------------------------------------------------
	Lightweight saved-variable manager with profile support, modelled on the
	AceDB layout but with zero external dependencies. Modules register their
	defaults at file-run time via `ns:RegisterDefaults`, then read/write through
	`ns.db` (the active profile) once it's built on ADDON_LOADED.

	Layout of the `BagforgeDB` saved variable:
	    {
	        profiles    = { ["Default"] = { ...settings... } },
	        profileKeys = { ["Name - Realm"] = "Default" },
	        global      = { ...account-wide data... },
	    }
--]]

local _, ns = ...
local C, F = ns.C, ns.F

-- The master default tree. Modules merge their own sub-tables into `profile`.
ns.defaults = {
	profile = {},
	global = {},
}

--- Merge a table of defaults into the profile (or global) defaults. Called by
--- modules at file-run time, before the DB is built:
---     ns:RegisterDefaults({ backpack = { columns = 12 } })
function ns:RegisterDefaults(defaults, scope)
	scope = scope or "profile"
	F.CopyDefaults(defaults, ns.defaults[scope])
end

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------

--- Switch the active profile, rebuilding `ns.db` and notifying listeners.
function ns:SetProfile(profileName)
	local root = _G.BagforgeDB
	root.profileKeys[C.Player.key] = profileName
	root.profiles[profileName] = root.profiles[profileName] or {}

	ns.db = F.CopyDefaults(ns.defaults.profile, root.profiles[profileName])
	ns.profileName = profileName

	ns:TriggerCallback("Profile.Changed", profileName)
end

-- ---------------------------------------------------------------------------
-- Setup (called by the engine on ADDON_LOADED, before module OnInitialize)
-- ---------------------------------------------------------------------------
function ns:SetupDatabase()
	C.RefreshPlayer()

	-- Saved variables are nil on a brand-new install; create the skeleton.
	local root = _G.BagforgeDB or {}
	_G.BagforgeDB = root
	root.profiles = root.profiles or {}
	root.profileKeys = root.profileKeys or {}
	root.global = F.CopyDefaults(ns.defaults.global, root.global)

	_G.BagforgeCharDB = _G.BagforgeCharDB or {}

	ns.global = root.global
	ns.charDB = _G.BagforgeCharDB

	-- This character's profile (defaults to its own key on first login).
	local profileName = root.profileKeys[C.Player.key] or "Default"
	ns:SetProfile(profileName)
end
