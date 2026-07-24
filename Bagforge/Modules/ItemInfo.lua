--[[
	Bagforge - ItemInfo
	-------------------------------------------------------------------------
	Per-slot display extras the item button paints on top of the icon:
	  * Item level (quality-coloured) on equippable gear.
	  * Bind labels (BoE / BoU / BoA / WuE) on unbound items.
	  * A red icon tint on items your class can't use or you're too low level for.

	The item button does the actual drawing; this module owns the data + toggles
	and publishes small checkers the button reads while painting (the same shape
	as the Pawn integration).

	Unusable tint follows the Bagnon/BagBrother stack (ItemSearch-1.3 + LibUnfit)
	and KkthnxUI's bag buttons: class weapon/armor proficiency, explicit tooltip
	class requirements (ITEM_CLASSES_ALLOWED), and itemMinLevel vs player level.
	We do NOT use C_PlayerInfo.CanUseItem — it returns false for wrong primary
	stats/spec gear you can still equip, which painted usable leather red.

	Item metadata used here is plain data in the 12.0.7 API docs.
--]]

local _, ns = ...
local F, L = ns.F, ns.L

local UnitLevel = UnitLevel
local UnitClassBase = UnitClassBase
local C_Item = C_Item
local C_TooltipInfo = C_TooltipInfo
local Enum = Enum
local pcall = pcall
local IsItemDataCachedByID = C_Item and C_Item.IsItemDataCachedByID
local IsEquippableItem = C_Item and C_Item.IsEquippableItem

local LINE_ITEM_BINDING = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.ItemBinding
local LINE_ITEM_LEVEL = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.ItemLevel
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
-- Usability (Bagnon ItemSearch-1.3 + LibUnfit-1.0 + KkthnxUI level gate).
--   1. LibUnfit class weapon/armor proficiency tables.
--   2. Tooltip "Classes: …" line (ITEM_CLASSES_ALLOWED) for restricted gear.
--   3. itemMinLevel > player level.
-- Does not use C_PlayerInfo.CanUseItem (stat/spec false negatives).
-- ---------------------------------------------------------------------------
local unusableCache = {}
local classReqCache = {}
local reqLevelCache = {}
local classReqPattern
local playerClassMale
local playerClassFemale
local INVTYPE_WEAPONOFFHAND = "INVTYPE_WEAPONOFFHAND"

local function EnsureClassReqPattern()
	if classReqPattern then
		return
	end
	if ITEM_CLASSES_ALLOWED then
		classReqPattern = ITEM_CLASSES_ALLOWED:format("(.*)")
	end
	local classToken = UnitClassBase("player")
	if classToken then
		playerClassMale = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classToken]
		playerClassFemale = LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[classToken]
	end
end

function ItemInfo:InvalidateUnusableCaches()
	wipe(unusableCache)
	wipe(classReqCache)
	wipe(reqLevelCache)
	classReqPattern = nil
	playerClassMale = nil
	playerClassFemale = nil
	EnsureClassReqPattern()
end

local function ResolveItemKey(entry)
	local link = entry.hyperlink
	if link then
		return link
	end
	local id = entry.itemID
	if id then
		return id
	end
	return nil
end

local function IsEquippableGearKey(key)
	if not key then
		return false
	end
	if IsEquippableItem then
		local ok, equippable = pcall(IsEquippableItem, key)
		if ok and equippable then
			return true
		end
	end
	local instant = F.GetItemInfoInstantRecord(key)
	local slot = instant and instant.itemEquipLoc
	return slot and slot ~= ""
end

--- LibUnfit-1.0 proficiency: wrong weapon/armor subclass or offhand when cannot dual-wield.
local function IsProficiencyUnusable(key)
	if not (playerUnusable and key) then
		return false
	end
	local instant = F.GetItemInfoInstantRecord(key)
	if not instant then
		return false
	end
	local classID = instant.classID
	local subClassID = instant.subclassID or instant.subClassID
	local equipLoc = instant.itemEquipLoc
	if not (classID and subClassID and equipLoc) then
		return false
	end

	local map = playerUnusable[classID]
	if equipLoc ~= "" and map and map[subClassID] then
		return true
	end
	if cannotDual and equipLoc == INVTYPE_WEAPONOFFHAND then
		return true
	end
	return false
