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
local C_Item = C_Item
local ItemLocation = ItemLocation
local SetItemButtonTexture = SetItemButtonTexture
local SetItemButtonCount = SetItemButtonCount
local SetItemButtonQuality = SetItemButtonQuality
local SetItemButtonDesaturated = SetItemButtonDesaturated
local SetItemButtonTextureVertexColor = SetItemButtonTextureVertexColor
local ClearItemButtonOverlay = _G["ClearItemButtonOverlay"]
local RARE_QUALITY = Enum.ItemQuality.Rare
local HEIRLOOM_QUALITY = Enum.ItemQuality.Heirloom
local QUALITY_COLORS = ns.C.QualityColors
local RED = _G["RED_FONT_COLOR"]
local UNUSABLE_TINT_R = 0.9
local UNUSABLE_TINT_G = 0
local UNUSABLE_TINT_B = 0

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
local slotsByBag = {}
local combatLayoutPending = false
local bankRouted = setmetatable({}, { __mode = "k" })
local highlightedBagID = nil
local FindSlotButton -- forward decl; assigned below RefreshSlot helpers

local function ClearBagHighlightFor(bagID)
	local set = slotsByBag[bagID]
	if not set then
		return
	end
	for parent in pairs(set) do
		local button = parent.button
		if button and button.BagIndicator then
			button.BagIndicator:Hide()
		end
	end
end

