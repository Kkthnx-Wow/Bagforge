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

-- `entry` is one slot record from Items:GetSlots().
local function Button_SetItem(self, entry)
	local key = SlotKey(entry.bag, entry.slot)
	if self.slotKey ~= key then
		UnregisterSlot(self)
		self.slotKey = key
	end
	self.entry = entry
	slotButtons[key] = self

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
	-- Bag stack counts are readable in Midnight, but guard anyway - it's cheap
	-- and SetItemButtonCount does a comparison internally that a secret would
	-- choke on.
	SetItemButtonCount(self.button, F.NotSecret(entry.count) and entry.count or 1)
	-- Stock quality ring (suppressOverlays = false) - Blizzard's default look.
	if F.NotSecret(entry.quality) then
		SetItemButtonQuality(self.button, entry.quality, entry.hyperlink, false, entry.isBound)
	end
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

	ApplyUnusableTint(self, entry)

	if ns.API and ns.API._FireItemButtonCallbacks then
		ns.API:_FireItemButtonCallbacks(self.button, entry.bag, entry.slot, entry)
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
		if entry and F.NotSecret(entry.itemID) and entry.itemID == itemID and parent:IsShown() then
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

	local button = CreateFrame("ItemButton", name, parent, "ContainerFrameItemButtonTemplate")
	button:SetAllPoints(parent)
	button:RegisterForDrag("LeftButton")
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
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
	end
	parent:ClearItem()
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

function ItemButton:OnEnable()
	self.pool = F.CreatePool(CreateButton, ResetButton)

	-- Pre-warm out of combat (OnEnable runs at PLAYER_LOGIN). Size from the
	-- player's real slot counts so backpack + bank open won't exhaust the pool.
	local prewarm = C.EstimateItemButtonPoolSize and C.EstimateItemButtonPoolSize() or C.Layout.ITEM_BUTTON_POOL_PREWARM or 400
	self.pool:Prewarm(prewarm)
	self:ApplyOverlayLayout()

	F.BucketEvent("BAG_UPDATE_COOLDOWN", 0.2, function()
		local items = ns:GetModule("Items")
		if items and items.AnyWindowOpen and not items:AnyWindowOpen() then
			return
		end
		ItemButton:RefreshCooldowns()
	end)

	ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
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
		if entry and F.NotSecret(entry.itemID) and entry.itemID == itemID then
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
	if not (info and info.itemID and F.NotSecret(info.itemID)) then
		return false
	end

	entry.isLocked = info.isLocked and true or false
	button:SetItemEntry(entry)
	if button.button and F.RefreshBagItemTooltipIfHovered then
		F.RefreshBagItemTooltipIfHovered(button.button)
	end
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
