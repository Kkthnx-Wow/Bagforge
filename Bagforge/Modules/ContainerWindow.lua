--[[
	Bagforge - ContainerWindow (shared categorized-window base)
	-------------------------------------------------------------------------
	Chrome geometry, category-container bookkeeping, drag persistence, and the
	shared DrawCategorized masonry path used by the backpack and every bank view.
	Call ns.ContainerWindow.Apply(target) once to mix these methods onto a module
	or view prototype table.
--]]

local _, ns = ...
local C, F = ns.C, ns.F

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local ipairs = ipairs
local max = math.max
local pairs = pairs
local wipe = wipe
local UIParent = UIParent

local ContainerWindow = {}
ns.ContainerWindow = ContainerWindow

local emptyItems = {}

--- Mix shared window methods onto `target` (Backpack module or Bank View proto).
function ContainerWindow.Apply(target)
	target.GetCategoryContainer = ContainerWindow.GetCategoryContainer
	target.HideInactiveCategoryContainers = ContainerWindow.HideInactiveCategoryContainers
	target.InitCategoryContainers = ContainerWindow.InitCategoryContainers
	target.ApplyFrameChrome = ContainerWindow.ApplyFrameChrome
	target.SetupDragPersistence = ContainerWindow.SetupDragPersistence
	target.SetItemGridsHidden = ContainerWindow.SetItemGridsHidden
	target.InvalidateItemLayouts = ContainerWindow.InvalidateItemLayouts
	target.RelayoutAfterDrag = ContainerWindow.RelayoutAfterDrag
	target.ApplySavedPosition = ContainerWindow.ApplySavedPosition
	target.GetChromeInsets = ContainerWindow.GetChromeInsets
	target.CreateSearchBox = ContainerWindow.CreateSearchBox
	target.SetSearchReserve = ContainerWindow.SetSearchReserve
	target.CheckCombatDraw = ContainerWindow.CheckCombatDraw
	target.DrawCategorized = ContainerWindow.DrawCategorized
	target.FindMainSection = ContainerWindow.FindMainSection
end

function ContainerWindow.GetChromeBandTop()
	local L = C.Layout
	return -(L.PANEL_PADDING + L.PANEL_HEADER_HEIGHT + L.MAIN_CHROME_TITLE_GAP - L.MAIN_CHROME_ROW_LIFT)
end

function ContainerWindow.GetChromeSearchY()
	return ContainerWindow.GetChromeBandTop() + C.Layout.MAIN_CHROME_SEARCH_OFFSET
end

function ContainerWindow.GetChromeInsets()
	local L = C.Layout
	local leftX = L.PANEL_PADDING_X + L.PANEL_BIAS_X
	local rightX = L.PANEL_PADDING_X - L.PANEL_BIAS_X
	local btnW = 20
	local btnGap = 4
	local searchY = ContainerWindow.GetChromeSearchY()
	-- Bottom-align 20px icon buttons with the 24px search box; MAIN_CHROME_BTN_OFFSET nudges up.
	local btnY = searchY - L.MAIN_CHROME_ROW_HEIGHT + btnW + (L.MAIN_CHROME_BTN_OFFSET or 0)
	return leftX, rightX, btnY, btnW, btnGap
end

function ContainerWindow.InitCategoryContainers(self)
	self.categoryContainers = self.categoryContainers or {}
	self.activeCategories = self.activeCategories or {}
	self.visibleCategoryOrder = self.visibleCategoryOrder or {}
end

function ContainerWindow:GetCategoryContainer(name)
	local containers = self.categoryContainers
	local container = containers[name]
	if not container then
		container = ns.Container.New(self.frame)
		containers[name] = container
	end
	return container
end

function ContainerWindow:HideInactiveCategoryContainers()
	local active = self.activeCategories
	for name, container in pairs(self.categoryContainers) do
		if not active[name] then
			container:Reset()
		end
	end
end

function ContainerWindow:ApplyFrameChrome(frame)
	frame:SetFrameStrata("HIGH")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