local VALID_CORNERS = {
	topleft = true,
	topright = true,
	bottomleft = true,
	bottomright = true,
	top = true,
	bottom = true,
	left = true,
	right = true,
	center = true,
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
	return F.SlotKey(bag, slot)
end

local function UnregisterSlot(parent)
	local key = parent.slotKey
	if key and slotButtons[key] == parent then
		slotButtons[key] = nil
	end
	if parent._highlightBag then
		local set = slotsByBag[parent._highlightBag]
		if set then
			set[parent] = nil
		end
		parent._highlightBag = nil
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

--- Red icon tint for wrong-class / under-level gear. Runs last so cooldown
--- updates and corner widgets don't stomp the vertex colour afterward.
local function ApplyUnusableTint(parent, entry)
	if not (parent and parent.button and entry) then
		return
	end
	local button = parent.button
	local itemInfoDb = ns.db and ns.db.itemInfo
	local showUnusable = itemInfoDb and itemInfoDb.enable and itemInfoDb.unusable
	if not showUnusable or entry.isLocked then
		if button.bfUnfit then
			SetItemButtonTextureVertexColor(button, 1, 1, 1)
			button.bfUnfit = nil
		end
		return
	end

	local unfit = entry.isUnusable
	if not unfit and ns.CheckItemUnusable then
		unfit = ns.CheckItemUnusable(entry) and true or false
		if unfit then
			entry.isUnusable = true
		end
	end

	if unfit then
		SetItemButtonTextureVertexColor(button, RED and RED.r or UNUSABLE_TINT_R, RED and RED.g or UNUSABLE_TINT_G, RED and RED.b or UNUSABLE_TINT_B)
		button.bfUnfit = true
	elseif button.bfUnfit then
		SetItemButtonTextureVertexColor(button, 1, 1, 1)
		button.bfUnfit = nil
	end
end

-- Warband / bank deposit dim is Blizzard ItemContextOverlay (0.8 black) via
-- UpdateItemContextMatching — do NOT add a second overlay. 1.5.0 stacked an
-- Ellesmere-style 0.75 dim on top and icons went pitch black.

-- `entry` is one slot record from Items:GetSlots().
local function SnapshotButtonPaint(entry)
	return {
		icon = entry.icon,
		count = entry.count,
		quality = entry.quality,
		isLocked = entry.isLocked,
		hyperlink = entry.hyperlink,
		isFiltered = entry.isFiltered,
		quest = entry.quest,
		questID = entry.questID,
		isActiveQuest = entry.isActiveQuest,
		readable = entry.readable,
		showIlvl = entry.showIlvl,
		ilvl = entry.ilvl,
		showBindLabel = entry.showBindLabel,
		isUpgrade = entry.isUpgrade,
		isUnusable = entry.isUnusable,
		itemID = entry.itemID,
		isNewItem = entry.isNewItem,
	}
end

local function ButtonPaintUnchanged(snap, entry)
	return snap.icon == entry.icon
		and snap.count == entry.count
		and snap.quality == entry.quality
		and snap.isLocked == entry.isLocked
		and snap.hyperlink == entry.hyperlink
		and snap.isFiltered == entry.isFiltered
		and snap.quest == entry.quest
		and snap.questID == entry.questID
		and snap.isActiveQuest == entry.isActiveQuest
		and snap.readable == entry.readable
		and snap.showIlvl == entry.showIlvl
		and snap.ilvl == entry.ilvl
		and snap.showBindLabel == entry.showBindLabel
		and snap.isUpgrade == entry.isUpgrade
		and snap.isUnusable == entry.isUnusable
		and snap.itemID == entry.itemID
		and snap.isNewItem == entry.isNewItem
end

local function Button_SetItem(self, entry)
	if not entry then
		return
	end
	local key = SlotKey(entry.bag, entry.slot)
	if self.slotKey ~= key then
		UnregisterSlot(self)
		self.slotKey = key
		self._paintSnap = nil
	end
	self.entry = entry
	slotButtons[key] = self

	local snap = self._paintSnap
	if snap and ButtonPaintUnchanged(snap, entry) then
		return
	end

	local bag = entry.bag
	if self._highlightBag and self._highlightBag ~= bag then
		local old = slotsByBag[self._highlightBag]
		if old then
			old[self] = nil
		end
	end
	self._highlightBag = bag
	if not slotsByBag[bag] then
		slotsByBag[bag] = {}
	end
	slotsByBag[bag][self] = true

	self:SetID(entry.bag)
	self.button:SetID(entry.slot)

	if ClearItemButtonOverlay then
		ClearItemButtonOverlay(self.button)
	end
	SetItemButtonTexture(self.button, entry.icon)
	SetItemButtonCount(self.button, entry.count or 1)
	-- ClearItemButtonOverlay does NOT clear IconBorder (ItemButtonTemplate.lua).
	-- Always SetItemButtonQuality so recycled buttons don't keep a stale ring.
	-- Quality must be the *instance* (container / link / ItemLocation) — bare
	-- GetItemQualityByID(itemID) is the item template and often Uncommon/green
	-- while bonus-ID gear is Epic (Baganator live buttons use cache/container).
	local quality = nil
	local bag, slot = entry.bag, entry.slot
	if bag and slot and ItemLocation and C_Item.GetItemQuality then
		local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
		if loc and C_Item.DoesItemExist and C_Item.DoesItemExist(loc) then
			quality = C_Item.GetItemQuality(loc)
		end
	end
	if quality == nil then
		local link = entry.hyperlink
		if link and C_Item.GetItemQualityByID then
			quality = C_Item.GetItemQualityByID(link)
		end
	end
	if quality == nil then
		quality = entry.quality
	end
	if quality ~= nil then
		SetItemButtonQuality(self.button, quality, entry.hyperlink or entry.itemID, false, entry.isBound)
	else
		SetItemButtonQuality(self.button, nil)
	end
	if SetItemCraftingQualityOverlay then
		local link = entry.hyperlink
		if link then
			SetItemCraftingQualityOverlay(self.button, link)
		end
	end
	SetItemButtonDesaturated(self.button, entry.isLocked)

	self.button:SetHasItem(entry.icon)
	if self.button.UpdateExtended then
		self.button:UpdateExtended()
	end
	if self.button.UpdateQuestItem then
		local quest = entry.quest
		local questID = entry.questID
		local active = entry.isActiveQuest
		if quest == nil then
			quest = false
		end
		if active == nil then
			active = false
		end
		self.button:UpdateQuestItem(quest, questID, active)
	end
	if self.button.UpdateNewItem then
		self.button:UpdateNewItem(quality ~= nil and quality or false)
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
	-- Run after context matching so deposit-context and search overlays compose.
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

	-- Item level (quality-coloured) on equippable gear. Pre-computed on the scan
	-- entry as entry.showIlvl so paint time stays presentation-only.
	local levelText = self.button.itemLevelText
	if levelText then
		if entry.showIlvl then
			local level = entry.ilvl
			levelText:SetText(level)
			local color = quality ~= nil and QUALITY_COLORS and QUALITY_COLORS[quality]
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

	-- Bind status (BoE / BoU / BoA / WuE). Pre-computed as entry.showBindLabel.
	local bindText = self.button.bindText
	if bindText then
		local label = entry.showBindLabel
		if label then
			bindText:SetText(label)
			bindText:SetTextColor(BindColor(label))
			bindText:Show()
		else
			bindText:SetText("")
			bindText:Hide()
		end
	end

	-- Pawn upgrade arrow — pre-computed on the entry as entry.isUpgrade.
	local upgradeIcon = self.button.upgradeIcon
	if upgradeIcon then
		upgradeIcon:SetShown(entry.isUpgrade == true)
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
		local categories = ns:GetModule("Categories")
		local id = entry.itemID
		local petTrash = id and categories and categories.IsPetTrashItem and categories:IsPetTrashItem(id)
		local tagged = o and o.customEnable and id and o.assignments[id]
		local junked = not tagged and not petTrash and ns.API and ns.API.IsItemJunk and ns.API:IsItemJunk(entry)
		if tag then
			tag:SetShown(tagged and true or false)
		end
		if junkMark then
			junkMark:SetShown((not tagged) and junked and true or false)
		end
	end

	ApplyUnusableTint(self, entry)

	if ns.API and ns.API._FireItemButtonCallbacks then
		ns.API:_FireItemButtonCallbacks(self.button, entry.bag, entry.slot, entry)
	end

	self.button:Show()
	self._paintSnap = SnapshotButtonPaint(entry)
end

local function Button_Clear(self)
	UnregisterSlot(self)
	self._paintSnap = nil
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
	if self.button.SetMatchesSearch then
		self.button:SetMatchesSearch(true)
	end
	if self.button.UpdateItemContextMatching then
		self.button:UpdateItemContextMatching()
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
	if self.button.BagIndicator then
		self.button.BagIndicator:Hide()
	end
	if ItemButton.HideCornerWidgets then
		ItemButton:HideCornerWidgets(self.button)
	end
	if self.button.TLHOverlay then
		self.button.TLHOverlay:Hide()
	end
end

-- Ctrl is WoW's default DRESSUP modifier; delete mode installs a narrow global
-- hook via InstallDeleteClickHook (Organize:SetMode) so Ctrl+Alt is not stolen
-- from other bag addons while delete mode is disarmed.

local origHandleModifiedItemClick
local deleteClickHooked = false
local deleteClickWrapper

function ItemButton:InstallDeleteClickHook()
	if deleteClickHooked then
		return
	end
	origHandleModifiedItemClick = _G["HandleModifiedItemClick"]
	if not origHandleModifiedItemClick then
		return
	end
	-- Narrow replace while delete mode is armed: swallow Ctrl+Alt so dress-up
	-- doesn't steal the click. Uninstall restores the prior global only if we
	-- still own it (another addon may have wrapped after us).
	deleteClickWrapper = function(link, itemLocation)
		local organize = ns:GetModule("Organize")
		if organize and organize.mode == "delete" and IsAltKeyDown() and IsControlKeyDown() then
			return true
		end
		return origHandleModifiedItemClick(link, itemLocation)
	end
	_G["HandleModifiedItemClick"] = deleteClickWrapper
	deleteClickHooked = true
end

function ItemButton:UninstallDeleteClickHook()
	if not deleteClickHooked then
		return
	end
	if deleteClickWrapper and _G["HandleModifiedItemClick"] == deleteClickWrapper and origHandleModifiedItemClick then
		_G["HandleModifiedItemClick"] = origHandleModifiedItemClick
	end
	deleteClickHooked = false
	deleteClickWrapper = nil
	origHandleModifiedItemClick = nil
end

-- While Organize's assign mode is armed, a left-click on any item opens its
-- "set category" menu instead of doing anything with the item. This is a post
-- -hook (observation only, no taint): Blizzard's default left-click picks the
-- item up onto the cursor, so we ClearCursor() to drop it straight back before
-- showing the menu - exactly how NDui's Favourite mode behaves.
local function OnItemButtonClick(button, mouseButton)
	if mouseButton == "RightButton" and bankRouted[button] then
		bankRouted[button] = nil
		if ClearCursor then
			ClearCursor()
		end
		return
	end

	local parent = button:GetParent()
	local entry = parent and parent.entry
	if not entry then
		return
	end
	local wasNew = entry.isNewItem
	if ns.Recent then
		ns.Recent:Clear(entry.bag, entry.slot)
	end
	if wasNew and ns.RefreshRecentSlot then
		ns:RefreshRecentSlot(entry.bag, entry.slot)
	end

	local organize = ns:GetModule("Organize")
	local mode = organize and organize.mode

	if mouseButton == "LeftButton" and not mode and IsAltKeyDown() and not IsControlKeyDown() then
		local db = ns.db and ns.db.backpack
		if (not db or db.flashFind ~= false) and entry.itemID then
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
		local canDelete = DeleteCursorItem and C_Container and C_Container.PickupContainerItem and IsAltKeyDown() and IsControlKeyDown() and entry.icon and quality ~= nil and (quality < RARE_QUALITY or quality == HEIRLOOM_QUALITY)
		if canDelete then
			if ClearCursor then
				ClearCursor()
			end
			C_Container.PickupContainerItem(entry.bag, entry.slot)
			DeleteCursorItem()
			-- BAG_UPDATE from the delete retriggers the normal dirty-bag flush.
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
	if not itemID then
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
	-- Never birth a secure ContainerFrameItemButtonTemplate mid-combat: a button
	-- created under lockdown taints UseContainerItem (ADDON_ACTION_FORBIDDEN in
	-- M+/Delves). The pre-warmed pool should cover normal counts; this guard is
	-- the belt on Acquire() when the pool is somehow exhausted in combat.
	if InCombatLockdown() then
		ItemButton:FlagCombatLayoutPending()
		return nil
	end

	buttonCount = buttonCount + 1
	local name = "BagforgeItemButton" .. buttonCount

	-- Hidden parent: holds the bag id and is what the grid anchors.
	local parent = CreateFrame("Button", name .. "Parent", UIParent)
	parent:SetSize(C.Layout.ITEM_SIZE, C.Layout.ITEM_SIZE)
	-- Blizzard's ItemButton Initialize calls GetBagID on the parent; without a
	-- bag container stub this can nil-crash in combat (BetterBags #991).
	parent.IsCombinedBagContainer = function()
		return false
	end

	local button = CreateFrame("ItemButton", name, parent, "ContainerFrameItemButtonTemplate")
	button:SetAllPoints(parent)
	button:RegisterForDrag("LeftButton")
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	-- Let scroll events reach the parent WowScrollBox (BetterBags item.lua).
	button:SetScript("OnMouseWheel", nil)
	if button.EnableMouseWheel then
		button:EnableMouseWheel(false)
	end
	button:HookScript("OnClick", OnItemButtonClick)

	-- Right-click deposit routing while the bank is open: queue transfers to the
	-- selected purchased tab instead of letting Blizzard scatter items. State lives
	-- in a weak table so we never taint the secure template button table.
	button:HookScript("PreClick", function(self, mouseButton)
		if mouseButton ~= "RightButton" then
			return
		end
		local parent = self:GetParent()
		local srcBag = parent and parent:GetID()
		local srcSlot = self:GetID()
		if not (srcBag and srcSlot and srcSlot ~= 0) then
			return
		end
		if not (C.IS_BACKPACK_BAG and C.IS_BACKPACK_BAG[srcBag]) then
			return
		end
		local transfers = ns:GetModule("Transfers")
		if transfers and transfers.QueueDeposit and transfers:QueueDeposit(srcBag, srcSlot) then
			bankRouted[self] = true
		end
	end)

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
	-- centred on the icon. Hidden until an upgrade provider asks.
	local upgradeIcon = button:CreateTexture(nil, "OVERLAY")
	upgradeIcon:SetSize(20, 22)
	upgradeIcon:SetPoint("CENTER", button, "CENTER", 0, 0)
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
	if parent.button then
		F.TooltipThrottleLeave(parent.button)
		if parent.button.bfFlashTimer then
			parent.button.bfFlashTimer:Cancel()
			parent.button.bfFlashTimer = nil
		end
	end
	parent:ClearItem()
	parent:SetScale(1) -- drop any per-view icon-size scale before the next reuse
	parent:SetParent(UIParent)
end

function ItemButton:ClearBagHighlight()
	if highlightedBagID ~= nil then
		ClearBagHighlightFor(highlightedBagID)
		highlightedBagID = nil
	end
end

function ItemButton:SetBagHighlight(bagID, highlight)
	if not bagID then
		return
	end
	if highlight then
		if highlightedBagID ~= nil and highlightedBagID ~= bagID then
			ClearBagHighlightFor(highlightedBagID)
		end
		highlightedBagID = bagID
		local set = slotsByBag[bagID]
		if not set then
			return
		end
		for parent in pairs(set) do
			if parent:IsShown() and parent.button and parent.button.BagIndicator then
				parent.button.BagIndicator:Show()
			end
		end
	else
		if highlightedBagID == bagID then
			self:ClearBagHighlight()
		else
			ClearBagHighlightFor(bagID)
		end
	end
end

function ItemButton:FlagCombatLayoutPending()
	if combatLayoutPending then
		return
	end
	combatLayoutPending = true
	local backpack = ns:GetModule("Backpack")
	if backpack then
		backpack.pendingDraw = true
	end
	local bank = ns:GetModule("Bank")
	if bank and bank.views then
		for i = 1, #bank.views do
			bank.views[i].pendingDraw = true
		end
	end
end

function ItemButton:RefreshCooldowns()
	for _, parent in pairs(slotButtons) do
		local button = parent.button
		local entry = parent.entry
		if button and button:IsShown() and entry and button.UpdateCooldown then
			button:UpdateCooldown(entry.icon)
			ApplyUnusableTint(parent, entry)
		end
	end
end

--- Lock flash only — Baganator LiveBagOnEvent ITEM_LOCK_CHANGED (no full Draw).
function ItemButton:RefreshLock(bag, slot)
	local parent = FindSlotButton(bag, slot)
	if not (parent and parent.button) then
		return
	end
	local locked = false
	if bag and slot and C_Container.GetContainerItemInfo then
		local info = C_Container.GetContainerItemInfo(bag, slot)
		locked = F.SafeBool(info and info.isLocked) == true
	end
	if parent.entry then
		parent.entry.isLocked = locked
	end
	SetItemButtonDesaturated(parent.button, locked)
	ApplyUnusableTint(parent, parent.entry)
end

--- Quest bang / border only — UNIT_QUEST_LOG_CHANGED / QUEST_ACCEPTED.
function ItemButton:RefreshQuests()
	local getQuest = C_Container.GetContainerItemQuestInfo
	if not getQuest then
		return
	end
	for _, parent in pairs(slotButtons) do
		local entry = parent.entry
		local button = parent.button
		if entry and button and button.UpdateQuestItem and entry.bag and entry.slot then
			local questInfo = getQuest(entry.bag, entry.slot)
			local quest = questInfo and F.SafeBool(questInfo.isQuestItem)
			entry.quest = quest and true or false
			entry.questID = questInfo and F.SafeNumber(questInfo.questID) or nil
			local active = questInfo and F.SafeBool(questInfo.isActive)
			entry.isActiveQuest = active and true or false
			button:UpdateQuestItem(entry.quest, entry.questID, entry.isActiveQuest)
			if parent._paintSnap then
				parent._paintSnap.quest = entry.quest
				parent._paintSnap.questID = entry.questID
				parent._paintSnap.isActiveQuest = entry.isActiveQuest
			end
		end
	end
end

--- Refresh Blizzard deposit/search context overlay (bank open/close / tab switch).
function ItemButton:RefreshWarbandDim()
	for _, parent in pairs(slotButtons) do
		local button = parent.button
		if button and button.UpdateItemContextMatching then
			button:UpdateItemContextMatching()
		end
	end
end

function ItemButton:OnEnable()
	if self._hooksInstalled then
		return
	end
	self._hooksInstalled = true
	self._eventHandles = self._eventHandles or {}
	local handles = self._eventHandles

	self.pool = self.pool or F.CreatePool(CreateButton, ResetButton)

	-- Pre-warm out of combat (OnEnable runs at PLAYER_LOGIN). Size from the
	-- player's real slot counts so backpack + bank open won't exhaust the pool.
	local prewarm = C.EstimateItemButtonPoolSize and C.EstimateItemButtonPoolSize() or C.Layout.ITEM_BUTTON_POOL_PREWARM or 400
	self.pool:Prewarm(prewarm)
	self:ApplyOverlayLayout()

	local cooldownHandle = F.BucketEvent("BAG_UPDATE_COOLDOWN", 0.2, function()
		local items = ns:GetModule("Items")
		if items and items.AnyWindowOpen and not items:AnyWindowOpen() then
			return
		end
		ItemButton:RefreshCooldowns()
	end)
	if cooldownHandle then
		handles[#handles + 1] = { "BAG_UPDATE_COOLDOWN", cooldownHandle }
	end

	-- Narrow paints — never full Items:Flush / Draw (Baganator Layouts LiveBagOnEvent).
	ns:TrackEvent(handles, "ITEM_LOCK_CHANGED", function(_, bag, slot)
		if bag and slot then
			ItemButton:RefreshLock(bag, slot)
		end
	end)
	ns:TrackEvent(handles, "UNIT_QUEST_LOG_CHANGED", function(_, unit)
		if unit == "player" then
			ItemButton:RefreshQuests()
		end
	end)
	ns:TrackEvent(handles, "QUEST_ACCEPTED", function()
		ItemButton:RefreshQuests()
	end)

	ns:TrackEvent(handles, "PLAYER_REGEN_ENABLED", function()
		if not combatLayoutPending then
			return
		end
		combatLayoutPending = false
		-- Top up the pool while clean so the next in-combat refresh can't run dry.
		if not InCombatLockdown() and ItemButton.pool then
			local prewarm = C.EstimateItemButtonPoolSize and C.EstimateItemButtonPoolSize() or C.Layout.ITEM_BUTTON_POOL_PREWARM or 400
			local have = #ItemButton.pool.objects
			if have < prewarm then
				ItemButton.pool:Prewarm(prewarm - have)
			end
		end
		ns:RefreshBags(false)
	end)

	if EventRegistry then
		EventRegistry:RegisterCallback("BagSlot.OnEnter", function(_, bagSlotButton)
			local backpack = ns:GetModule("Backpack")
			if not (backpack and backpack.frame and backpack.frame:IsShown()) then
				return
			end
			if bagSlotButton and type(bagSlotButton.GetBagID) == "function" then
				local bagID = bagSlotButton:GetBagID()
				if bagID then
					self:SetBagHighlight(bagID, true)
				end
			end
		end, self)
		EventRegistry:RegisterCallback("BagSlot.OnLeave", function(_, bagSlotButton)
			if bagSlotButton and type(bagSlotButton.GetBagID) == "function" then
				local bagID = bagSlotButton:GetBagID()
				if bagID then
					self:SetBagHighlight(bagID, false)
				end
			end
		end, self)
	end
end

function ItemButton:OnDisable()
	if not self._hooksInstalled then
		return
	end
	self._hooksInstalled = false
	self:UninstallDeleteClickHook()
	local organize = ns:GetModule("Organize")
	if organize and organize.SetMode and organize.mode then
		organize:SetMode(nil)
	end
	ns:UnregisterModuleEventHandles(self._eventHandles)
	if EventRegistry and EventRegistry.UnregisterCallback then
		EventRegistry:UnregisterCallback("BagSlot.OnEnter", self)
		EventRegistry:UnregisterCallback("BagSlot.OnLeave", self)
	end
	combatLayoutPending = false
end

function ItemButton:Acquire()
	local pool = self.pool
	if not pool then
		return nil
	end
	-- Reuse pooled buttons in combat; never grow the pool under lockdown.
	if InCombatLockdown() and pool.numFree <= 0 then
		self:FlagCombatLayoutPending()
		return nil
	end
	local obj = pool:Acquire()
	if not obj then
		self:FlagCombatLayoutPending()
	end
	return obj
end

--- Release a single button back to the pool. Each category panel tracks and
--- frees only the buttons it borrowed, so two windows (backpack + bank) can
--- draw from this one shared pool without stomping each other - a global
--- ReleaseAll would yank the other window's buttons out from under it.
function ItemButton:Release(button)
	if self.pool and button then
		self.pool:Release(button)
	end
end

function ItemButton:GetSlotButton(bag, slot)
	return slotButtons[SlotKey(bag, slot)]
end

function ItemButton:RefreshItemID(itemID)
	if not itemID then
		return
	end
	for _, parent in pairs(slotButtons) do
		local entry = parent.entry
		if entry and entry.itemID == itemID then
			parent:SetItemEntry(entry)
		end
	end
end

FindSlotButton = function(bag, slot)
	local button = ItemButton:GetSlotButton(bag, slot)
	if button then
		return button
	end
	for _, parent in pairs(slotButtons) do
		local entry = parent.entry
		local merged = entry and entry._mergedSlots
		if merged then
			for i = 1, #merged do
				local m = merged[i]
				if m.bag == bag and m.slot == slot then
					return parent
				end
			end
		end
	end
	return nil
end

function ItemButton:RefreshSlot(bag, slot)
	local button = FindSlotButton(bag, slot)
	if not (button and button.entry) then
		return false
	end
	local entry = button.entry

	button:SetItemEntry(entry)
	if button.button and F.RefreshBagItemTooltipIfHovered then
		F.RefreshBagItemTooltipIfHovered(button.button)
	end
	return true
end

function ItemButton:ReleaseAll()
	if self.pool then
		self.pool:ReleaseAll()
	end
end

local CORNER_ANCHORS = {
	topleft = { "TOPLEFT", "TOPLEFT", 1, -1 },
	topright = { "TOPRIGHT", "TOPRIGHT", -1, -1 },
	bottomleft = { "BOTTOMLEFT", "BOTTOMLEFT", 1, 1 },
	bottomright = { "BOTTOMRIGHT", "BOTTOMRIGHT", -1, 1 },
	top = { "TOP", "TOP", 0, 2 },
	bottom = { "BOTTOM", "BOTTOM", 0, -2 },
	left = { "LEFT", "LEFT", 2, 0 },
	right = { "RIGHT", "RIGHT", -2, 0 },
	center = { "CENTER", "CENTER", 0, 0 },
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
