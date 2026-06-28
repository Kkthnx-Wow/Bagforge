--[[
	Bagforge - ItemInfo
	-------------------------------------------------------------------------
	Per-slot display extras the item button paints on top of the icon:
	  * Item level (quality-coloured) on equippable gear.
	  * Bind labels (BoE / BoU / BoA / WuE) on unbound items.
	  * A red icon tint on items your class can't use or you're too low level for.

	The item button does the actual drawing; this module owns the data + toggles
	and publishes small checkers the button reads while painting (the same shape
	as the Pawn integration). The unusable/class-restriction logic is adapted
	from NexEnhance's UnusableItems (itself from LibUnfit-1.0 via KkthnxUI), and
	Bind labels are resolved at scan time via ItemInfo:GetBindLabel (NexEnhance/BlizzardBags_BoE idea).

	Class/level/bind data is not a Secret value, so there's no 12.0 concern here;
	we still guard item links defensively.
--]]

local _, ns = ...
local F, L = ns.F, ns.L

local select = select
local UnitLevel = UnitLevel
local UnitClassBase = UnitClassBase
local C_Item = C_Item
local C_Container = C_Container
local C_TooltipInfo = C_TooltipInfo
local Enum = Enum
local pcall = pcall

local LINE_ITEM_BINDING = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.ItemBinding
local BIND = Enum and Enum.TooltipDataItemBinding
local ITEM_BIND = Enum and Enum.ItemBind

local itemLevelCache = {}

ns:RegisterDefaults({
	itemInfo = {
		enable = true,
		itemLevel = true,
		bindText = true,
		unusable = true,
		itemLevelCorner = "bottomleft",
		bindTextCorner = "topright",
		markerCorner = "topleft",
	},
})

local CORNER_CHOICES = {
	{ value = "topleft", label = L["Top Left"] },
	{ value = "topright", label = L["Top Right"] },
	{ value = "bottomleft", label = L["Bottom Left"] },
	{ value = "bottomright", label = L["Bottom Right"] },
	{ value = "top", label = L["Top"] },
	{ value = "bottom", label = L["Bottom"] },
	{ value = "left", label = L["Left"] },
	{ value = "right", label = L["Right"] },
	{ value = "center", label = L["Center"] },
}

local ItemInfo = ns:NewModule("ItemInfo", "itemInfo")
ItemInfo.title = L["Item Info"]
ItemInfo.order = 15
ItemInfo.group = "display"