end

--- Bagnon ItemSearch: scan tooltip for ITEM_CLASSES_ALLOWED (not red stat lines).
local function HasClassRequirementMismatch(itemID)
	if not itemID then
		return false
	end
	local cached = classReqCache[itemID]
	if cached ~= nil then
		return cached
	end

	EnsureClassReqPattern()
	if not (classReqPattern and (playerClassMale or playerClassFemale) and C_TooltipInfo and C_TooltipInfo.GetItemByID) then
		classReqCache[itemID] = false
		return false
	end

	local result = false
	local ok, data = pcall(C_TooltipInfo.GetItemByID, itemID)
	if ok and data and data.lines then
		local lines = data.lines
		for i = #lines - 1, 5, -1 do
			local line = lines[i]
			local text = line and line.leftText
			if text then
				local classList = text:match(classReqPattern)
				if classList then
					local matches = (playerClassMale and classList:find(playerClassMale, 1, true))
						or (playerClassFemale and classList:find(playerClassFemale, 1, true))
					result = not matches
					break
				end
			end
		end
	end

	classReqCache[itemID] = result
	return result
end

local function IsBelowRequiredLevel(itemID, key)
	if not itemID then
		return false
	end
	local req = reqLevelCache[itemID]
	if req == nil then
		local info = (key and F.GetItemInfoRecord(key)) or F.GetItemInfoRecord(itemID)
		local safe = info and info.itemMinLevel
		if safe then
			reqLevelCache[itemID] = safe
			req = safe
		else
			reqLevelCache[itemID] = false
			req = false
		end
	end
	if not req or req <= 0 then
		return false
	end
	return req > playerLevel
end

--- True when the player's class can't use the item, or is below its required
--- level. `item` is a scanned slot entry (carries classID/subClassID/equipLoc).
function ItemInfo:IsUnusable(item)
	if not item then
		return false
	end

	local itemID = item.itemID
	if not itemID then
		return false
	end

	-- Defer until item data is loaded; a premature check can cache a wrong answer.
	if IsItemDataCachedByID and not IsItemDataCachedByID(itemID) then
		return false
	end

	local cached = unusableCache[itemID]
	if cached ~= nil then
		return cached
	end

	local key = ResolveItemKey(item)
	if not IsEquippableGearKey(key) then
		return F.CacheSet(unusableCache, itemID, false)
	end

	if IsProficiencyUnusable(key) then
		return F.CacheSet(unusableCache, itemID, true)
	end

	if HasClassRequirementMismatch(itemID) then
		return F.CacheSet(unusableCache, itemID, true)
	end

	if IsBelowRequiredLevel(itemID, key) then
		return F.CacheSet(unusableCache, itemID, true)
	end

	return F.CacheSet(unusableCache, itemID, false)
end

local function ResolveGearClassID(entry)
	local classID = entry.classID
	if classID then
		return classID
	end
	local id = entry.itemID
	if not id then
		return nil
	end
	local instant = F.GetItemInfoInstantRecord(id)
	if instant and instant.classID then
		return instant.classID
	end
	local record = F.GetItemInfoRecord(id)
	if record and record.classID then
		return record.classID
	end
	return nil
end

local function IsEquippableGear(entry)
	local classID = ResolveGearClassID(entry)
	return classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor
end

