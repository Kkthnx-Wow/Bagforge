--[[
	Bagforge - Options
	-------------------------------------------------------------------------
	Settings-menu integration, modelled on NexEnhance's config so the two
	addons feel the same. A single vertical-layout category lives under the
	game's Settings panel (Game Menu > Options > AddOns > Bagforge). Each module
	that wants options exposes `module:RegisterOptions(category, builder)` and
	draws its controls through the shared `OptionBuilder`.

	Bindings go straight through Blizzard's modern Settings API
	(`Settings.RegisterAddOnSetting`), which reads/writes `ns.db[dbKey][key]`
	for us. On change we call the module's `OnSettingChanged` for live apply and
	broadcast on the internal bus so other modules can react without a hard
	reference (subscribe via "SettingChanged.<dbKey>.<key>").
--]]

local _, ns = ...
local L, F = ns.L, ns.F
local format = string.format

-- ---------------------------------------------------------------------------
-- Live apply
-- ---------------------------------------------------------------------------
local function ApplyModuleSetting(module, key, value)
	-- Bank uses `active` / `warband` as per-view toggles, not module lifecycle.
	local isMasterEnable = key == "enable" or (key == "active" and module.dbKey ~= "bank")
	if isMasterEnable then
		ns:ApplyModuleEnable(module, value and true or false)
	elseif module.OnSettingChanged then
		module:OnSettingChanged(key, value)
	end
	if module.dbKey then
		ns:TriggerCallback("SettingChanged." .. module.dbKey .. "." .. key, value, module)
	end
end

-- ---------------------------------------------------------------------------
-- Builder
--   `module` must carry a `dbKey`; the setting is bound to ns.db[dbKey][key]
--   with the registered default pulled from ns.defaults.profile[dbKey][key].
-- ---------------------------------------------------------------------------
local OptionBuilder = {}

local function GetDefault(module, key)
	local defaults = ns.defaults.profile[module.dbKey]
	return defaults and defaults[key]
end

local function RegisterSetting(category, module, key, name)
	local variableTbl = ns.db[module.dbKey]
	if not variableTbl then
		return
	end
	local defaultValue = GetDefault(module, key)
	local variable = ns.name .. "_" .. module.dbKey .. "_" .. key
	local setting = Settings.RegisterAddOnSetting(category, variable, key, variableTbl, type(defaultValue), name, defaultValue)
	setting:SetValueChangedCallback(function(_, value)
		ApplyModuleSetting(module, key, value)
	end)
	return setting
end

function OptionBuilder:Checkbox(category, module, key, name, tooltip)
	local setting = RegisterSetting(category, module, key, name)
	if not setting then
		return
	end
	local initializer = Settings.CreateCheckbox(category, setting, tooltip)
	return setting, initializer
end

function OptionBuilder:Slider(category, module, key, name, tooltip, minValue, maxValue, step)
	local setting = RegisterSetting(category, module, key, name)
	if not setting then
		return
	end
	local options = Settings.CreateSliderOptions(minValue, maxValue, step)
	if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
		options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
	end
	local initializer = Settings.CreateSlider(category, setting, options, tooltip)
	return setting, initializer
end

-- `choices` is an array of { value = <number>, label = <string>, tooltip = <string> }.
function OptionBuilder:Dropdown(category, module, key, name, tooltip, choices)
	if not Settings.CreateDropdown then
		return
	end
	local setting = RegisterSetting(category, module, key, name)
	if not setting then
		return
	end
	local function GetOptions()
		local container = Settings.CreateControlTextContainer()
		for i = 1, #choices do
			local choice = choices[i]
			container:Add(choice.value, choice.label, choice.tooltip)
		end
		return container:GetData()
	end
	local initializer = Settings.CreateDropdown(category, setting, GetOptions, tooltip)
	return setting, initializer
end

-- Section header inside the page (mid-list grouping of related controls).
function OptionBuilder:Header(text)
	local layout = self.layout
	if layout and _G["CreateSettingsListSectionHeaderInitializer"] then
		layout:AddInitializer(_G["CreateSettingsListSectionHeaderInitializer"](text))
	end
end

-- A clickable button row (used to open auxiliary windows like the category
-- manager). `label` is the left-hand text, `buttonText` the button caption.
function OptionBuilder:Button(label, buttonText, onClick, tooltip)
	local layout = self.layout
	local create = _G["CreateSettingsButtonInitializer"]
	if layout and create then
		-- Midnight's Settings helper asserts that addSearchTags is explicitly
		-- provided; omitting it aborts the module's RegisterOptions after the
		-- section header, which leaves a blank "Category Manager" block.
		layout:AddInitializer(create(label, buttonText, onClick, tooltip, true))
	end
end