end

function ContainerWindow:SetupDragPersistence(frame, setPos)
	local owner = self
	frame:SetScript("OnDragStart", function(f)
		if F.HideActiveBagTooltip then
			F.HideActiveBagTooltip()
		end
		owner:SetItemGridsHidden(true)
		f:StartMoving()
	end)
	frame:SetScript("OnDragStop", function(f)
		f:StopMovingOrSizing()
		owner:SetItemGridsHidden(false)
		owner:InvalidateItemLayouts()
		owner:RelayoutAfterDrag()
		local point, _, relPoint, x, y = f:GetPoint(1)
		setPos({ point = point, relPoint = relPoint, x = x, y = y })
	end)
end

function ContainerWindow:SetItemGridsHidden(hidden)
	if self.mainContainer and self.mainContainer.SetItemGridsHidden then
		self.mainContainer:SetItemGridsHidden(hidden)
	end
	local containers = self.categoryContainers
	if containers then
		for _, container in pairs(containers) do
			container:SetItemGridsHidden(hidden)
		end
	end
end

function ContainerWindow:InvalidateItemLayouts()
	if self.mainContainer then
		self.mainContainer._sig = nil
		self.mainContainer._lastW = nil
		self.mainContainer._lastH = nil
	end
	local containers = self.categoryContainers
	if containers then
		for _, container in pairs(containers) do
			container._sig = nil
			container._lastW = nil
			container._lastH = nil
		end
	end
end

function ContainerWindow:RelayoutAfterDrag()
	if self.open == false then
		return
	end
	if self.frame and self.frame:IsShown() and self.Draw then
		self:Draw()
	end
end

function ContainerWindow:ApplySavedPosition(pos, defaultPoint, defaultRelPoint, defaultX, defaultY)
	local frame = self.frame
	frame:ClearAllPoints()
	if pos then
		frame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
	else
		frame:SetPoint(defaultPoint or "BOTTOMRIGHT", UIParent, defaultRelPoint or "BOTTOMRIGHT", defaultX or -40, defaultY or 120)
	end
end

-- Right-hand inset that keeps `rightButtonCount` square chrome buttons clear of
-- the search field. Shared by CreateSearchBox and SetSearchReserve so the two
-- always agree.
local function SearchReserve(rightX, btnW, btnGap, rightButtonCount)
	return rightX + btnW * rightButtonCount + btnGap * max(rightButtonCount - 1, 0) + 6
end

-- SearchBoxTemplate border art is authored at 20px in InputBoxVisualTemplate; the
-- edit box frame can be taller but the chrome won't grow unless we stretch it.
local function SearchBoxHeight()
	return C.Layout.MAIN_CHROME_ROW_HEIGHT
end

local function ApplySearchBoxHeight(search, height)
	search:SetHeight(height)
	local left, right, middle = search.Left, search.Right, search.Middle
	if left and right and middle then
		left:SetHeight(height)
		right:SetHeight(height)
		middle:SetHeight(height)
	end
end

--- `rightButtonCount` = how many icon buttons sit on the search row's right end.
function ContainerWindow:CreateSearchBox(rightButtonCount)
	local frame = self.frame
	local leftX, rightX, _, btnW, btnGap = ContainerWindow.GetChromeInsets()
	local reserve = SearchReserve(rightX, btnW, btnGap, rightButtonCount)
	-- BagSearchBoxTemplate inherits SearchBoxTemplate's look (same chrome as
	-- Baganator's box) but, unlike the bare template, natively drives Blizzard's
	-- bag search: it calls C_Container.SetItemSearch, fires INVENTORY_SEARCH_UPDATE
	-- (our incremental filter refresh hangs off that) and keeps every bag/bank
	-- search field in sync. Hand-wiring the bare template proved unreliable.
	local search = CreateFrame("EditBox", nil, frame, "BagSearchBoxTemplate")
	local searchH = SearchBoxHeight()
	local searchY = ContainerWindow.GetChromeSearchY()
	search:SetAutoFocus(false)
	search:SetPoint("TOPLEFT", frame, "TOPLEFT", leftX + 4, searchY)
	search:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -reserve, searchY)
	ApplySearchBoxHeight(search, searchH)
	if search.Instructions then
		search.Instructions:SetWordWrap(false)
	end
	return search
