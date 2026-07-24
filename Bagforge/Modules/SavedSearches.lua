--[[
	Bagforge - Saved Searches
	-------------------------------------------------------------------------
	Named, account-wide search presets (Baganator parity). The player types a
	query into any Bagforge search box, right-clicks the box, and saves it under
	a name. Recalling one writes the query back into the box, which drives
	Blizzard's native bag filter (BagSearch_OnTextChanged -> C_Container.SetItemSearch).

	  * Right-click any search box : open the saved-search menu.
	  * Save Current Search...     : name and store the box's current text.
	  * Click a saved search       : apply it to the box.
	  * Delete > / Clear All       : manage the list.

	Storage is account-wide (ns.global.savedSearches) so presets follow the
	player across characters, matching Baganator's saved_searches scope. The
	list is an ordered array of { name = <string>, query = <string> }.
--]]

local _, ns = ...
local F, L = ns.F, ns.L

local MenuUtil = _G["MenuUtil"]
local StaticPopup_Show = _G["StaticPopup_Show"]
local StaticPopupDialogs = _G["StaticPopupDialogs"]
local GameTooltip_SetTitle = _G["GameTooltip_SetTitle"]
local GameTooltip_AddNormalLine = _G["GameTooltip_AddNormalLine"]

local tinsert = table.insert
local tremove = table.remove
local wipe = wipe
local format = string.format
local strtrim = strtrim

local MAX_SAVED = 50
local MAX_NAME = 48

-- Account-wide preset list: { { name = , query = }, ... }. Registered at file
-- load so SetupDatabase seeds ns.global.savedSearches before any menu opens.
ns:RegisterDefaults({ savedSearches = {} }, "global")

local SavedSearches = ns:NewModule("SavedSearches")
ns.SavedSearches = SavedSearches

-- Boxes we've already wired, so re-decorating a rebuilt window can't double-hook.
local attached = setmetatable({}, { __mode = "k" })

local function Store()
	return ns.global and ns.global.savedSearches
end

local function Trim(text)
	if type(text) ~= "string" then
		return ""
	end
	return strtrim and strtrim(text) or text
end

local function FindIndex(list, name)
	for i = 1, #list do
		if list[i].name == name then
			return i
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Store operations
-- ---------------------------------------------------------------------------

--- Ordered copy of the preset list (safe for the caller to iterate).
function SavedSearches:GetAll()
	return Store() or {}
end

--- Save (or overwrite by name) a preset. Returns true on success.
function SavedSearches:Save(name, query)
	name = Trim(name)
	query = Trim(query)
	if name == "" then
		F.Print(L["Enter a name for the saved search."])
		return false
	end
	if query == "" then
		F.Print(L["The search box is empty - nothing to save."])
		return false
	end
	local list = Store()
	if not list then
		return false
	end
	local idx = FindIndex(list, name)
	if idx then
		list[idx].query = query
		F.Print(format(L["Updated saved search '%s'."], name))
		return true
	end
	if #list >= MAX_SAVED then
		F.Print(format(L["You can only keep %d saved searches."], MAX_SAVED))
		return false
	end
	tinsert(list, { name = name, query = query })
	F.Print(format(L["Saved search '%s'."], name))
	return true
end

--- Remove a preset by name.
function SavedSearches:Delete(name)
	local list = Store()
	if not list then
		return
	end
	local idx = FindIndex(list, name)
	if idx then
		tremove(list, idx)
		F.Print(format(L["Deleted saved search '%s'."], name))
	end
end

--- Wipe every preset.
function SavedSearches:Clear()
	local list = Store()
	if list and #list > 0 then
		wipe(list)
		F.Print(L["Cleared all saved searches."])
	end
end

--- Write `query` into `box`; BagSearchBoxTemplate's OnTextChanged then drives
--- the native bag filter (C_Container.SetItemSearch) and syncs sibling boxes.
function SavedSearches:Apply(box, query)
	if not (box and box.SetText and type(query) == "string") then
		return
	end
	box:SetText(query)
	if box.ClearFocus then
		box:ClearFocus()
	end