-- Grey out and disable `child` whenever the `parent` toggle is off. Both are the
-- *initializers* returned as the 2nd value from Checkbox/Slider/Dropdown.
function OptionBuilder:DependsOn(child, parent)
	if not (child and parent and child.SetParentInitializer) then
		return
	end
	child:SetParentInitializer(parent, function()
		local setting = parent:GetSetting()
		return setting and setting:GetValue()
	end)
end

-- ---------------------------------------------------------------------------
-- Sidebar groups (sub-trees)
--   Each module declares a `group` key. The "general" group renders on the
--   parent "Bagforge" page; every other group becomes its own vertical-layout
--   subcategory in the Settings sidebar (NexEnhance-style). New groups just need
--   an entry here and a matching module.group.
-- ---------------------------------------------------------------------------
local GROUPS = {
	{ key = "general", parent = true, title = L["General"] },
	{ key = "display", title = L["Item Display"], icon = [[Interface\ICONS\INV_Misc_Note_01]] },
	{ key = "filters", title = L["Filters"], icon = [[Interface\ICONS\INV_Misc_Spyglass_02]] },
	{ key = "extras", title = L["Extras"], icon = [[Interface\ICONS\INV_Gizmo_01]] },
	{ key = "plugins", title = L["Plugins"], icon = [[Interface\ICONS\INV_Misc_Gear_01]] },
}

local GROUP_INDEX = {}
for i = 1, #GROUPS do
	GROUP_INDEX[GROUPS[i].key] = i
end

-- Sidebar label with an inline icon (texture path -> |T escape). Sorting uses
-- the clean title; the icon is decoration only.
local function GroupLabel(group)
	if group.icon then
		return format("|T%s:16:16:0:0|t %s", group.icon, group.title)
	end
	return group.title
end

-- ---------------------------------------------------------------------------
-- Build the category (once, at login)
-- ---------------------------------------------------------------------------
local function SortModules(a, b)
	local ga = GROUP_INDEX[a.group or "general"] or math.huge
	local gb = GROUP_INDEX[b.group or "general"] or math.huge
	if ga ~= gb then
		return ga < gb
	end
	local oa, ob = a.order or 100, b.order or 100
	if oa ~= ob then
		return oa < ob
	end
	return a.name < b.name
end

local function BuildOptions()
	if not (Settings and Settings.RegisterVerticalLayoutCategory) then
		return
	end

	local category, layout = Settings.RegisterVerticalLayoutCategory(ns.title)
	ns.settingsCategory = category

	-- Stable layout regardless of module registration order.
	local ordered = {}
	for i = 1, #ns.modules do
		ordered[i] = ns.modules[i]
	end
	table.sort(ordered, SortModules)

	-- Which groups actually have option-bearing modules, so we never spawn an
	-- empty sidebar page.
	local groupUsed = {}
	for i = 1, #ordered do
		local module = ordered[i]
		if module.RegisterOptions then
			groupUsed[module.group or "general"] = true
		end
	end

	-- One vertical-layout subcategory per used non-parent group (in GROUPS order
	-- so the sidebar reads top-to-bottom predictably). The "general" group maps
	-- to the parent page. Falls back to the single parent page on older clients.
	local pageCategory = { general = category }
	local pageLayout = { general = layout }
	local canSub = Settings.RegisterVerticalLayoutSubcategory ~= nil
	if canSub then
		for i = 1, #GROUPS do
			local group = GROUPS[i]
			if not group.parent and groupUsed[group.key] then
				local sub, subLayout = Settings.RegisterVerticalLayoutSubcategory(category, GroupLabel(group))
				pageCategory[group.key] = sub
				pageLayout[group.key] = subLayout
			end
		end
	end

	for i = 1, #ordered do
		local module = ordered[i]
		if module.RegisterOptions then
			local key = pageCategory[module.group or "general"] and (module.group or "general") or "general"
			OptionBuilder.layout = pageLayout[key]
			OptionBuilder:Header(module.title or module.name)
			-- Isolate each module's options build (same reason OnEnable is pcall'd):
			-- one module throwing must not abort the loop and leave the whole
			-- category unregistered - that would make every Bagforge option vanish
			-- from the Settings panel. Print the culprit instead.
			local ok, err = pcall(module.RegisterOptions, module, pageCategory[key], OptionBuilder)
			if not ok then
				F.Print(format(L["Options error in %s:"], module.name), err)
			end
			OptionBuilder.layout = nil
		end
	end

	Settings.RegisterAddOnCategory(category)

	function ns:OpenOptions()
		if Settings.OpenToCategory then
			local id = category.GetID and category:GetID() or category.ID
			Settings.OpenToCategory(id)
		end
	end
end

ns:RegisterEvent("PLAYER_LOGIN", BuildOptions)

-- Fallback so /bf config works even on a flavour without the Settings API.
function ns:OpenOptions()
	F.Print(format(L["Open %s through Game Menu > Options > AddOns."], ns.title))
end
