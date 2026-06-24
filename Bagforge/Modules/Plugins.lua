--[[
	Bagforge - Plugins (settings page)
	-------------------------------------------------------------------------
	A read-and-toggle list of the plugins registered through Bagforge.API
	(Core/API.lua). Each installed plugin "source" gets one checkbox: on means
	its categories and sort modes are live, off hides them. The checkbox tooltip
	spells out exactly what the plugin contributes.

	Lives under its own "Plugins" sidebar sub-category. The list is built once at
	login (like the rest of the options), so a plugin that registers after login
	only appears after a /reload.
--]]

local _, ns = ...
local L = ns.L
local format = string.format
local tconcat = table.concat

-- dbKey "plugins" binds the per-source checkboxes to ns.db.plugins[sourceKey]
-- (seeded to true by the API when a source first registers).
local Plugins = ns:NewModule("Plugins", "plugins")
Plugins.title = L["Plugins"]
Plugins.order = 10
Plugins.group = "plugins"

local sourceTooltipScratch = {}

-- Tooltip describing what a source contributes plus the toggle hint.
local function SourceTooltip(src)
	local lines = sourceTooltipScratch
	wipe(lines)
	local n = 0
	if #src.categories > 0 then
		n = n + 1
		lines[n] = format(L["Categories: %s"], tconcat(src.categories, ", "))
	end
	if #src.sorts > 0 then
		n = n + 1
		lines[n] = format(L["Sort modes: %s"], tconcat(src.sorts, ", "))
	end
	n = n + 1
	lines[n] = L["Uncheck to disable this plugin's categories and sort options."]
	return tconcat(lines, "|n", 1, n)
end

--- A source was toggled: re-validate the item sort (a plugin sort whose source we
--- just disabled must fall back) and reclassify so its categories appear/vanish.
function Plugins:OnSettingChanged()
	local organize = ns:GetModule("Organize")
	if organize and organize.ValidateSortMode then
		organize:ValidateSortMode()
	end
	ns:RefreshBags(true)
end

function Plugins:RegisterOptions(category, builder)
	if not (ns.API and ns.API:HasPlugins()) then
		builder:Header(L["No plugins installed."])
		return
	end

	local sources = ns.API:GetSources()
	for i = 1, #sources do
		local src = sources[i]
		builder:Checkbox(category, self, src.key, src.name, SourceTooltip(src))
	end
end
