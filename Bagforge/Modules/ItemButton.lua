--[[
	Bagforge - ItemButton (pooled widget)
	-------------------------------------------------------------------------
	The recyclable item button the view hands out, one per occupied slot. We
	build on Blizzard's ContainerFrameItemButtonTemplate so clicking, dragging,
	splitting, tooltips and the secure "use item" path all come for free - we
	just feed it a bag id (on the parent) and a slot id (on the button), exactly
	as the default bags do.

	Two non-obvious tricks, both lifted from BetterBags:
	  * The ItemButton lives inside a plain throwaway parent frame. The parent
	    carries the bag id and is what the view anchors; this sidesteps the 10.x
	    item-button taint where reparenting a live container button gets cranky.
	  * We pre-warm the pool out of combat. A secure button created mid-combat
	    can taint the whole bag frame, so every button the player could possibly
	    need already exists, clean, before the first pull.
--]]

local _, ns = ...
local C, F, L = ns.C, ns.F, ns.L

local CreateFrame = CreateFrame
local C_Container = C_Container
local C_Timer = C_Timer
local ClearCursor = ClearCursor
local DeleteCursorItem = DeleteCursorItem
local InCombatLockdown = InCombatLockdown
local IsAltKeyDown = IsAltKeyDown
local IsControlKeyDown = IsControlKeyDown
local SetItemButtonTexture = SetItemButtonTexture
local SetItemButtonCount = SetItemButtonCount
local SetItemButtonQuality = SetItemButtonQuality
local SetItemButtonDesaturated = SetItemButtonDesaturated
local SetItemButtonTextureVertexColor = SetItemButtonTextureVertexColor
local ClearItemButtonOverlay = _G["ClearItemButtonOverlay"]
local ITEM_CLASS = Enum.ItemClass
local POOR_QUALITY = Enum.ItemQuality.Poor
local RARE_QUALITY = Enum.ItemQuality.Rare
local HEIRLOOM_QUALITY = Enum.ItemQuality.Heirloom
local QUALITY_COLORS = ns.C.QualityColors
local RED = _G["RED_FONT_COLOR"]

-- Bind labels are coloured like NexEnhance: account-bound variants in light
-- blue, everything else (BoE/BoU) plain white.
local function BindColor(label)
	if label == "BoA" or label == "WuE" then
		return 0, 0.8, 1
	end
	return 1, 1, 1
end

local ItemButton = ns:NewModule("ItemButton")

local buttonCount = 0
local slotButtons = {}

local VALID_CORNERS = {
	topleft = true,
	topright = true,
	bottomleft = true,
	bottomright = true,
}

local function OverlayCorner(key, fallback)
	local db = ns.db and ns.db.itemInfo
	local corner = db and db[key]
	if corner then
		corner = string.lower(corner)
	end
	if not (corner and VALID_CORNERS[corner]) then
		local defaults = ns.defaults and ns.defaults.profile and ns.defaults.profile.itemInfo
		corner = defaults and defaults[key] or fallback
	end
	return corner
end

function ItemButton:LayoutButtonOverlays(button)
	if not button then
		return
	end
	F.AnchorOverlayCorner(button.itemLevelText, button, OverlayCorner("itemLevelCorner", "bottomleft"))
	F.AnchorOverlayCorner(button.bindText, button, OverlayCorner("bindTextCorner", "topright"))
	local marker = OverlayCorner("markerCorner", "topleft")
	F.AnchorOverlayCorner(button.bfTag, button, marker, 1)
	F.AnchorOverlayCorner(button.bfJunk, button, marker, 1)
end

function ItemButton:ApplyOverlayLayout()
	local pool = self.pool
	if not pool or not pool.objects then
		return
	end
	for i = 1, #pool.objects do
		local parent = pool.objects[i]
		if parent.button then
			self:LayoutButtonOverlays(parent.button)
		end
	end
end

local function SlotKey(bag, slot)
	return bag * 1000 + slot
end

local function UnregisterSlot(parent)
	local key = parent.slotKey
	if key and slotButtons[key] == parent then
		slotButtons[key] = nil
	end
	parent.slotKey = nil
	parent.entry = nil
