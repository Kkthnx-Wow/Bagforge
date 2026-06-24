--[[
	Bagforge - Container (per-category panel)
	-------------------------------------------------------------------------
	A "container" is one bordered panel that shows a single category: a header
	label on top and a grid of item buttons below. This is the cargBags idea
	(NDui ships a derivative): specialty filters get their own panels stacked
	above the main "Bag" panel, which owns the search bar, money and controls.

	A Container is a plain Lua object (not a frame) wrapping a backdrop frame, so
	it pools cleanly through F.CreatePool: the pool's reclaim only auto-hides
	objects that are themselves frames, and our Reset() handles the inner frame
	and hands every borrowed item button back to the shared ItemButton pool.

	Buttons are borrowed from the *shared* ItemButton pool and released
	individually (never a global ReleaseAll), so a backpack panel and a bank
	panel can both be on screen at once without fighting over the pool.
--]]

local _, ns = ...
local C, F, L = ns.C, ns.F, ns.L

local CreateFrame = CreateFrame
local C_AddOns = C_AddOns
local C_Container = C_Container
local C_Item = C_Item
local InCombatLockdown = InCombatLockdown
local CursorHasItem = CursorHasItem
local ClearCursor = ClearCursor
local GetCursorInfo = GetCursorInfo
local GetItemInfoInstant = C_Item.GetItemInfoInstant
local ipairs = ipairs
local pcall = pcall
local wipe = wipe
local type = type
local format = string.format
local tonumber = tonumber
local ceil, max, min, floor = math.ceil, math.max, math.min, math.floor

local SetItemButtonCount = SetItemButtonCount
local GameTooltip = GameTooltip
local GameTooltip_SetTitle = _G["GameTooltip_SetTitle"]
local GameTooltip_AddNormalLine = _G["GameTooltip_AddNormalLine"]
local GameTooltip_Hide = _G["GameTooltip_Hide"]
local HIGHLIGHT_FONT_COLOR = _G["HIGHLIGHT_FONT_COLOR"]
local NORMAL_FONT_COLOR = _G["NORMAL_FONT_COLOR"]

local Container = {}
ns.Container = Container

local SETTINGS_SHARED = "Blizzard_Settings_Shared"
local UIPANELS_GAME = "Blizzard_UIPanels_Game"
local BagIndex = Enum.BagIndex
local IsAccountSecured = IsAccountSecured

local extendedTemplatesReady = false
local extendedSlotsTestOverride = false

local function EnsureSettingsTemplate()
	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.LoadAddOn and not C_AddOns.IsAddOnLoaded(SETTINGS_SHARED) then
		pcall(C_AddOns.LoadAddOn, SETTINGS_SHARED)
	end
end

--- Blizzard's combined-bags backpack shows four padlocked slots (and a green "+"
--- button) when the account is not Battle.net Authenticator–secured. Mirrors
--- ContainerFrame_GetContainerNumSlots / ContainerFrameExtendedSlotPack.
local function EnsureExtendedSlotTemplates()
	if extendedTemplatesReady then
		return true
	end
	EnsureSettingsTemplate()
	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.LoadAddOn and not C_AddOns.IsAddOnLoaded(UIPANELS_GAME) then
		pcall(C_AddOns.LoadAddOn, UIPANELS_GAME)
	end
	local probe = CreateFrame("Frame", nil, UIParent, "ContainerFrameExtendedItemButtonTemplate")
	if probe then
		probe:Hide()
		probe:SetParent(nil)
		extendedTemplatesReady = true
	end
	return extendedTemplatesReady
end

local function GetBackpackExtendedSlotCount()
	if extendedSlotsTestOverride then
		return 4
	end
	if not IsAccountSecured or IsAccountSecured() then
		return 0
	end
	if not BagIndex or not C_Container or not C_Container.GetContainerNumSlots then
		return 0
	end
	local current = C_Container.GetContainerNumSlots(BagIndex.Backpack) or 0
	return max(0, (current + 4) - current)
end

local function HideBackpackExtendedSlots(container)
	if container.extendedSlots then
		for i = 1, #container.extendedSlots do
			container.extendedSlots[i]:Hide()
		end
	end
	if container.addSlotsButton then
		container.addSlotsButton:Hide()
	end