function ItemInfo:GetItemLevel(entry)
	if not entry or not IsEquippableGear(entry) then
		return nil
	end

	local link = entry.hyperlink
	local cacheKey = link or entry.itemID
	if cacheKey then
		local cached = itemLevelCache[cacheKey]
		if cached ~= nil then
			return cached
		end
	end

	-- Match the game tooltip (timewarped/scaled gear shows the same ilvl the player sees).
	-- WoWUIBugs #828: GetDetailedItemLevelInfo and GetItemInfo.itemLevel can return
	-- wrong values in 12.0+; tooltip + Item:GetCurrentItemLevel are reliable.
	if entry.bag and entry.slot and C_TooltipInfo and C_TooltipInfo.GetBagItem and LINE_ITEM_LEVEL then
		local ok, data = pcall(C_TooltipInfo.GetBagItem, entry.bag, entry.slot)
		if ok and data and data.lines then
			for i = 2, #data.lines do
				local line = data.lines[i]
				if line.type == LINE_ITEM_LEVEL then
					local level = line.itemLevel
					if level and level > 0 then
						if cacheKey then
							F.CacheSet(itemLevelCache, cacheKey, level)
						end
						return level
					end
				end
			end
		end
	end

	local Item = _G["Item"]
	if entry.bag and entry.slot and Item then
		local item = Item:CreateFromBagAndSlot(entry.bag, entry.slot)
		if item and item.IsValid and item:IsValid() and item.GetCurrentItemLevel then
			local ok, level = pcall(item.GetCurrentItemLevel, item)
			if ok and level and level > 0 then
				if cacheKey then
					F.CacheSet(itemLevelCache, cacheKey, level)
				end
				return level
			end
		end
	end

	local info = F.GetItemInfoRecord(link) or F.GetItemInfoRecord(entry.itemID)
	local level = info and info.itemLevel
	if level and level > 0 then
		if cacheKey then
			F.CacheSet(itemLevelCache, cacheKey, level)
		end
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
	if not entry then
		return nil
	end
	if entry.isBound == true then
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
		local ok, data = pcall(C_TooltipInfo.GetBagItem, entry.bag, entry.slot)
		if ok and data and data.lines then
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
		local info = (entry.hyperlink and F.GetItemInfoRecord(entry.hyperlink))
			or (entry.itemID and F.GetItemInfoRecord(entry.itemID))
		local bindType = info and info.bindType
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
		F.CacheSet(bindLabelCache, id, label or false, 600)
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

	if on and db.unusable then
		ns.CheckItemUnusable = function(entry)
			return ItemInfo:IsUnusable(entry)
		end
	else
		ns.CheckItemUnusable = nil
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

	if on and db.unusable then
		RefreshUnusableEntries()
	end
	if ns.Scan and ns.Scan.RefreshDisplayFieldsAll then
		ns.Scan.RefreshDisplayFieldsAll()
		return
	end
	-- Display flags / overlay layout: bump DrawEpoch so panels repaint without a
	-- full rescan (rescan alone leaves SectionSignature unchanged).
	ns:RefreshBags(false)
end

function ItemInfo:OnEnable()
	BuildUnusable()
	playerLevel = UnitLevel("player") or 1
	wipe(itemLevelCache)
	if ns.Scan and ns.Scan.ClearItemCaches then
		ns.Scan.ClearItemCaches()
	end
	self:InvalidateUnusableCaches()
	self:Apply()
	self.levelUpHandler = self:RegisterEvent("PLAYER_LEVEL_UP", "OnLevelUp")
end

function ItemInfo:OnLevelUp(level)
	playerLevel = level or UnitLevel("player") or 1
	self:InvalidateUnusableCaches()
	RefreshUnusableEntries()
end

function ItemInfo:OnSettingChanged()
	self:Apply()
end

function ItemInfo:OnDisable()
	if self.levelUpHandler then
		ns:UnregisterEvent("PLAYER_LEVEL_UP", self.levelUpHandler)
		self.levelUpHandler = nil
	end
	self:Apply()
end

-- ---------------------------------------------------------------------------
-- Settings panel
-- ---------------------------------------------------------------------------
function ItemInfo:RegisterOptions(category, builder)
	local _, master = builder:Checkbox(category, self, "enable", L["Enable Item Info"], L["Show item level, bind status and unusable-item tinting on bag and bank slots."])

	local _, ilvl = builder:Checkbox(category, self, "itemLevel", L["Show Item Level"], L["Show the (quality-colored) item level on equippable gear."])
	builder:DependsOn(ilvl, master)

	local _, bind = builder:Checkbox(category, self, "bindText", L["Show Bind Status"], L["Show BoE, BoU, BoA and WuE labels on items that are not yet bound."])
	builder:DependsOn(bind, master)

	local _, unfit = builder:Checkbox(category, self, "unusable", L["Color Unusable Items"], L["Tint icons red for items your class can't use or that you're too low level for."])
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