end

-- ---------------------------------------------------------------------------
-- UI: name prompt + context menu
-- ---------------------------------------------------------------------------

function SavedSearches:PromptSave(query)
	if not StaticPopup_Show then
		return
	end
	local dialog = StaticPopup_Show("BAGFORGE_SAVE_SEARCH")
	if dialog then
		dialog.data = Trim(query)
	end
end

function SavedSearches:OpenMenu(box)
	if not MenuUtil then
		return
	end
	local current = box and box.GetText and Trim(box:GetText()) or ""

	MenuUtil.CreateContextMenu(box, function(_, root)
		root:SetTag("MENU_BAGFORGE_SAVED_SEARCHES")
		root:CreateTitle(L["Saved Searches"])

		local save = root:CreateButton(L["Save Current Search..."], function()
			SavedSearches:PromptSave(current)
		end)
		if current == "" and save and save.SetEnabled then
			save:SetEnabled(false)
		end

		local list = SavedSearches:GetAll()
		if #list == 0 then
			return
		end

		if root.CreateDivider then
			root:CreateDivider()
		end
		for i = 1, #list do
			local item = list[i]
			local entry = root:CreateButton(item.name, function()
				SavedSearches:Apply(box, item.query)
			end)
			if entry and entry.SetTooltip and GameTooltip_SetTitle then
				entry:SetTooltip(function(tooltip)
					GameTooltip_SetTitle(tooltip, item.name)
					if GameTooltip_AddNormalLine then
						GameTooltip_AddNormalLine(tooltip, item.query)
					end
				end)
			end
		end

		if root.CreateDivider then
			root:CreateDivider()
		end
		local del = root:CreateButton(L["Delete"])
		for i = 1, #list do
			local item = list[i]
			del:CreateButton(item.name, function()
				SavedSearches:Delete(item.name)
			end)
		end
		root:CreateButton(L["Clear All Saved Searches"], function()
			if StaticPopup_Show then
				StaticPopup_Show("BAGFORGE_CLEAR_SAVED_SEARCHES")
			end
		end)
	end)
end

-- ---------------------------------------------------------------------------
-- Attachment: wire a search box's right-click to the menu
-- ---------------------------------------------------------------------------

--- Called by ContainerWindow:CreateSearchBox for every search field. The
--- SearchBoxTemplate edit box defines no mouse scripts of its own, so a plain
--- hook is safe and non-invasive.
function SavedSearches:Attach(box)
	if not box or attached[box] then
		return
	end
	attached[box] = true
	box:HookScript("OnMouseUp", function(self, button)
		if button == "RightButton" then
			SavedSearches:OpenMenu(self)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Popups
-- ---------------------------------------------------------------------------

local function GetPopupEditText(popup)
	local editBox = popup and (popup.EditBox or popup.editBox)
	return editBox and editBox:GetText() or ""
end

function SavedSearches:OnEnable()
	if not StaticPopupDialogs then
		return
	end

	StaticPopupDialogs["BAGFORGE_SAVE_SEARCH"] = {
		text = L["Name this search:"],
		button1 = _G["ACCEPT"] or "Accept",
		button2 = _G["CANCEL"] or "Cancel",
		hasEditBox = true,
		maxLetters = MAX_NAME,
		OnAccept = function(popup, data)
			SavedSearches:Save(GetPopupEditText(popup), data)
		end,
		EditBoxOnEnterPressed = function(editBox)
			local popup = editBox:GetParent()
			SavedSearches:Save(editBox:GetText(), popup.data)
			popup:Hide()
		end,
		EditBoxOnEscapePressed = function(editBox)
			editBox:GetParent():Hide()
		end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
	}

	StaticPopupDialogs["BAGFORGE_CLEAR_SAVED_SEARCHES"] = {
		text = L["Delete every saved search?"],
		button1 = _G["YES"] or "Yes",
		button2 = _G["NO"] or "No",
		OnAccept = function()
			SavedSearches:Clear()
		end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
	}
end