end

-- ---------------------------------------------------------------------------
-- Button behaviour
--   `self` is the parent frame (the thing the view anchors). It owns the bag
--   id; `self.button` is the actual ItemButton and owns the slot id. Methods
--   are module-level function references (not per-button closures) so a pool of
--   hundreds doesn't cost hundreds of duplicate closures.
-- ---------------------------------------------------------------------------

-- `entry` is one slot record from Items:GetSlots().
local function Button_SetItem(self, entry)
	local key = SlotKey(entry.bag, entry.slot)
	if self.slotKey ~= key then
		UnregisterSlot(self)
		self.slotKey = key
	end
	self.entry = entry
	slotButtons[key] = self

	self:SetID(entry.bag)
	self.button:SetID(entry.slot)

	if ClearItemButtonOverlay then
		ClearItemButtonOverlay(self.button)
	end
	SetItemButtonTexture(self.button, entry.icon)
	-- Bag stack counts are readable in Midnight, but guard anyway - it's cheap
	-- and SetItemButtonCount does a comparison internally that a secret would
	-- choke on.
	SetItemButtonCount(self.button, F.NotSecret(entry.count) and entry.count or 1)
	-- Stock quality ring (suppressOverlays = false) - Blizzard's default look.
	SetItemButtonQuality(self.button, entry.quality, entry.hyperlink, false, entry.isBound)
	SetItemButtonDesaturated(self.button, entry.isLocked)

	self.button:SetHasItem(entry.icon)
	if self.button.UpdateExtended then
		self.button:UpdateExtended()
	end
	if self.button.UpdateQuestItem then
		self.button:UpdateQuestItem(entry.quest, entry.questID, entry.isActiveQuest)
	end
	if self.button.UpdateNewItem then
		self.button:UpdateNewItem(entry.quality)
	end
	-- We draw our own always-on junk coin (below), so keep Blizzard's merchant-only
	-- JunkIcon suppressed to avoid a doubled coin in the same corner.
	if self.button.JunkIcon then
		self.button.JunkIcon:Hide()
	end
	if self.button.UpdateItemContextMatching then
		self.button:UpdateItemContextMatching()
	end
	-- Blizzard's bag search desaturates non-matching items in place (rather than
	-- hiding them). entry.isFiltered comes from C_Container after SetItemSearch.
	if self.button.SetMatchesSearch then
		local hide = ns.db and ns.db.organize and ns.db.organize.searchHideNonMatches
		local matches = hide or not entry.isFiltered
		self.button:SetMatchesSearch(matches)
	end
	if self.button.UpdateCooldown then
		self.button:UpdateCooldown(entry.icon)
	end
	if self.button.SetReadable then
		self.button:SetReadable(entry.readable)
	end

	-- Item level (quality-coloured) on equippable gear. Gated by the ItemInfo
	-- module's live flag so the toggle applies without per-button bookkeeping.
	local levelText = self.button.itemLevelText
	if levelText then
		local level = ns.ShowItemLevel and (entry.classID == ITEM_CLASS.Weapon or entry.classID == ITEM_CLASS.Armor) and entry.ilvl
		if level and F.NotSecret(level) and level > 0 then
			levelText:SetText(level)
			local color = QUALITY_COLORS and QUALITY_COLORS[entry.quality]
			if color then
				levelText:SetTextColor(color[1], color[2], color[3])
			else
				levelText:SetTextColor(1, 1, 1)
			end
			levelText:Show()
		else
			levelText:SetText("")
			levelText:Hide()
		end
	end

	-- Bind status (BoE / BoU / BoA / WuE). ns.GetItemBindLabel is published by
	-- the ItemInfo module only while the toggle is on (nil otherwise).
	local bindText = self.button.bindText
	if bindText then
		local label = ns.GetItemBindLabel and ns.GetItemBindLabel(entry)
		if label then
			bindText:SetText(label)
			bindText:SetTextColor(BindColor(label))
			bindText:Show()
		else
			bindText:SetText("")
			bindText:Hide()
		end
	end

	-- Unusable tint: red the icon for items this class can't use / is too low
	-- for. Mirrors Blizzard's own unusable cue. Skip when locked (Blizzard's
	-- desaturation owns that case). ns.IsItemUnusable is nil when off.
	if ns.IsItemUnusable and not entry.isLocked and ns.IsItemUnusable(entry) then
		SetItemButtonTextureVertexColor(self.button, RED and RED.r or 1, RED and RED.g or 0.1, RED and RED.b or 0.1)
		self.button.bfUnfit = true
	elseif self.button.bfUnfit then
		SetItemButtonTextureVertexColor(self.button, 1, 1, 1)
		self.button.bfUnfit = nil
	end

	-- Pawn (or any plugin corner widget) may show an upgrade arrow via API.
	local upgradeIcon = self.button.upgradeIcon
	if upgradeIcon then
		local check = ns.PawnIsUpgrade
		local useLegacy = check ~= nil
		if useLegacy and ns.API and ns.API.HasCornerWidget then
			useLegacy = not ns.API:HasCornerWidget("pawn.upgrade")
		end
		upgradeIcon:SetShown(useLegacy and check(entry.hyperlink) == true)
	end

	if ItemButton.UpdateCornerWidgets then
		ItemButton:UpdateCornerWidgets(self.button, entry)
	end

	-- Sort-lock overlay (Ctrl+right-click toggle).
	if self.button.bfSortLock then
		local organize = ns:GetModule("Organize")
		local locked = organize and organize:IsSortLocked(entry.bag, entry.slot)
		self.button.bfSortLock:SetShown(locked and true or false)
	end

	-- Top-left markers. The star flags a custom-assigned item (NDui's Favourite
	-- cue); the coin flags junk - both the game's natural Poor-quality junk AND
	-- anything the player custom-flagged - shown always (not just at a merchant,
	-- which is all Blizzard's own JunkIcon does). Only one shows: star wins.
	local tag, junkMark = self.button.bfTag, self.button.bfJunk
	if tag or junkMark then
		local o = ns.db and ns.db.organize
		local junkList = ns.global and ns.global.customJunk
		local id = entry.itemID
		local safe = id and F.NotSecret(id)
		local tagged = o and o.customEnable and safe and o.assignments[id]
		local junked = (F.NotSecret(entry.quality) and entry.quality == POOR_QUALITY and not entry.noValue) or (junkList and safe and junkList[id] and true)
		if tag then
			tag:SetShown(tagged and true or false)
		end
		if junkMark then
			junkMark:SetShown((not tagged) and junked and true or false)
		end
	end

	self.button:Show()
end

local function Button_Clear(self)
	UnregisterSlot(self)
	self:SetID(0)
	self.button:SetID(0)
	if ClearItemButtonOverlay then
		ClearItemButtonOverlay(self.button)
	end
	SetItemButtonTexture(self.button, nil)
	SetItemButtonCount(self.button, 0)
	SetItemButtonQuality(self.button, nil)
	SetItemButtonDesaturated(self.button, false)
	-- Drop any unusable tint so a reused button doesn't carry red over.
	if self.button.bfUnfit then
		SetItemButtonTextureVertexColor(self.button, 1, 1, 1)
		self.button.bfUnfit = nil
	end
	self.button:SetHasItem(false)
	if self.button.UpdateQuestItem then
		self.button:UpdateQuestItem(false, nil, nil)
	end
	if self.button.UpdateNewItem then
		self.button:UpdateNewItem(false)
	end
	if self.button.UpdateJunkItem then
		self.button:UpdateJunkItem(false, false)
	end
	if self.button.UpdateCooldown then
		self.button:UpdateCooldown(false)
	end
	if self.button.SetReadable then
		self.button:SetReadable(false)
	end
	if self.button.itemLevelText then
		self.button.itemLevelText:SetText("")
		self.button.itemLevelText:Hide()
	end
	if self.button.bindText then
		self.button.bindText:SetText("")
		self.button.bindText:Hide()
	end
	if self.button.upgradeIcon then
		self.button.upgradeIcon:Hide()
	end
	if self.button.bfTag then
		self.button.bfTag:Hide()
	end
	if self.button.bfJunk then
		self.button.bfJunk:Hide()
	end
	if self.button.bfSortLock then
		self.button.bfSortLock:Hide()
	end
	if ItemButton.HideCornerWidgets then
		ItemButton:HideCornerWidgets(self.button)
	end
end

-- Ctrl is WoW's default DRESSUP modifier, so a Ctrl(+Alt) click on a bag item
-- normally opens the dressing room before our delete post-hook can act. Blizzard's
-- ContainerFrameItemButtonMixin:OnModifiedClick bails the moment HandleModifiedItemClick
-- reports the click handled, so while delete mode is armed and the player holds the
-- delete combo we swallow it here. HandleModifiedItemClick is an insecure FrameXML
-- global, and the guard is narrow (delete mode + Ctrl+Alt only), so nothing else is
-- affected.
local origHandleModifiedItemClick = _G["HandleModifiedItemClick"]
if origHandleModifiedItemClick then
	_G["HandleModifiedItemClick"] = function(link, itemLocation)
		local organize = ns:GetModule("Organize")
		if organize and organize.mode == "delete" and IsAltKeyDown() and IsControlKeyDown() then
			return true
		end
		return origHandleModifiedItemClick(link, itemLocation)
	end
end

-- While Organize's assign mode is armed, a left-click on any item opens its
-- "set category" menu instead of doing anything with the item. This is a post
-- -hook (observation only, no taint): Blizzard's default left-click picks the
-- item up onto the cursor, so we ClearCursor() to drop it straight back before
-- showing the menu - exactly how NDui's Favourite mode behaves.
local function OnItemButtonClick(button, mouseButton)
	local parent = button:GetParent()
	local entry = parent and parent.entry
	if not entry then
		return
	end
	if ns.Recent then
		ns.Recent:Clear(entry.bag, entry.slot)
	end

	local organize = ns:GetModule("Organize")
	local mode = organize and organize.mode

	if mouseButton == "LeftButton" and not mode and IsAltKeyDown() and not IsControlKeyDown() then
		local db = ns.db and ns.db.backpack
		if (not db or db.flashFind ~= false) and entry.itemID and F.NotSecret(entry.itemID) then
			ItemButton:FlashFind(entry.itemID)
		end
		if ClearCursor then
			ClearCursor()
		end
		return
	end

	if mouseButton == "RightButton" then
		if not mode and IsControlKeyDown() and organize then
			organize:ToggleSortLock(entry.bag, entry.slot)
			if parent.SetItemEntry then
				parent:SetItemEntry(entry)
			end
		end
		return
	end

	if mouseButton and mouseButton ~= "LeftButton" then
		return
	end
	if not mode then
		return
	end
	if mode == "delete" then
		if InCombatLockdown() then
			F.Print(L["Can't delete items during combat."])
			if ClearCursor then
				ClearCursor()
			end
			return
		end
		local quality = entry.quality
		local canDelete = DeleteCursorItem and C_Container and C_Container.PickupContainerItem and IsAltKeyDown() and IsControlKeyDown() and entry.icon and quality ~= nil and F.NotSecret(quality) and (quality < RARE_QUALITY or quality == HEIRLOOM_QUALITY)
		if canDelete then
			if ClearCursor then
				ClearCursor()
			end
			C_Container.PickupContainerItem(entry.bag, entry.slot)
			DeleteCursorItem()
			ns:RefreshBags(true)
		elseif ClearCursor then
			-- This click hook runs after Blizzard's default item click, which
			-- picked the item up. Put it back unless every delete safety gate
			-- passed.
			ClearCursor()
		end
		return
	end
	if ClearCursor then
		ClearCursor()
	end
	if mode == "assign" then
		organize:OpenAssignMenu(button, entry)
	elseif mode == "junk" then
		organize:ToggleJunk(entry)
	end
end

function ItemButton:FlashButton(button)
	if not button then
		return
	end
	if button.flashAnim and button.flashAnim.Play then
		button.flashAnim:Play()
		return
	end
	local glow = button.bfFlashGlow
	if not glow then
		glow = button:CreateTexture(nil, "OVERLAY", nil, 7)
		glow:SetAtlas("bags-newitem")
		glow:SetBlendMode("ADD")
		glow:SetPoint("TOPLEFT", button, "TOPLEFT", -2, 2)
		glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
		button.bfFlashGlow = glow
	end
	glow:Show()
	glow:SetAlpha(1)
	if button.bfFlashTimer then
		button.bfFlashTimer:Cancel()
	end
	button.bfFlashTimer = C_Timer.NewTimer(1.2, function()
		if glow then
			glow:Hide()
		end
		button.bfFlashTimer = nil
	end)
end

--- Alt-click flash-find (Bagnon flashFind): pulse every visible stack of `itemID`.
function ItemButton:FlashFind(itemID)
	if not itemID or F.IsSecret(itemID) then
		return
	end
	local hits = 0
	for _, parent in pairs(slotButtons) do
		local entry = parent.entry
		if entry and entry.itemID == itemID and parent:IsShown() then
			hits = hits + 1
			self:FlashButton(parent.button)
		end
	end
	if hits == 0 then
		F.Print(L["No matching items in open bags."])
	end
end

-- ---------------------------------------------------------------------------
-- Pool plumbing
-- ---------------------------------------------------------------------------
local function CreateButton()
	buttonCount = buttonCount + 1
	local name = "BagforgeItemButton" .. buttonCount

	-- Hidden parent: holds the bag id and is what the grid anchors.
	local parent = CreateFrame("Button", name .. "Parent", UIParent)
	parent:SetSize(C.Layout.ITEM_SIZE, C.Layout.ITEM_SIZE)

	local button = CreateFrame("ItemButton", name, parent, "ContainerFrameItemButtonTemplate")
	button:SetAllPoints(parent)
	button:RegisterForDrag("LeftButton")
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:HookScript("OnClick", OnItemButtonClick)

	-- Item level: bottom-left, outlined, quality-coloured at paint time.
	local itemLevelText = F.CreateFS(button, 12, "", "OVERLAY")
	local font = itemLevelText:GetFont()
	if font then
		itemLevelText:SetFont(font, 12, "OUTLINE")
	end
	itemLevelText:SetTextColor(1, 1, 1)
	itemLevelText:Hide()
	button.itemLevelText = itemLevelText

	-- Bind label (BoE / BoU / BoA / WuE).
	local bindText = F.CreateFS(button, 11, "", "OVERLAY")
	local bindFont = bindText:GetFont()
	if bindFont then
		bindText:SetFont(bindFont, 11, "OUTLINE")
	end
	bindText:Hide()
	button.bindText = bindText

	-- Pawn-style upgrade arrow (Blizzard's stock "bags-greenarrow" atlas),
	-- anchored to the left edge. Hidden until an upgrade provider asks.
	local upgradeIcon = button:CreateTexture(nil, "OVERLAY")
	upgradeIcon:SetSize(20, 22)
	upgradeIcon:SetPoint("LEFT", button, "LEFT", 1, 0)
	upgradeIcon:SetAtlas("bags-greenarrow")
	upgradeIcon:Hide()
	button.upgradeIcon = upgradeIcon

	-- Custom-category marker (top-left star), shown on assigned items. High
	-- sublevel so it sits above the quality/IconBorder (also on OVERLAY).
	local tag = button:CreateTexture(nil, "OVERLAY", nil, 7)
	tag:SetAtlas("transmog-icon-favorite")
	tag:SetSize(14, 14)
	tag:Hide()
	button.bfTag = tag

	-- Custom-junk marker (coin), shown on items marked as junk. Uses the same
	-- "bags-junkcoin" atlas as Blizzard's own merchant junk coin so it reads as
	-- junk at a glance. Shares the corner with the star; only one shows at a time
	-- (star wins). Drawn one sublevel up so it sits above the item texture.
	local junk = button:CreateTexture(nil, "OVERLAY", nil, 7)
	junk:SetAtlas("bags-junkcoin")
	junk:SetSize(17, 17)
	junk:Hide()
	button.bfJunk = junk

	local sortLock = button:CreateTexture(nil, "OVERLAY", nil, 7)
	sortLock:SetAtlas("loottoast-lock")
	sortLock:SetSize(14, 14)
	sortLock:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
	sortLock:Hide()
	button.bfSortLock = sortLock

	F.InstallTooltipThrottle(button)

	ItemButton:LayoutButtonOverlays(button)

	parent.button = button
	parent.SetItemEntry = Button_SetItem
	parent.ClearItem = Button_Clear

	return parent
end

-- When a button is released back to the pool, blank it so a stale icon never
-- flashes when it's reused for a different item.
local function ResetButton(parent)
	parent:ClearItem()
	parent:SetParent(UIParent)
end

function ItemButton:OnEnable()
	self.pool = F.CreatePool(CreateButton, ResetButton)

	-- Backpack (~220 slots) plus a merged bank view can exceed 300 while both
	-- windows are open; prewarm enough that no secure button is created in combat.
	self.pool:Prewarm(650)
	self:ApplyOverlayLayout()
end

function ItemButton:Acquire()
	return self.pool:Acquire()
end

--- Release a single button back to the pool. Each category panel tracks and
--- frees only the buttons it borrowed, so two windows (backpack + bank) can
--- draw from this one shared pool without stomping each other - a global
--- ReleaseAll would yank the other window's buttons out from under it.
function ItemButton:Release(button)
	self.pool:Release(button)
end

function ItemButton:GetSlotButton(bag, slot)
	return slotButtons[SlotKey(bag, slot)]
end

function ItemButton:RefreshItemID(itemID)
	if not (itemID and F.NotSecret(itemID)) then
		return
	end
	for _, parent in pairs(slotButtons) do
		local entry = parent.entry
		if entry and entry.itemID == itemID then
			parent:SetItemEntry(entry)
		end
	end
end

function ItemButton:RefreshSlot(bag, slot)
	local button = self:GetSlotButton(bag, slot)
	local entry = button and button.entry
	if not entry then
		return false
	end

	local info = C_Container.GetContainerItemInfo(bag, slot)
	if not (info and info.itemID) then
		return false
	end

	entry.isLocked = info.isLocked and true or false
	button:SetItemEntry(entry)
	return true
end

function ItemButton:ReleaseAll()
	self.pool:ReleaseAll()
end

local CORNER_ANCHORS = {
	topleft = { "TOPLEFT", "TOPLEFT", 1, -1 },
	topright = { "TOPRIGHT", "TOPRIGHT", -1, -1 },
	bottomleft = { "BOTTOMLEFT", "BOTTOMLEFT", 1, 1 },
	bottomright = { "BOTTOMRIGHT", "BOTTOMRIGHT", -1, 1 },
	left = { "LEFT", "LEFT", 2, 0 },
	right = { "RIGHT", "RIGHT", -2, 0 },
}

local function EnsureCornerTexture(button, corner)
	local corners = button.bfCorners
	if not corners then
		corners = {}
		button.bfCorners = corners
	end
	local tex = corners[corner]
	if not tex then
		tex = button:CreateTexture(nil, "OVERLAY", nil, 7)
		corners[corner] = tex
		local anchor = CORNER_ANCHORS[corner]
		if anchor then
			tex:SetPoint(anchor[1], button, anchor[2], anchor[3], anchor[4])
		end
		tex:Hide()
	end
	return tex
end

function ItemButton:HideCornerWidgets(button)
	if not button or not button.bfCorners then
		return
	end
	for _, tex in pairs(button.bfCorners) do
		tex:Hide()
	end
end

function ItemButton:UpdateCornerWidgets(button, entry)
	local API = ns.API
	if not (API and API.UpdateCornerWidgets) then
		return
	end
	API:UpdateCornerWidgets(button, entry, EnsureCornerTexture)
end