end

--- Padlocked authenticator slots trail the free-slot box on the main bag grid.
local function LayoutBackpackExtendedSlots(container, cellIndex, columns, size, pad, leftX, topOffset)
	if not container.isMain then
		return cellIndex
	end

	local extCount = GetBackpackExtendedSlotCount()
	if extCount <= 0 or not EnsureExtendedSlotTemplates() then
		HideBackpackExtendedSlots(container)
		return cellIndex
	end

	container.extendedSlots = container.extendedSlots or {}

	local freeShown = container.freeSlot and container.freeSlot:IsShown()
	local skipCell = 0
	if freeShown and cellIndex > 0 then
		local prevCol = (cellIndex - 1) % columns
		local thisCol = cellIndex % columns
		local prevRow = floor((cellIndex - 1) / columns)
		local thisRow = floor(cellIndex / columns)
		-- Free slot and padlocks share a row: reserve one grid cell for the + button.
		if thisRow == prevRow and thisCol > prevCol then
			skipCell = 1
		end
	end

	local startCell = cellIndex

	for i = 1, extCount do
		local gridIndex = startCell + skipCell + (i - 1)
		local slot = container.extendedSlots[i]
		if not slot then
			slot = CreateFrame("Frame", nil, container.frame)
			local slotBG = slot:CreateTexture(nil, "BACKGROUND", "ItemSlotBackgroundCombinedBagsTemplate", -6)
			slotBG:SetAllPoints(slot)
			local lock = CreateFrame("Frame", nil, slot, "ContainerFrameExtendedItemButtonTemplate")
			lock:SetAllPoints(slot)
			container.extendedSlots[i] = slot
		end
		slot:SetSize(size, size)
		local col = gridIndex % columns
		local row = floor(gridIndex / columns)
		slot:ClearAllPoints()
		slot:SetPoint("TOPLEFT", container.frame, "TOPLEFT", leftX + col * (size + pad), -(topOffset + row * (size + pad)))
		slot:Show()
	end

	for i = extCount + 1, #container.extendedSlots do
		container.extendedSlots[i]:Hide()
	end

	if not container.addSlotsButton then
		container.addSlotsButton = CreateFrame("Button", nil, container.frame, "AddExtendedSlotsButtonTemplate")
	end
	local first = container.extendedSlots[1]
	if first then
		container.addSlotsButton:ClearAllPoints()
		if skipCell > 0 then
			local col = startCell % columns
			local row = floor(startCell / columns)
			container.addSlotsButton:SetPoint("CENTER", container.frame, "TOPLEFT", leftX + col * (size + pad) + size * 0.5, -(topOffset + row * (size + pad) + size * 0.5))
		else
			container.addSlotsButton:SetPoint("LEFT", first, "LEFT", -14, -2)
		end
		container.addSlotsButton:Show()
	end

	return startCell + skipCell + extCount
end

--- Drop the item on the cursor into the first empty slot of this panel's bags
--- (set via SetFreeSlotDeposit). Lets the free-slot box act like a real empty
--- slot you can drop onto, the same way Blizzard's trailing empty slot does.
local function FreeSlot_Deposit(free)
	if not CursorHasItem() then
		return
	end
	if InCombatLockdown() then
		if UIErrorsFrame and ERR_NOT_IN_COMBAT then
			UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, 1, 0.3, 0.3)
		end
		return
	end
	local getBags = free.depositBagsFn
	local bags = getBags and getBags()
	if not bags then
		return
	end
	for _, bag in ipairs(bags) do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if not (info and info.itemID) then
				C_Container.PickupContainerItem(bag, slot)
				return
			end
		end
	end
end

