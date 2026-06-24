--[[
	Bagforge - Delete Cheapest
	-------------------------------------------------------------------------
	A one-shot bag action (NexEnhance's goblin-head button, rebuilt for the
	Bagforge module/options architecture): find and destroy the cheapest
	vendor-sellable item in your carried bags - a quick way to free a slot
	when you're full and the nearest vendor is far away.

	  * Left-click  : find the cheapest sellable item and prompt to delete it.
	  * Right-click : just report the cheapest item in chat (no deletion).

	"Cheapest" is the lowest total vendor value (unit sell price x stack count).
	Items with no sell value (most quest items, soulbound junk, etc.) are
	skipped outright, and optional per-item-class filters protect whole
	categories (quest items are protected by default).

	The toolbar button itself is created in Backpack:BuildChrome alongside the
	other chrome icons; this module owns the scan, the confirm dialog and the
	options page, and Backpack calls back into Report()/Prompt() on click.

	Midnight note: vendor sell price comes from C_Item.GetItemInfo (static item
	data, never Secret), but a bag slot's stack count and item link can be
	Secret in combat/instances, so we gate those reads with F.IsSecret and fall
	back to treating a slot as a single item rather than doing arithmetic on a
	Secret.
--]]

local _, ns = ...
local C, F, L = ns.C, ns.F, ns.L

local select = select
local ipairs = ipairs
local format = string.format

local C_Container = C_Container
local C_Container_GetContainerNumSlots = C_Container.GetContainerNumSlots
local C_Container_GetContainerItemInfo = C_Container.GetContainerItemInfo
local C_Container_PickupContainerItem = C_Container.PickupContainerItem
local C_Item_GetItemInfo = C_Item.GetItemInfo
local ClearCursor = ClearCursor
local DeleteCursorItem = DeleteCursorItem
local InCombatLockdown = InCombatLockdown
local StaticPopupDialogs = StaticPopupDialogs
local StaticPopup_Show = StaticPopup_Show

-- Item-class IDs (Enum.ItemClass) -> the setting that protects that class.
local FILTER_KEYS = {
	[Enum.ItemClass.Consumable] = "filterConsumable",
	[Enum.ItemClass.Container] = "filterContainer",
	[Enum.ItemClass.Weapon] = "filterWeapon",
	[Enum.ItemClass.Armor] = "filterArmor",
	[Enum.ItemClass.Reagent] = "filterReagent",
	[Enum.ItemClass.Tradegoods] = "filterTradeskill",
	[Enum.ItemClass.Questitem] = "filterQuest",
}

ns:RegisterDefaults({
	deleteCheapest = {
		enable = true,
		filterConsumable = false,
		filterContainer = false,
		filterWeapon = false,
		filterArmor = false,
		filterReagent = false,
		filterTradeskill = false,
		filterQuest = true, -- protect quest items by default
	},
})

local DeleteCheapest = ns:NewModule("DeleteCheapest", "deleteCheapest")
DeleteCheapest.title = L["Delete Cheapest"]
DeleteCheapest.order = 40
DeleteCheapest.group = "extras"

-- ---------------------------------------------------------------------------
-- Scan
-- ---------------------------------------------------------------------------
-- True when the item's class is excluded by the user's protection filters.
local function IsFiltered(link)
	local classID = select(12, C_Item_GetItemInfo(link))
	-- classID can be Secret inside instances; never index the table with it.
	if not classID or F.IsSecret(classID) then
		return false
	end
	local key = FILTER_KEYS[classID]
	return key ~= nil and ns.db.deleteCheapest[key]
end

-- Walk every carried bag and return the slot with the lowest total vendor
-- value. Returns link, value, count, bag, slot (or nil when nothing qualifies).
local function FindCheapest()
	local bestLink, bestValue, bestCount, bestBag, bestSlot, bestItemID

	for _, bag in ipairs(C.BACKPACK_BAGS) do
		local numSlots = C_Container_GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local info = C_Container_GetContainerItemInfo(bag, slot)
			if info and not info.hasNoValue and info.hyperlink and F.NotSecret(info.hyperlink) and info.itemID and F.NotSecret(info.itemID) then
				local sellPrice = select(11, C_Item_GetItemInfo(info.hyperlink))
				-- sellPrice is static item data (not Secret); guard anyway.
				if sellPrice and F.NotSecret(sellPrice) and sellPrice > 0 and not IsFiltered(info.hyperlink) then
					-- Stack count can be Secret in combat; only multiply when
					-- it is a plain number, otherwise price the single item.
					local count = info.stackCount
					local total = sellPrice
					if count and F.NotSecret(count) and count > 1 then
						total = sellPrice * count
					else
						count = 1
					end

					if not bestValue or total < bestValue then
						bestLink = info.hyperlink
						bestValue = total
						bestCount = count
						bestBag = bag
						bestSlot = slot
						bestItemID = info.itemID
					end
				end
			end
		end
	end

	return bestLink, bestValue, bestCount, bestBag, bestSlot, bestItemID
end