end

--- Re-set the search field's right edge for `rightButtonCount` chrome buttons,
--- used when a toolbar button shows/hides at runtime (e.g. Delete Cheapest).
--- `extraReserve` adds width when a chrome control is wider than `btnW` (toolbar arrow).
function ContainerWindow:SetSearchReserve(rightButtonCount, extraReserve)
	if not self.search then
		return
	end
	local _, rightX, _, btnW, btnGap = ContainerWindow.GetChromeInsets()
	local reserve = SearchReserve(rightX, btnW, btnGap, rightButtonCount) + (extraReserve or 0)
	local searchH = SearchBoxHeight()
	local searchY = ContainerWindow.GetChromeSearchY()
	self.search:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -reserve, searchY)
	ApplySearchBoxHeight(self.search, searchH)
end

function ContainerWindow:CheckCombatDraw()
	if InCombatLockdown() then
		self.pendingDraw = true
		return true
	end
	self.pendingDraw = false
	return false
end

function ContainerWindow:FindMainSection(sections, mainName, categories)
	if self.scanner and self.scanner.sectionsByName and mainName then
		local section = self.scanner.sectionsByName[mainName]
		if section then
			return section
		end
	end
	if not sections then
		return
	end
	for i = 1, #sections do
		local section = sections[i]
		if section.name == mainName or (categories and categories:IsMainPanel(section.name)) then
			return section
		end
	end
end

--- Shared masonry draw. See opts table in ContainerWindow.DrawCategorized below.
function ContainerWindow:DrawCategorized(opts)
	if not self.frame then
		return
	end
	if opts.requireOpen and not self.open then
		return
	end
	if self:CheckCombatDraw() then
		return
	end

	local categories = ns:GetModule("Categories")
	local cols = opts.columns or C.Layout.COLUMNS
	local gridW = opts.gridWidth or ns.Container.GridWidth(cols)
	local sections = opts.drawSections or opts.sections
	local mainName = opts.mainName or (categories and categories:GetMainCategory())
	-- Each window passes its own perColumn (backpack and bank track it separately);
	-- the shared base never reaches into a specific window's DB.
	local perColumn = opts.perColumn or C.Layout.DEFAULT_CATEGORIES_PER_COLUMN

	local active = self.activeCategories
	wipe(active)
	self.visibleCategoryOrder = self.visibleCategoryOrder or {}
	wipe(self.visibleCategoryOrder)

	if opts.beforeLayout then
		opts.beforeLayout(cols, gridW)
	end

	local mainSection = opts.mainSection
	if not mainSection and sections then
		mainSection = self:FindMainSection(sections, mainName, categories)
	end

	local layoutSection = mainSection
	if opts.mainTitle then
		layoutSection = {
			name = opts.mainTitle,
			items = mainSection and mainSection.items or emptyItems,
		}
	end

	local layoutOpts = opts.mainLayoutOpts or {}
	layoutOpts.forceWidth = gridW
	if opts.layoutBatchSize then
		layoutOpts.layoutBatchSize = opts.layoutBatchSize
	end
	self.mainContainer:Layout(layoutSection, cols, layoutOpts)

	ns.Container.StackCategories({
		sections = sections,
		mainName = mainName,
		mainFrame = self.frame,
		columns = cols,
		gridWidth = gridW,
		perColumn = perColumn,
		freeSlots = opts.freeSlots,
		layoutBatchSize = opts.layoutBatchSize,
		owner = self,
		active = active,
	})

	self:HideInactiveCategoryContainers()

	if opts.afterLayout then
		opts.afterLayout()
	end
end
