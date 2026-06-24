--[[
	Bagforge - Commands
	-------------------------------------------------------------------------
	The single slash-command entry point. Parses the first word and dispatches
	via a lookup table so new commands don't grow another if-chain.
--]]

local _, ns = ...
local L, F = ns.L, ns.F
local format = string.format

local function ShowHelp()
	F.Print(L["Commands"] .. " (" .. L["/bf"] .. "):")
	F.Print("  " .. L["toggle - Open or close the bags"])
	F.Print("  " .. L["config - Open the settings panel"])
	F.Print("  " .. L["open - Open the bags"])
	F.Print("  " .. L["close - Close the bags"])
	F.Print("  " .. L["sort - Sort and stack the bags"])
	F.Print("  " .. L["sortbank - Sort the character bank"])
	F.Print("  " .. L["sortwarbank - Sort the warband bank"])
	F.Print("  " .. L["depositbank - Deposit items into the character bank"])
	F.Print("  " .. L["depositwarbank - Deposit items into the warband bank"])
	F.Print("  " .. L["reset - Reset the bag position"])
	F.Print("  " .. L["columns <number> - Set item columns"])
	F.Print("  " .. L["bankcolumns <number> - Set character bank columns"])
	F.Print("  " .. L["warbandcolumns <number> - Set warband bank columns"])
	F.Print("  " .. L["resetbank - Reset the character bank position"])
	F.Print("  " .. L["resetwarbank - Reset the warband bank position"])
	F.Print("  " .. L["filter <name> on|off - Toggle a category filter"])
	F.Print("  " .. L["cat <add|remove|clear|order|list> - Manage custom categories"])
	F.Print("  " .. L["junk <add|remove|clear|list> - Manage custom junk"])
	F.Print("  " .. L["testextslots [on|off] - Preview authenticator backpack slots"])
end

local exactCommands = {
	sort = function()
		local items = ns:GetModule("Items")
		if items then
			items:Sort()
		end
	end,
	sortbank = function()
		local bank = ns:GetModule("Bank")
		if bank then
			bank:Sort(false)
		end
	end,
	sortwarbank = function()
		local bank = ns:GetModule("Bank")
		if bank then
			bank:Sort(true)
		end
	end,
	depositbank = function()
		local bank = ns:GetModule("Bank")
		if bank then
			bank:DepositAll(false)
		end
	end,
	depositwarbank = function()
		local bank = ns:GetModule("Bank")
		if bank then
			bank:DepositAll(true)
		end
	end,
	reset = function()
		local backpack = ns:GetModule("Backpack")
		if backpack then
			backpack:ResetPosition()
		end
	end,
	resetbank = function()
		local bank = ns:GetModule("Bank")
		if bank then
			bank:ResetPosition()
		end
	end,
	config = function()
		if ns.OpenOptions then
			ns:OpenOptions()
		end
	end,
	open = function()
		local backpack = ns:GetModule("Backpack")
		if backpack then
			backpack:Open()
		end
	end,
	close = function()
		local backpack = ns:GetModule("Backpack")
		if backpack then
			backpack:Close()
		end
	end,
	toggle = function()
		local backpack = ns:GetModule("Backpack")
		if backpack then
			backpack:Toggle()
		end
	end,
	[""] = function()
		exactCommands.toggle()
	end,
}

-- Alternate spellings for the same command (kept in one place).
local commandAliases = {
	banksort = "sortbank",
	warbanksort = "sortwarbank",
	sortwarbandbank = "sortwarbank",
	bankdeposit = "depositbank",
	warbankdeposit = "depositwarbank",
	depositwarbandbank = "depositwarbank",
	resetpos = "reset",
	bankreset = "resetbank",
	resetwarbank = "resetbank",
	warbankreset = "resetbank",
	resetwarbandbank = "resetbank",
	options = "config",
}
for alias, target in pairs(commandAliases) do
	exactCommands[alias] = function()
		exactCommands[target]()
	end
end

local prefixCommands = {
	columns = function(value)
		local backpack = ns:GetModule("Backpack")
		local columns = backpack and backpack:SetColumns(value)
		if columns then
			F.Print(format(L["Columns set to %d."], columns))
		else
			F.Print(L["Usage: /bf columns <number>"])
		end
	end,
	bankcolumns = function(value)
		local bank = ns:GetModule("Bank")
		local columns = bank and bank:SetColumns(value, false)
		if columns then
			F.Print(format(L["Bank columns set to %d."], columns))
		else
			F.Print(L["Usage: /bf bankcolumns <number>"])
		end
	end,
	warbandcolumns = function(value)
		local bank = ns:GetModule("Bank")
		local columns = bank and bank:SetColumns(value, true)
		if columns then
			F.Print(format(L["Warband bank columns set to %d."], columns))
		else
			F.Print(L["Usage: /bf warbandcolumns <number>"])
		end
	end,
	filter = function(value)
		local categories = ns:GetModule("Categories")
		if categories then
			categories:HandleCommand(value)
		end
	end,
	cat = function(value)
		local organize = ns:GetModule("Organize")
		if organize then
			organize:HandleCommand(value)
		end
	end,
	junk = function(value)
		local organize = ns:GetModule("Organize")
		if organize then
			organize:HandleJunkCommand(value)
		end
	end,
	testextslots = function(value)
		local container = ns.Container
		if not container or not container.SetExtendedSlotsTestOverride then
			return
		end
		local word = value:lower():match("^(%S+)")
		local enable
		if word == "on" or word == "1" or word == "true" then
			enable = true
		elseif word == "off" or word == "0" or word == "false" then
			enable = false
		else
			enable = not container.GetExtendedSlotsTestOverride()
		end
		container.SetExtendedSlotsTestOverride(enable)
		F.Print(format(L["Extended backpack slots preview %s."], enable and L["on"] or L["off"]))
	end,
}

local prefixAliases = {
	bankcols = "bankcolumns",
	warbandcols = "warbandcolumns",
	warbankcols = "warbandcolumns",
	category = "cat",
	testextended = "testextslots",
	testslots = "testextslots",
}
for alias, target in pairs(prefixAliases) do
	prefixCommands[alias] = function(value)
		prefixCommands[target](value)
	end
end

local function HandleSlash(msg)
	-- Trim but DON'T lowercase: custom-category names and pasted item links are
	-- case-sensitive. Only the command word is normalised; the value passes
	-- through verbatim (handlers that want lowercase, like filter, do it).
	msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local command, value = msg:match("^(%S+)%s*(.*)$")
	command = (command or ""):lower()
	value = value or ""

	-- No-argument commands match on the command word alone (covers "" = toggle).
	if value == "" and exactCommands[command] then
		exactCommands[command]()
		return
	end

	local prefix = prefixCommands[command]
	if prefix then
		prefix(value)
		return
	end

	ShowHelp()
end

_G.SLASH_BAGFORGE1 = "/bagforge"
_G.SLASH_BAGFORGE2 = "/bf"
SlashCmdList["BAGFORGE"] = HandleSlash