-- ---------------------------------------------------------------------------
-- Actions (called from the Backpack chrome button)
-- ---------------------------------------------------------------------------
function DeleteCheapest:Report()
	local link, value, count = FindCheapest()
	if not (link and value) then
		F.Print(L["No sellable items were found in your bags."])
		return
	end
	if count and count > 1 then
		F.Print(format(L["Cheapest item: %s x%d, worth %s."], link, count, F.FormatMoney(value)))
	else
		F.Print(format(L["Cheapest item: %s, worth %s."], link, F.FormatMoney(value)))
	end
end

if StaticPopupDialogs then
	StaticPopupDialogs["BAGFORGE_DELETE_CHEAPEST"] = {
		text = L["Delete the cheapest item in your bags?"] .. "|n|n%s",
		button1 = _G["YES"] or "Yes",
		button2 = _G["NO"] or "No",
		OnAccept = function(_, data)
			if not (data and data.bag and data.slot) then
				return
			end
			if InCombatLockdown() then
				F.Print(L["Can't delete items during combat."])
				return
			end
			-- Re-verify the slot still holds the same item before destroying it,
			-- so a bag shuffle between prompt and confirm can't delete the wrong
			-- thing. Compare bag/slot only; hyperlinks may be Secret in instances.
			local info = C_Container_GetContainerItemInfo(data.bag, data.slot)
			if not info or not info.itemID or not F.NotSecret(info.itemID) or info.itemID ~= data.itemID then
				F.Print(L["The item moved before it could be deleted - nothing was destroyed."])
				return
			end
			if ClearCursor then
				ClearCursor()
			end
			C_Container_PickupContainerItem(data.bag, data.slot)
			DeleteCursorItem()
			if data.count and data.count > 1 then
				F.Print(format(L["Deleted %s x%d, worth %s."], data.link, data.count, F.FormatMoney(data.value)))
			else
				F.Print(format(L["Deleted %s, worth %s."], data.link, F.FormatMoney(data.value)))
			end
			ns:RefreshBags(true)
		end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
		showAlert = 1,
		preferredIndex = 3,
	}
end

function DeleteCheapest:Prompt()
	if InCombatLockdown() then
		F.Print(L["Can't delete items during combat."])
		return
	end
	local link, value, count, bag, slot, itemID = FindCheapest()
	if not (link and bag and slot and itemID and F.NotSecret(itemID)) then
		F.Print(L["No sellable items were found in your bags."])
		return
	end

	-- The item link (text_arg1 -> %s in the dialog text) renders as the usual
	-- clickable, quality-coloured link, so the player sees what's at stake.
	if StaticPopup_Show then
		StaticPopup_Show("BAGFORGE_DELETE_CHEAPEST", link, nil, {
			link = link,
			value = value,
			count = count,
			bag = bag,
			slot = slot,
			itemID = itemID,
		})
	end
end

-- ---------------------------------------------------------------------------
-- Settings / live apply
-- ---------------------------------------------------------------------------
function DeleteCheapest:OnSettingChanged(key)
	if key ~= "enable" then
		return
	end
	-- The toolbar button lives on the backpack chrome; let it show/hide and
	-- reclaim the search-box width without a reload.
	local backpack = ns:GetModule("Backpack")
	if backpack and backpack.UpdateDeleteCheapestButton then
		backpack:UpdateDeleteCheapestButton()
	end
end

function DeleteCheapest:RegisterOptions(category, builder)
	local _, enableInit = builder:Checkbox(category, self, "enable", L["Enable Delete Cheapest"], L["Add a button to the bag window that finds and deletes the cheapest sellable item. Left-click to delete (with a confirmation), right-click to preview."])

	builder:Header(L["Protected Item Types"])
	local _, consumableInit = builder:Checkbox(category, self, "filterConsumable", L["Protect Consumables"], L["Never offer to delete consumable items."])
	local _, containerInit = builder:Checkbox(category, self, "filterContainer", L["Protect Containers"], L["Never offer to delete bags and other containers."])
	local _, weaponInit = builder:Checkbox(category, self, "filterWeapon", L["Protect Weapons"], L["Never offer to delete weapons."])
	local _, armorInit = builder:Checkbox(category, self, "filterArmor", L["Protect Armor"], L["Never offer to delete armor."])
	local _, reagentInit = builder:Checkbox(category, self, "filterReagent", L["Protect Reagents"], L["Never offer to delete reagents."])
	local _, tradeskillInit = builder:Checkbox(category, self, "filterTradeskill", L["Protect Trade Goods"], L["Never offer to delete trade goods / crafting materials."])
	local _, questInit = builder:Checkbox(category, self, "filterQuest", L["Protect Quest Items"], L["Never offer to delete quest items."])

	builder:DependsOn(consumableInit, enableInit)
	builder:DependsOn(containerInit, enableInit)
	builder:DependsOn(weaponInit, enableInit)
	builder:DependsOn(armorInit, enableInit)
	builder:DependsOn(reagentInit, enableInit)
	builder:DependsOn(tradeskillInit, enableInit)
	builder:DependsOn(questInit, enableInit)
end