--- Tooltip for the free-slot box: a plain "Free Slots" header, the count and a
--- hint that it accepts drops, so it reads like a real (empty) bag slot.
local function FreeSlot_OnEnter(free)
	if not GameTooltip then
		return
	end
	GameTooltip:SetOwner(free, "ANCHOR_RIGHT")
	if GameTooltip_SetTitle then
		GameTooltip_SetTitle(GameTooltip, L["Free Slots"], HIGHLIGHT_FONT_COLOR)
	end
	if GameTooltip_AddNormalLine then
		local n = free.freeNum or tonumber(free.count:GetText()) or 0
		GameTooltip_AddNormalLine(GameTooltip, format(L["%d empty"], n))
		GameTooltip_AddNormalLine(GameTooltip, L["Click, or drop an item here, to use the next empty slot."])
	end
	GameTooltip:Show()
end

local function FreeSlot_OnLeave()
	if GameTooltip_Hide then
		GameTooltip_Hide()
	end
end

local freeSlotCount = 0
local ERR_NOT_IN_COMBAT = _G["ERR_NOT_IN_COMBAT"]
local UIErrorsFrame = _G["UIErrorsFrame"]

local function AddFreeSlot(container)
	-- Bare ItemButton intrinsic: same base slot frame, but without the container
	-- template's new-item/context glow and tooltip OnUpdate. For the recessed fill,
	-- use Blizzard's combined-bag slot background template (same pattern as
	-- Bagforge's bag-bar slots) instead of SetItemButtonTexture; the intrinsic icon
	-- region is what was pinning the background small in the top-left.
	freeSlotCount = freeSlotCount + 1
	local free = CreateFrame("ItemButton", "BagforgeFreeSlot" .. freeSlotCount, container.frame)
	free:SetSize(C.Layout.ITEM_SIZE, C.Layout.ITEM_SIZE)
	free:Hide()

	local slotBG = free:CreateTexture(nil, "BACKGROUND", "ItemSlotBackgroundCombinedBagsTemplate", -6)
	slotBG:SetAllPoints(free)
	slotBG:Show()
	free.slotBG = slotBG

	if SetItemButtonCount then
		SetItemButtonCount(free, 0)
	end

	-- Big centered free-slot count (the template's own count sits bottom-right and
	-- stays blank).
	local freeCount = F.CreateFS(free, 14, "", "OVERLAY")
	freeCount:SetPoint("CENTER", free, "CENTER", 0, 0)
	freeCount:SetTextColor(1, 1, 1)
	free.count = freeCount

	free:RegisterForDrag("LeftButton")
	free:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	free:SetScript("OnReceiveDrag", FreeSlot_Deposit)
	free:SetScript("OnClick", FreeSlot_Deposit)
	free:SetScript("OnEnter", FreeSlot_OnEnter)
	free:SetScript("OnLeave", FreeSlot_OnLeave)

	container.freeSlot = free
end

-- Instance methods live on one shared metatable so a pool of dozens of panels
-- doesn't duplicate closures per panel.
local methods = {}
methods.__index = methods

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

--- Build a new specialty panel parented to `parent`. `name` is optional and only
--- set for the main panel (it needs a global name for UISpecialFrames/keybinds).
--- Close buttons are opt-in: category panels hide the SettingsFrameTemplate
--- close button, while the main bag panel keeps it.
--- Use a Container pool (see Backpack) rather than calling this directly.
function Container.New(parent, name, showClose)
	EnsureSettingsTemplate()

	-- SettingsFrameTemplate is Blizzard's settings-panel shell:
	-- FlatPanelBackgroundTemplate + ButtonFrameTemplateNoPortrait NineSlice +
	-- UIPanel close button. The frame style lives here so every category can
	-- switch templates from one place later.
	local frame = CreateFrame("Frame", name, parent, "SettingsFrameTemplate")
	frame:Hide()

	-- Use the template's own title FontString (GameFontNormal = Blizzard yellow);
	-- no colour override, so it matches the default UI.
	local header = frame.NineSlice and frame.NineSlice.Text or F.CreateFS(frame, 12, "", "OVERLAY")
	header:SetJustifyH("CENTER")

	if frame.ClosePanelButton then
		frame.ClosePanelButton:SetShown(showClose and true or false)
	end

	return setmetatable({
		frame = frame,
		header = header,
		buttons = {},
	}, methods)
end