-- ---------------------------------------------------------------------------
-- Class-restriction data (resolved to the player's class at login).
--   Reproduced from LibUnfit-1.0 (João Cardoso, GPL3) via NexEnhance:
--   playerUnusable[itemClassID][itemSubClassID] = true -> unusable subtype.
-- ---------------------------------------------------------------------------
local playerUnusable
local cannotDual = false
local playerLevel = 1

local function BuildUnusable()
	local W = Enum and Enum.ItemWeaponSubclass
	local A = Enum and Enum.ItemArmorSubclass
	if not (W and A and Enum.ItemClass) then
		return
	end

	local byClass = {
		DEATHKNIGHT = { weapons = { W.Bows, W.Guns, W.Warglaive, W.Staff, W.Unarmed, W.Dagger, W.Thrown, W.Crossbow, W.Wand }, armor = { A.Shield } },
		DEMONHUNTER = { weapons = { W.Axe2H, W.Bows, W.Guns, W.Mace1H, W.Mace2H, W.Polearm, W.Sword2H, W.Staff, W.Thrown, W.Crossbow, W.Wand }, armor = { A.Mail, A.Plate, A.Shield } },
		DRUID = { weapons = { W.Axe1H, W.Axe2H, W.Bows, W.Guns, W.Sword1H, W.Sword2H, W.Warglaive, W.Thrown, W.Crossbow, W.Wand }, armor = { A.Mail, A.Plate, A.Shield }, cannotDual = true },
		EVOKER = { weapons = { W.Bows, W.Guns, W.Polearm, W.Warglaive, W.Thrown, W.Crossbow, W.Wand }, armor = { A.Plate, A.Shield }, cannotDual = true },
		HUNTER = { weapons = { W.Mace1H, W.Mace2H, W.Warglaive, W.Thrown, W.Wand }, armor = { A.Plate, A.Shield } },
		MAGE = { weapons = { W.Axe1H, W.Axe2H, W.Bows, W.Guns, W.Mace1H, W.Mace2H, W.Polearm, W.Sword2H, W.Warglaive, W.Unarmed, W.Thrown, W.Crossbow }, armor = { A.Leather, A.Mail, A.Plate, A.Shield }, cannotDual = true },
		MONK = { weapons = { W.Axe2H, W.Bows, W.Guns, W.Mace2H, W.Sword2H, W.Warglaive, W.Dagger, W.Thrown, W.Crossbow, W.Wand }, armor = { A.Mail, A.Plate, A.Shield } },
		PALADIN = { weapons = { W.Bows, W.Guns, W.Warglaive, W.Staff, W.Unarmed, W.Dagger, W.Thrown, W.Crossbow, W.Wand }, armor = {}, cannotDual = true },
		PRIEST = { weapons = { W.Axe1H, W.Axe2H, W.Bows, W.Guns, W.Mace2H, W.Polearm, W.Sword1H, W.Sword2H, W.Warglaive, W.Unarmed, W.Thrown, W.Crossbow }, armor = { A.Leather, A.Mail, A.Plate, A.Shield }, cannotDual = true },
		ROGUE = { weapons = { W.Axe2H, W.Mace2H, W.Polearm, W.Sword2H, W.Warglaive, W.Staff, W.Wand }, armor = { A.Mail, A.Plate, A.Shield } },
		SHAMAN = { weapons = { W.Bows, W.Guns, W.Polearm, W.Sword1H, W.Sword2H, W.Warglaive, W.Thrown, W.Crossbow, W.Wand }, armor = { A.Plate } },
		WARLOCK = { weapons = { W.Axe1H, W.Axe2H, W.Bows, W.Guns, W.Mace1H, W.Mace2H, W.Polearm, W.Sword2H, W.Warglaive, W.Unarmed, W.Thrown, W.Crossbow }, armor = { A.Leather, A.Mail, A.Plate, A.Shield }, cannotDual = true },
		WARRIOR = { weapons = { W.Warglaive, W.Wand }, armor = {} },
	}

	local entry = byClass[UnitClassBase("player")]
	if not entry then
		return
	end

	local lookup = { [Enum.ItemClass.Weapon] = {}, [Enum.ItemClass.Armor] = {} }
	local weapons, armor = lookup[Enum.ItemClass.Weapon], lookup[Enum.ItemClass.Armor]
	for i = 1, #entry.weapons do
		weapons[entry.weapons[i]] = true
	end
	for i = 1, #entry.armor do
		armor[entry.armor[i]] = true
	end

	playerUnusable = lookup
	cannotDual = entry.cannotDual or false
end

-- ---------------------------------------------------------------------------
-- Usability checks (bounded per-itemID caches; class/req-level never change).
-- ---------------------------------------------------------------------------
local classCache = {}
local reqLevelCache = {}
local tooltipUnfitCache = {}

local ITEM_SCRAPABLE_NOT = _G["ITEM_SCRAPABLE_NOT"]
local CANNOT_UNEQUIP_COMBAT = _G["CANNOT_UNEQUIP_COMBAT"]
local ITEM_DISENCHANT_NOT_DISENCHANTABLE = _G["ITEM_DISENCHANT_NOT_DISENCHANTABLE"]
local IsEquippableItem = _G["IsEquippableItem"]

local function IsTooltipUnusable(itemID)
	if not itemID or F.IsSecret(itemID) then
		return false
	end
	local cached = tooltipUnfitCache[itemID]
	if cached ~= nil then
		return cached
	end

	local result = false
	if C_TooltipInfo and C_TooltipInfo.GetItemByID and (IsEquippableItem or C_Item.GetItemSpell) then
		local check = IsEquippableItem and IsEquippableItem(itemID)
		if not check and C_Item.GetItemSpell then
			check = C_Item.GetItemSpell(itemID)
		end
		if check then
			local tip = C_TooltipInfo.GetItemByID(itemID)
			if tip and tip.lines then
				for _, row in ipairs(tip.lines) do
					local lc = row.leftColor
					if lc and lc.r == 1 and lc.g < 0.2 and lc.b < 0.2
						and row.leftText ~= ITEM_SCRAPABLE_NOT
						and row.leftText ~= CANNOT_UNEQUIP_COMBAT
						and row.leftText ~= ITEM_DISENCHANT_NOT_DISENCHANTABLE then
						result = true
						break
					end
					local rc = row.rightColor
					if rc and rc.r == 1 and rc.g < 0.2 and rc.b < 0.2 then
						result = true
						break
					end
				end
			end
		end
	end

	F.CacheSet(tooltipUnfitCache, itemID, result)
	return result
end

local function IsClassUnusable(item)
	if not (playerUnusable and item.itemID) then
		return false
	end

	local cached = classCache[item.itemID]
	if cached ~= nil then
		return cached
	end

	local result = false
	local map = playerUnusable[item.classID]
	if map and item.itemEquipLoc and item.itemEquipLoc ~= "" then
		if map[item.subClassID] then
			result = true
		elseif item.itemEquipLoc == "INVTYPE_WEAPONOFFHAND" and cannotDual then
			result = true
		end
	end

	classCache[item.itemID] = result
	return result
end

--- True when the player's class can't use the item, or is below its required
--- level. `item` is a scanned slot entry (carries classID/subClassID/equipLoc).
function ItemInfo:IsUnusable(item)
	if not item then
		return false
	end
	if IsClassUnusable(item) then
		return true
	end
	if IsTooltipUnusable(item.itemID) then
		return true
	end

	if item.hyperlink and not F.IsSecret(item.hyperlink) then
		local req = reqLevelCache[item.itemID]
		if req == nil then
			req = select(5, C_Item.GetItemInfo(item.hyperlink)) or 0
			reqLevelCache[item.itemID] = req
		end
		if req > 0 and req > playerLevel then
			return true
		end
	end

	return false
end

-- ---------------------------------------------------------------------------
-- Item level + bind label (cached; populated at scan into entry.ilvl/bindLabel)
-- ---------------------------------------------------------------------------

function ItemInfo:GetItemLevel(entry)
	if not entry or not entry.hyperlink or F.IsSecret(entry.hyperlink) then
		return nil
	end
	if entry.classID ~= Enum.ItemClass.Weapon and entry.classID ~= Enum.ItemClass.Armor then
		return nil
	end

	local link = entry.hyperlink
	local cached = itemLevelCache[link]
	if cached ~= nil then
		return cached
	end

	if not C_Item or not C_Item.GetDetailedItemLevelInfo then
		return nil
	end

	local ok, level = pcall(C_Item.GetDetailedItemLevelInfo, link)
	if ok and F.NotSecret(level) and level and level > 0 then
		-- Bounded: keyed by full link (varies by bonus/enchant IDs), so cap it
		-- rather than let a long session accumulate every variant seen.
		F.CacheSet(itemLevelCache, link, level)
		return level
	end
end

-- Resolved bind label per itemID. An unbound item's bind type is intrinsic to
-- its item type, so once we resolve "BoE"/etc. (or definitively "no label") it
-- never changes while the item stays unbound (a bound item short-circuits above
-- the cache read). This spares the tooltip scan on every rescan - the scanner's
-- "cached per item" promise. `false` = resolved to no label (distinct from nil =
-- not resolved yet, e.g. item data not loaded).
local bindLabelCache = {}

function ItemInfo:GetBindLabel(entry)
	if not entry or not entry.hyperlink or F.IsSecret(entry.hyperlink) then
		return nil
	end
	if entry.isBound then
		return nil
	end

	local id = entry.itemID
	if id then
		local cached = bindLabelCache[id]
		if cached ~= nil then
			return cached or nil
		end
	end

	local label, resolved

	if entry.bag and entry.slot and C_TooltipInfo and C_TooltipInfo.GetBagItem and BIND then
		local data = C_TooltipInfo.GetBagItem(entry.bag, entry.slot)
		if data and data.lines then
			for i = 2, #data.lines do
				local line = data.lines[i]
				if line.type == LINE_ITEM_BINDING then
					local bonding = line.bonding
					if bonding == BIND.BindOnEquip then
						label = "BoE"
					elseif bonding == BIND.BindOnUse then
						label = "BoU"
					elseif bonding == BIND.Account or bonding == BIND.BindToAccount or bonding == BIND.BindToBnetAccount or bonding == BIND.BnetAccount then
						label = "BoA"
					elseif bonding == BIND.AccountUntilEquipped or bonding == BIND.BindToAccountUntilEquipped then
						label = "WuE"
					end
					resolved = true
					break
				end
			end
		end
	end

	if not resolved and ITEM_BIND and C_Item and C_Item.GetItemInfo then
		local bindType = select(14, C_Item.GetItemInfo(entry.hyperlink))
		if bindType ~= nil then
			resolved = true
			if bindType == ITEM_BIND.OnEquip then
				label = "BoE"
			elseif bindType == ITEM_BIND.OnUse then
				label = "BoU"
			elseif bindType == ITEM_BIND.ToWoWAccount or bindType == ITEM_BIND.ToBnetAccount then
				label = "BoA"
			elseif bindType == ITEM_BIND.ToBnetAccountUntilEquipped then
				label = "WuE"
			end
		end
	end

	-- Only memoise a definitive answer; if neither source had data yet (item not
	-- cached), leave it unresolved so a later rescan can fill it in.
	if resolved and id then
		bindLabelCache[id] = label or false
	end
	return label
end

-- ---------------------------------------------------------------------------
-- Wiring
--   Publish display flags the item button reads, then repaint open windows.
-- ---------------------------------------------------------------------------
local function RefreshUnusableEntries()
	if ns.Scan and ns.Scan.RefreshUnusableAll then
		ns.Scan.RefreshUnusableAll()
	end
end

function ItemInfo:Apply()
	local db = ns.db.itemInfo
	local on = db.enable

	ns.ShowItemLevel = on and db.itemLevel or false

	if on and db.unusable and not playerUnusable then
		BuildUnusable()
		playerLevel = UnitLevel("player") or playerLevel
	end

	if on and db.bindText then
		ns.GetItemBindLabel = function(item)
			return item.bindLabel
		end
	else
		ns.GetItemBindLabel = nil
	end

	local itemButton = ns:GetModule("ItemButton")
	if itemButton and itemButton.ApplyOverlayLayout then
		itemButton:ApplyOverlayLayout()
	end

	RefreshUnusableEntries()
	ns:RefreshBags(false)
end

function ItemInfo:OnEnable()
	BuildUnusable()
	playerLevel = UnitLevel("player") or 1
	self:Apply()
	self:RegisterEvent("PLAYER_LEVEL_UP", "OnLevelUp")
end

function ItemInfo:OnLevelUp(level)
	playerLevel = level or UnitLevel("player") or 1
	RefreshUnusableEntries()
	ns:RefreshBags(false)
end

function ItemInfo:OnSettingChanged()
	self:Apply()
end

-- ---------------------------------------------------------------------------
-- Settings panel
-- ---------------------------------------------------------------------------
function ItemInfo:RegisterOptions(category, builder)
	local _, master = builder:Checkbox(category, self, "enable", L["Enable Item Info"], L["Show item level, bind status and unusable-item tinting on bag and bank slots."])

	local _, ilvl = builder:Checkbox(category, self, "itemLevel", L["Show Item Level"], L["Show the (quality-coloured) item level on equippable gear."])
	builder:DependsOn(ilvl, master)

	local _, bind = builder:Checkbox(category, self, "bindText", L["Show Bind Status"], L["Show BoE, BoU, BoA and WuE labels on items that are not yet bound."])
	builder:DependsOn(bind, master)

	local _, unfit = builder:Checkbox(category, self, "unusable", L["Colour Unusable Items"], L["Tint icons red for items your class can't use or that you're too low level for."])
	builder:DependsOn(unfit, master)

	builder:Header(L["Overlay Positions"])
	local _, ilvlPos = builder:Dropdown(category, self, "itemLevelCorner", L["Item Level Position"], L["Which corner of the slot shows the item level."], CORNER_CHOICES)
	builder:DependsOn(ilvlPos, ilvl)

	local _, bindPos = builder:Dropdown(category, self, "bindTextCorner", L["Bind Status Position"], L["Which corner of the slot shows BoE, BoU, BoA and WuE labels."], CORNER_CHOICES)
	builder:DependsOn(bindPos, bind)

	local _, markerPos = builder:Dropdown(category, self, "markerCorner", L["Marker Position"], L["Which corner shows the junk coin and custom-category star (only one appears at a time)."], CORNER_CHOICES)
	-- The junk/star marker is drawn independently of the item-level and bind
	-- toggles, so it has no per-feature parent. Depend on the master enable so
	-- this row renders and greys out consistently with the two dropdowns above
	-- it (otherwise it stands out as the only always-bright control here).
	builder:DependsOn(markerPos, master)
end