--- Main "Bag" panel (cargBags anchor). Title shows when Layout gets
--- `showMainTitle`; it owns the "free slot" box - a fake empty slot that shows
--- the free-slot count and trails the last item, exactly like cargBags' [space].
function Container.NewMain(parent)
	local container = Container.New(parent, "BagforgeBackpackFrame", true)
	container.isMain = true
	container.header:Hide() -- shown by Layout when showMainTitle is set
	AddFreeSlot(container)

	return container
end

function Container.AddFreeSlot(container)
	if not container.freeSlot then
		AddFreeSlot(container)
	end
end

--- Tell the free-slot box which bags to deposit a dropped item into. `fn` returns
--- an array of bag IDs (a function so dynamic sets - like the bank's purchased
--- tabs - resolve at drop time).
function methods:SetFreeSlotDeposit(fn)
	if self.freeSlot then
		self.freeSlot.depositBagsFn = fn
	end
end

-- ---------------------------------------------------------------------------
-- Layout
--   Place the header and one item button per entry. Specialty panels shrink to
--   their item count (capped at `columns`) unless `forceWidth` is set; the main
--   panel passes forceWidth so it spans the full grid. `opts.topInset` and
--   `opts.bottomInset` reserve space for the main panel's chrome row and footer.
--   Returns width and height.
-- ---------------------------------------------------------------------------

-- Content signature: skip the (expensive) button rebuild when nothing that
-- affects this panel's contents or geometry changed since the last draw. Built
-- from every per-item display field (including bag/slot so a moved item always
-- relayouts and never points a button at the wrong slot), the layout opts, and a
-- global display epoch that the display-only toggles bump (item level / bind
-- labels / unusable tint / Pawn arrows) so those still force a repaint.
local function FoldHash(h, v)
	-- Lua 5.1 numbers are doubles; keep the fold in a stable integer range.
	return (h * 31 + (v or 0)) % 2147483647
end

-- Bag APIs are usually non-secret, but guard anyway so signature hashing never
-- throws during combat or in instances (Midnight secret model).
local function SafeFold(h, v)
	if v ~= nil and type(v) == "number" and F.IsSecret(v) then
		return FoldHash(h, -1)
	end
	return FoldHash(h, v)
end

-- Category names are a small, stable set, so fold each one to a number once and
-- reuse it instead of re-hashing the string on every panel signature.
local nameHashCache = {}
local function NameHash(name)
	if not name then
		return 0
	end
	local h = nameHashCache[name]
	if not h then
		h = 0
		for i = 1, #name do
			h = FoldHash(h, name:byte(i))
		end
		nameHashCache[name] = h
	end
	return h
end

local function SectionSignature(section, columns, opts, showHeader)
	local h = FoldHash(0, ns.DrawEpoch or 0)
	h = FoldHash(h, NameHash(section and section.name))
	h = FoldHash(h, columns)
	h = FoldHash(h, opts.forceWidth or -1)
	h = FoldHash(h, opts.topInset or 0)
	h = FoldHash(h, opts.bottomInset or 0)
	h = FoldHash(h, showHeader and 1 or 0)
	h = FoldHash(h, opts.freeCount == nil and -1 or opts.freeCount)
	if opts.freeCount ~= nil then
		h = FoldHash(h, GetBackpackExtendedSlotCount())
	end
	local hideSearch = ns.db and ns.db.organize and ns.db.organize.searchHideNonMatches
	h = FoldHash(h, hideSearch and 1 or 0)
	local items = section and section.items
	if items then
		for i = 1, #items do
			local e = items[i]
			h = FoldHash(h, e.key)
			h = SafeFold(h, e.itemID)
			h = SafeFold(h, e.count)
			h = SafeFold(h, e.quality)
			h = FoldHash(h, e.isFiltered and 1 or 0)
			h = FoldHash(h, e.isLocked and 1 or 0)
			h = FoldHash(h, e.isNewItem and 1 or 0)
			h = FoldHash(h, e.isBound and 1 or 0)
			h = SafeFold(h, e.icon)
			if e.bindLabel and F.CanAccessValue(e.bindLabel) then
				for j = 1, #e.bindLabel do
					h = FoldHash(h, e.bindLabel:byte(j))
				end
			end
			h = SafeFold(h, e.ilvl)
		end
	end
	return h
end

local layoutVisibleScratch = {}

--- When search-hide is on, drop non-matching entries from the layout grid.
local function LayoutEntries(entries, hideNonMatches)
	local total = #entries
	if not hideNonMatches or total == 0 then
		return entries, total
	end
	local anyFiltered = false
	for i = 1, total do
		if entries[i].isFiltered then
			anyFiltered = true
			break
		end
	end
	if not anyFiltered then
		return entries, total
	end
	wipe(layoutVisibleScratch)
	local n = 0
	for i = 1, total do
		local e = entries[i]
		if not e.isFiltered then
			n = n + 1
			layoutVisibleScratch[n] = e
		end
	end
	return layoutVisibleScratch, n
end

function methods:Layout(section, columns, opts)
	opts = opts or {}

	local showHeader = opts.showHeader ~= false and (not self.isMain or opts.showMainTitle)

	-- Unchanged since last draw: keep the existing buttons exactly as they are and
	-- just re-show the frame. The caller (StackCategories) still re-anchors panels,
	-- which is cheap; this only avoids releasing/re-acquiring/repainting buttons.
	local sig = SectionSignature(section, columns, opts, showHeader)
	if self._sig == sig and self._lastW then
		self.frame:Show()
		return self._lastW, self._lastH
	end
	self._sig = sig

	if showHeader then
		local name = section and section.name
		self.header:SetText(name or "")
		-- Custom header tint (Modules/Organize): a custom/search category can
		-- carry a colour; group-by sub-panels ("<name>: <suffix>") inherit the
		-- parent's. Falls back to the template's default yellow.
		local o = ns.db and ns.db.organize
		local color = o and o.colors and name and o.colors[name]
		if not color and name and o and o.colors then
			local base = name:match("^(.-): ")
			color = base and o.colors[base]
		end
		if color then
			self.header:SetTextColor(color[1], color[2], color[3])
		elseif NORMAL_FONT_COLOR then
			self.header:SetTextColor(NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
		else
			self.header:SetTextColor(1, 0.82, 0)
		end
		self.header:Show()
	else
		self.header:SetText("")
		self.header:Hide()
	end

	local itemButton = ns:GetModule("ItemButton")
	local entries = section and section.items or {}
	local hideNonMatches = ns.db and ns.db.organize and ns.db.organize.searchHideNonMatches
	local displayEntries, count = LayoutEntries(entries, hideNonMatches)
	local size, pad = C.Layout.ITEM_SIZE, C.Layout.ITEM_PADDING
	local insetX = C.Layout.PANEL_PADDING_X
	local leftX = insetX + C.Layout.PANEL_BIAS_X -- grid shifted right to balance the border
	local insetY = C.Layout.PANEL_PADDING
	local headerH = showHeader and C.Layout.PANEL_HEADER_HEIGHT or 0
	local topInset = opts.topInset or 0
	local bottomInset = opts.bottomInset or 0
	local topOffset = insetY + headerH + topInset

	-- Reuse the buttons this panel already holds and only repaint them; acquire
	-- just the growth and release just the shrink. Releasing/re-acquiring the
	-- whole section every redraw (cargBags/NDui repaint per button) churns the
	-- shared pool and re-parents needlessly when one stack count ticked.
	for i = 1, count do
		local button = self.buttons[i]
		if not button then
			button = itemButton:Acquire()
			button:SetParent(self.frame)
			self.buttons[i] = button
		end

		local col = (i - 1) % columns
		local row = floor((i - 1) / columns)
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", self.frame, "TOPLEFT", leftX + col * (size + pad), -(topOffset + row * (size + pad)))
		button:SetItemEntry(displayEntries[i])
	end

	-- Hand back any buttons beyond the new count (section shrank).
	for i = #self.buttons, count + 1, -1 do
		itemButton:Release(self.buttons[i])
		self.buttons[i] = nil
	end

	-- The free-slot box (main panel only) trails the last item as cell #count+1,
	-- so it flows with the grid and wraps to the next row when the bag is full.
	local cells = count
	if self.freeSlot then
		if opts.freeCount ~= nil then
			local col = count % columns
			local row = floor(count / columns)
			self.freeSlot:ClearAllPoints()
			self.freeSlot:SetPoint("TOPLEFT", self.frame, "TOPLEFT", leftX + col * (size + pad), -(topOffset + row * (size + pad)))
			self.freeSlot.count:SetText(opts.freeCount)
			self.freeSlot.freeNum = opts.freeCount
			self.freeSlot:Show()
			cells = count + 1
		else
			self.freeSlot:Hide()
		end
	end

	cells = LayoutBackpackExtendedSlots(self, cells, columns, size, pad, leftX, topOffset)

	local rows = max(ceil(cells / columns), 1)
	local width
	if opts.forceWidth then
		width = opts.forceWidth
	else
		local gridCols = min(columns, max(count, 1))
		width = insetX * 2 + gridCols * size + (gridCols - 1) * pad
	end
	local height = insetY * 2 + headerH + topInset + bottomInset + rows * size + (rows - 1) * pad

	self.frame:SetSize(width, height)
	self.frame:Show()

	self._lastW, self._lastH = width, height
	return width, height
end

function methods:GetFrame()
	return self.frame
end

-- ---------------------------------------------------------------------------
-- Shared grid geometry / masonry stacking
--   These are window-agnostic so the backpack and every bank view share one
--   implementation of the cargBags layout instead of copy-pasting it.
-- ---------------------------------------------------------------------------

--- Pixel width of a `columns`-wide item grid including the panel insets. Used to
--- force every panel in a window to the same width.
function Container.GridWidth(columns)
	local size, pad = C.Layout.ITEM_SIZE, C.Layout.ITEM_PADDING
	local insetX = C.Layout.PANEL_PADDING_X
	return insetX * 2 + columns * size + (columns - 1) * pad
end

--- Drop (or click-drop) the cursor item onto a category panel to assign it to
--- that category (Modules/Organize). Panels are plain non-secure frames, so this
--- can't taint; the item returns to its slot via ClearCursor and the assignment
--- triggers a reclassify/redraw. Built-in panels work too (it pins the item
--- there). The main "Bag" panel is excluded by StackCategories, so dropping
--- there is a no-op - unassign via /bf cat remove.
function Container.OnCategoryDrop(container)
	if not CursorHasItem() then
		return
	end
	local infoType, a, b = GetCursorInfo()
	if infoType ~= "item" then
		return
	end
	local itemID = (type(a) == "number" and a) or (b and GetItemInfoInstant(b))
	local organize = ns:GetModule("Organize")
	if itemID and organize and container.categoryName then
		if organize:AssignItem(itemID, container.categoryName) then
			ClearCursor()
		end
	end
end

local function EnableCategoryDrop(container)
	if container._dropSetup then
		return
	end
	local frame = container.frame
	frame:EnableMouse(true)
	local function drop()
		Container.OnCategoryDrop(container)
	end
	local function onMouseUp(_, button)
		if button == "RightButton" and not CursorHasItem() then
			local organize = ns:GetModule("Organize")
			if organize and organize.OpenCategoryOrderMenu then
				organize:OpenCategoryOrderMenu(frame, container.categoryName, container._orderOwner)
			end
			return
		end
		drop()
	end
	frame:SetScript("OnReceiveDrag", drop)
	frame:SetScript("OnMouseUp", onMouseUp)
	container._dropSetup = true
end

--- cargBags masonry: stack the category panels upward from the already-sized
--- main panel, wrapping into a new column to the left once a column holds
--- `perColumn` panels. The main panel stays put at its anchor.
---
--- opts fields:
---   sections    - the scanner's section list (array of { name, items })
---   mainName    - category that lives in the main panel (skipped here)
---   mainFrame   - the anchored root frame the first column sits above
---   columns     - item columns per panel
---   gridWidth   - forced panel width (Container.GridWidth)
---   perColumn   - category panels per column before wrapping left (default 5)
---   freeSlots   - optional map [name] = { count, getBags } giving a panel its own
---                 free-slot box; such panels render even when they hold no items
---   owner       - view/backpack instance; used with GetCategoryContainer
---   active      - table marked active[name]=true for each drawn panel
function Container.StackCategories(opts)
	local sections = opts.sections
	local mainName = opts.mainName
	local mainFrame = opts.mainFrame
	local cols = opts.columns
	local gridW = opts.gridWidth
	local owner = opts.owner
	local active = opts.active
	local visibleOrder = owner and owner.visibleCategoryOrder
	local freeSlots = opts.freeSlots
	local gap = C.Layout.PANEL_GAP

	local perColumn = opts.perColumn or C.Layout.DEFAULT_CATEGORIES_PER_COLUMN
	if perColumn < 1 then
		perColumn = 1
	end

	local colWrapRef = mainFrame -- next column bottom-aligns to this frame
	local colFirstCat -- first (bottom) panel in the current column
	local prevInCol -- previous panel in the current column (stack upward)
	local countInCol = 0 -- panels placed in the current column so far

	for i = 1, #sections do
		local section = sections[i]
		local freeInfo = freeSlots and freeSlots[section.name]
		if section.name ~= mainName and (#section.items > 0 or freeInfo) then
			active[section.name] = true
			if visibleOrder then
				visibleOrder[#visibleOrder + 1] = section.name
			end
			local container = owner:GetCategoryContainer(section.name)
			container.categoryName = section.name
			container._orderOwner = owner
			EnableCategoryDrop(container)
			if freeInfo then
				Container.AddFreeSlot(container)
				container:SetFreeSlotDeposit(freeInfo.getBags)
				container:Layout(section, cols, { forceWidth = gridW, freeCount = freeInfo.count })
			else
				container:Layout(section, cols, { forceWidth = gridW })
			end
			local panel = container:GetFrame()
			panel:ClearAllPoints()

			if colFirstCat and countInCol >= perColumn then
				-- New column to the left, bottom-aligned to the previous column.
				-- The horizontal seam reads wider than the vertical PANEL_GAP, so
				-- pull wrapped columns tighter toward the main frame.
				panel:SetPoint("BOTTOMRIGHT", colWrapRef, "BOTTOMLEFT", -(gap - 2), 0)
				colWrapRef = panel
				colFirstCat = panel
				prevInCol = panel
				countInCol = 1
			else
				if not colFirstCat then
					panel:SetPoint("BOTTOMLEFT", mainFrame, "TOPLEFT", 0, gap)
					colFirstCat = panel
				else
					panel:SetPoint("BOTTOMLEFT", prevInCol, "TOPLEFT", 0, gap)
				end
				prevInCol = panel
				countInCol = countInCol + 1
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Recycling
-- ---------------------------------------------------------------------------

function methods:ReleaseButtons()
	local itemButton = ns:GetModule("ItemButton")
	if not itemButton then
		return
	end
	for i = #self.buttons, 1, -1 do
		itemButton:Release(self.buttons[i])
		self.buttons[i] = nil
	end
end

function methods:Reset()
	self:ReleaseButtons()
	self.header:SetText("")
	self.frame:ClearAllPoints()
	self.frame:Hide()
	self._orderOwner = nil
	-- Invalidate the layout cache so the next Layout rebuilds from scratch
	-- (this panel may be reused for a different category).
	self._sig = nil
	self._lastW = nil
	self._lastH = nil
end

function Container.CreatePool(parent)
	return F.CreatePool(function()
		return Container.New(parent)
	end, function(container)
		container:Reset()
	end)
end

--- Dev preview: force the four authenticator padlock slots (+ green button) on the
--- main bag even when the account is already secured. `/bf testextslots`.
function Container.GetExtendedSlotsTestOverride()
	return extendedSlotsTestOverride
end

function Container.SetExtendedSlotsTestOverride(enable)
	local want = enable and true or false
	if extendedSlotsTestOverride == want then
		return extendedSlotsTestOverride
	end
	extendedSlotsTestOverride = want
	ns.DrawEpoch = (ns.DrawEpoch or 0) + 1
	local backpack = ns:GetModule("Backpack")
	if backpack then
		if want then
			backpack:Open()
		elseif backpack.IsShown and backpack:IsShown() then
			backpack:Draw()
		end
	end
	return extendedSlotsTestOverride
end
