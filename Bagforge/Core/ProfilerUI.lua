--[[
	Bagforge - Profiler window
	-------------------------------------------------------------------------
	A ranked table over the numbers Core/Profiler.lua collects. One window, no
	state of its own beyond the sort column and the search text.

	  * Click a column header to sort, click again to flip the direction.
	  * The search box filters by probe name ("scan", "event:", "button").
	  * Hover a row for the full detail and the call stack of its slowest call.
	    Right-click a row to print that stack to chat.
	  * Start, Stop, Reset and Bench drive the profiler. Native and Memory print
	    their reports to chat.
	  * The footer shows the client's own per-addon numbers (C_AddOnProfiler) next
	    to ours, so a probe total can be sanity-checked against the engine.

	The window refreshes once a second while it is open and the profiler runs,
	and never builds rows for anything off screen. Rows are a fixed pool, scrolled
	by offset, so a few hundred probes cost no more than sixteen rows.
--]]

local _, ns = ...
local C, F = ns.C, ns.F
local format = string.format
local sort = table.sort
local floor = math.floor
local min, max = math.min, math.max

local ProfilerUI = {}
ns.ProfilerUI = ProfilerUI

local FRAME_NAME = "BagforgeProfilerFrame"
local ROW_HEIGHT = 20
local VISIBLE_ROWS = 16
local REFRESH_SECONDS = 1
local WHEEL_STEP = 3
local SETTINGS_SHARED = "Blizzard_Settings_Shared"

local HEAT_WARN_MS = 1
local HEAT_HOT_MS = 5

-- width is pixels, field is the row key the profiler snapshot uses.
local COLUMNS = {
	{ key = "label", title = "Function", width = 250, justify = "LEFT" },
	{ key = "calls", title = "Calls", width = 58, justify = "RIGHT", fmt = "int" },
	{ key = "callsPerSec", title = "/s", width = 52, justify = "RIGHT", fmt = "rate" },
	{ key = "selfMs", title = "Self ms", width = 68, justify = "RIGHT", fmt = "ms", heat = true },
	{ key = "totalMs", title = "Total ms", width = 68, justify = "RIGHT", fmt = "ms" },
	{ key = "avgMs", title = "Avg ms", width = 58, justify = "RIGHT", fmt = "ms" },
	{ key = "peakMs", title = "Peak ms", width = 58, justify = "RIGHT", fmt = "ms", heat = true },
	{ key = "slow", title = ">1ms", width = 48, justify = "RIGHT", fmt = "int" },
	{ key = "allocKB", title = "Alloc KB", width = 66, justify = "RIGHT", fmt = "kb" },
	{ key = "retainedKB", title = "Net KB", width = 66, justify = "RIGHT", fmt = "kb" },
}
local LEFT_PAD, RIGHT_PAD = 14, 30

local state = {
	sortKey = "selfMs",
	descending = true,
	filter = "",
	offset = 0,
}

local ui -- widgets, built on first open

-- ---------------------------------------------------------------------------
-- Pure helpers (kept free of frames so the headless tests can run them)
-- ---------------------------------------------------------------------------
function ProfilerUI.FilterRows(rows, text)
	if not text or text == "" then
		return rows
	end
	local out = {}
	for i = 1, #rows do
		if rows[i].label:lower():find(text, 1, true) then
			out[#out + 1] = rows[i]
		end
	end
	return out
end

function ProfilerUI.SortRows(rows, key, descending)
	sort(rows, function(a, b)
		local av, bv = a[key], b[key]
		-- A missing value (Net KB without the engine path) always sorts last.
		if av == nil or bv == nil then
			if av == bv then
				return a.label < b.label
			end
			return av ~= nil
		end
		if av == bv then
			return a.label < b.label
		end
		if descending then
			return av > bv
		end
		return av < bv
	end)
	return rows
end

local function FormatValue(fmt, value)
	if value == nil then
		return "-"
	end
	if fmt == "int" then
		return format("%d", value)
	elseif fmt == "rate" then
		return value >= 100 and format("%.0f", value) or format("%.1f", value)
	elseif fmt == "ms" then
		if value >= 100 then
			return format("%.1f", value)
		elseif value >= 10 then
			return format("%.2f", value)
		end
		return format("%.3f", value)
	elseif fmt == "kb" then
		return format("%.0f", value)
	end
	return tostring(value)
end
ProfilerUI.FormatValue = FormatValue

local function HeatColor(ms)
	local colors = C.Colors
	if ms >= HEAT_HOT_MS then
		return colors.red[1], colors.red[2], colors.red[3]
	elseif ms >= HEAT_WARN_MS then
		return colors.yellow[1], colors.yellow[2], colors.yellow[3]
	end
	return 1, 1, 1
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------
local function TotalWidth()
	local w = 0
	for i = 1, #COLUMNS do
		w = w + COLUMNS[i].width
	end
	return w
end

local function MakeButton(parent, text, width, onClick)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 22)
	button:SetText(text)
	button:SetScript("OnClick", onClick)
	return button
end

local function ShowRowTooltip(row)
	local data = row.data
	if not data then
		return
	end
	local tip = GameTooltip
	tip:SetOwner(row, "ANCHOR_RIGHT")
	tip:AddLine(data.label, 1, 0.82, 0)
	tip:AddDoubleLine("Calls", format("%d  (%.1f/s)", data.calls, data.callsPerSec), 0.8, 0.8, 0.8, 1, 1, 1)
	tip:AddDoubleLine("Self / total", format("%.3f / %.3f ms", data.selfMs, data.totalMs), 0.8, 0.8, 0.8, 1, 1, 1)
	tip:AddDoubleLine("Average / peak", format("%.3f / %.3f ms", data.avgMs, data.peakMs), 0.8, 0.8, 0.8, 1, 1, 1)
	tip:AddDoubleLine(format("Calls over %dms", 1), format("%d", data.slow), 0.8, 0.8, 0.8, 1, 1, 1)
	tip:AddDoubleLine("Allocated", format("%.0f KB", data.allocKB), 0.8, 0.8, 0.8, 1, 1, 1)
	if data.retainedKB then
		tip:AddDoubleLine("Net (not freed in the call)", format("%.0f KB", data.retainedKB), 0.8, 0.8, 0.8, 1, 1, 1)
	end
	if data.peakStack then
		tip:AddLine(" ")
		tip:AddLine("Slowest call, called from:", 0.99, 0.61, 0.13)
		local lines = 0
		for line in data.peakStack:gmatch("[^\n]+") do
			tip:AddLine(line, 0.65, 0.65, 0.65)
			lines = lines + 1
			if lines >= 8 then
				break
			end
		end
		tip:AddLine("Right-click to print the stack to chat.", 0.5, 0.5, 0.5)
	end
	tip:Show()
end

local function CreateRow(parent, index)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
	row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)
	row:RegisterForClicks("AnyUp")

	local stripe = row:CreateTexture(nil, "BACKGROUND")
	stripe:SetAllPoints()
	stripe:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
	row.stripe = stripe

	local highlight = row:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetColorTexture(0.99, 0.61, 0.13, 0.14)

	row.cells = {}
	local x = 0
	for i = 1, #COLUMNS do
		local column = COLUMNS[i]
		local fs = F.CreateFS(row, 11, "", "OVERLAY")
		fs:SetTextColor(1, 1, 1)
		fs:SetJustifyH(column.justify)
		fs:SetWordWrap(false)
		fs:SetWidth(column.width - 8)
		fs:SetPoint("LEFT", row, "LEFT", x + 4, 0)
		row.cells[i] = fs
		x = x + column.width
	end

	row:SetScript("OnEnter", ShowRowTooltip)
	row:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	row:SetScript("OnClick", function(self, button)
		if button == "RightButton" and self.data then
			ns.Profiler:PrintStack(self.data.label)
		end
	end)
	return row
end

local function UpdateRows()
	local rows = ui.shown
	local total = #rows
	local maxOffset = max(total - VISIBLE_ROWS, 0)
	state.offset = min(max(state.offset, 0), maxOffset)

	for i = 1, VISIBLE_ROWS do
		local row = ui.rows[i]
		local data = rows[state.offset + i]
		row.data = data
		if data then
			for c = 1, #COLUMNS do
				local column = COLUMNS[c]
				local value = data[column.key]
				local fs = row.cells[c]
				if column.key == "label" then
					fs:SetText(value)
					if value:find("^event:") then
						fs:SetTextColor(0.55, 0.75, 1)
					else
						fs:SetTextColor(1, 1, 1)
					end
				else
					fs:SetText(FormatValue(column.fmt, value))
					if column.heat and value then
						fs:SetTextColor(HeatColor(value))
					else
						fs:SetTextColor(1, 1, 1)
					end
				end
			end
			row:Show()
		else
			row:Hide()
		end
	end

	ui.updatingSlider = true
	ui.slider:SetMinMaxValues(0, maxOffset)
	ui.slider:SetValue(state.offset)
	ui.slider:SetShown(maxOffset > 0)
	ui.updatingSlider = false
end

local function UpdateHeaders()
	for i = 1, #COLUMNS do
		local column = COLUMNS[i]
		local header = ui.headers[i]
		local arrow = ""
		if state.sortKey == column.key then
			arrow = state.descending and "  v" or "  ^"
		end
		header.text:SetText(column.title .. arrow)
		if state.sortKey == column.key then
			header.text:SetTextColor(0.99, 0.61, 0.13)
		else
			header.text:SetTextColor(1, 0.82, 0)
		end
	end
end

local function NativeFooterText()
	local data = ns.Profiler:ReadNative()
	if not data then
		return "Client profiler: not available on this client"
	end
	local mine = data.addon.RecentAverageTime
	local all = data.overall.RecentAverageTime
	if data.allZero then
		return "Client profiler: reports 0 (stubbed here, or nothing ran). Trust the table."
	end
	return format("Client profiler, recent avg per tick:  Bagforge %.3f ms   all addons %.3f ms   peak %.3f ms",
		mine or 0, all or 0, data.addon.PeakTime or 0)
end

function ProfilerUI:Refresh()
	if not (ui and ui.frame:IsShown()) then
		return
	end
	local profiler = ns.Profiler
	local rows = profiler:GetRows()
	rows = ProfilerUI.FilterRows(rows, state.filter)
	ProfilerUI.SortRows(rows, state.sortKey, state.descending)
	ui.shown = rows

	UpdateHeaders()
	UpdateRows()

	local status = profiler:GetStatus()
	ui.startButton:SetText(status.active and "Stop" or "Start")
	ui.empty:SetShown(#rows == 0)
	ui.empty:SetText(status.active
		and "Running. Use your bags, open the bank, sort, and the table fills in."
		or "No data yet. Press Start, use your bags, then watch this fill. Bench measures fixed workloads.")

	ui.footerNative:SetText(NativeFooterText())
	ui.footerMode:SetText(format("%s  |  %d probes  |  %.0fs  |  probe overhead %s", status.active and "running" or "stopped",
		status.probeCount, status.seconds, status.overheadUs and format("%.2f us/call", status.overheadUs) or "not measured"))
end

local function SetSort(key)
	if state.sortKey == key then
		state.descending = not state.descending
	else
		state.sortKey = key
		-- Names read best A to Z, every number reads best biggest first.
		state.descending = key ~= "label"
	end
	state.offset = 0
	ProfilerUI:Refresh()
end

local function EnsureSettingsTemplate()
	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.LoadAddOn and not C_AddOns.IsAddOnLoaded(SETTINGS_SHARED) then
		pcall(C_AddOns.LoadAddOn, SETTINGS_SHARED)
	end
end

local function Build()
	EnsureSettingsTemplate()

	local width = TotalWidth() + LEFT_PAD + RIGHT_PAD
	local height = 120 + VISIBLE_ROWS * ROW_HEIGHT + 20
	local frame = CreateFrame("Frame", FRAME_NAME, UIParent, "SettingsFrameTemplate")
	frame:SetSize(width, height)
	frame:SetPoint("CENTER")
	-- Above the bag and bank windows, which sit in HIGH: the profiler is read
	-- while they are open, and it came up underneath them.
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()

	local title = frame.NineSlice and frame.NineSlice.Text
	if title then
		title:SetText("Bagforge Profiler")
	end
	tinsert(UISpecialFrames, FRAME_NAME)

	ui = { frame = frame, rows = {}, headers = {}, shown = {} }

	-- Toolbar -------------------------------------------------------------
	local toolbarY = -34
	local startButton = MakeButton(frame, "Start", 64, function()
		if ns.Profiler:IsActive() then
			ns.Profiler:Stop(true)
		else
			ns.Profiler:Start()
		end
		ProfilerUI:Refresh()
	end)
	startButton:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT_PAD, toolbarY)
	ui.startButton = startButton

	local reset = MakeButton(frame, "Reset", 56, function()
		ns.Profiler:Reset()
		ProfilerUI:Refresh()
	end)
	reset:SetPoint("LEFT", startButton, "RIGHT", 4, 0)

	local bench = MakeButton(frame, "Bench", 56, function()
		ns.Profiler:Bench()
		ProfilerUI:Refresh()
	end)
	bench:SetPoint("LEFT", reset, "RIGHT", 4, 0)

	local native = MakeButton(frame, "Native", 60, function()
		ns.Profiler:PrintNative()
	end)
	native:SetPoint("LEFT", bench, "RIGHT", 4, 0)

	local memory = MakeButton(frame, "Memory", 64, function()
		ns.Profiler:Memory(false)
	end)
	memory:SetPoint("LEFT", native, "RIGHT", 4, 0)

	-- SearchBoxTemplate when the client has it, a plain input otherwise.
	local ok, search = pcall(CreateFrame, "EditBox", nil, frame, "SearchBoxTemplate")
	if not ok or not search then
		search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	end
	search:SetSize(190, 22)
	search:SetAutoFocus(false)
	search:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -RIGHT_PAD + 4, toolbarY)
	search:HookScript("OnTextChanged", function(self)
		state.filter = (self:GetText() or ""):lower()
		state.offset = 0
		ProfilerUI:Refresh()
	end)
	ui.search = search

	-- Column headers ------------------------------------------------------
	local headerY = toolbarY - 30
	local x = LEFT_PAD
	for i = 1, #COLUMNS do
		local column = COLUMNS[i]
		local header = CreateFrame("Button", nil, frame)
		header:SetSize(column.width, 20)
		header:SetPoint("TOPLEFT", frame, "TOPLEFT", x, headerY)
		header.text = F.CreateFS(header, 11, column.title, "OVERLAY")
		header.text:SetJustifyH(column.justify)
		header.text:SetPoint("LEFT", header, "LEFT", 4, 0)
		header.text:SetPoint("RIGHT", header, "RIGHT", -4, 0)
		local hl = header:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.08)
		header:SetScript("OnClick", function()
			SetSort(column.key)
		end)
		ui.headers[i] = header
		x = x + column.width
	end

	-- Row area ------------------------------------------------------------
	local body = CreateFrame("Frame", nil, frame)
	body:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT_PAD, headerY - 22)
	body:SetSize(TotalWidth(), VISIBLE_ROWS * ROW_HEIGHT)
	body:EnableMouseWheel(true)
	local function OnWheel(_, delta)
		state.offset = state.offset - delta * WHEEL_STEP
		UpdateRows()
	end
	body:SetScript("OnMouseWheel", OnWheel)
	for i = 1, VISIBLE_ROWS do
		local row = CreateRow(body, i)
		row:EnableMouseWheel(true)
		row:SetScript("OnMouseWheel", OnWheel)
		ui.rows[i] = row
	end

	ui.empty = F.CreateFS(body, 12, "", "OVERLAY")
	ui.empty:SetTextColor(0.65, 0.65, 0.65)
	ui.empty:SetPoint("CENTER", body, "CENTER", 0, 0)

	-- Scrollbar: a plain slider, the list only ever scrolls by whole rows.
	local slider = CreateFrame("Slider", nil, frame)
	slider:SetOrientation("VERTICAL")
	slider:SetPoint("TOPLEFT", body, "TOPRIGHT", 6, 0)
	slider:SetPoint("BOTTOMLEFT", body, "BOTTOMRIGHT", 6, 0)
	slider:SetWidth(10)
	slider:SetMinMaxValues(0, 0)
	slider:SetValueStep(1)
	slider:SetObeyStepOnDrag(true)
	local track = slider:CreateTexture(nil, "BACKGROUND")
	track:SetAllPoints()
	track:SetColorTexture(1, 1, 1, 0.06)
	slider:SetThumbTexture(slider:CreateTexture(nil, "OVERLAY"))
	local thumb = slider:GetThumbTexture()
	thumb:SetColorTexture(0.99, 0.61, 0.13, 0.7)
	thumb:SetSize(10, 40)
	slider:SetScript("OnValueChanged", function(_, value)
		if ui.updatingSlider then
			return
		end
		state.offset = floor(value + 0.5)
		UpdateRows()
	end)
	ui.slider = slider

	-- Footer --------------------------------------------------------------
	ui.footerNative = F.CreateFS(frame, 11, "", "OVERLAY")
	ui.footerNative:SetTextColor(0.8, 0.8, 0.8)
	ui.footerNative:SetJustifyH("LEFT")
	ui.footerNative:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 4, -8)

	ui.footerMode = F.CreateFS(frame, 11, "", "OVERLAY")
	ui.footerMode:SetTextColor(0.6, 0.6, 0.6)
	ui.footerMode:SetJustifyH("LEFT")
	ui.footerMode:SetPoint("TOPLEFT", ui.footerNative, "BOTTOMLEFT", 0, -4)

	-- Refresh once a second. A hidden frame gets no OnUpdate, so this costs
	-- nothing while the window is closed.
	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < REFRESH_SECONDS then
			return
		end
		elapsed = 0
		ProfilerUI:Refresh()
	end)
	frame:SetScript("OnShow", function()
		ProfilerUI:Refresh()
	end)
	frame:SetScript("OnHide", function()
		GameTooltip:Hide()
	end)

	return frame
end

function ProfilerUI:Open()
	if not ui then
		Build()
	end
	ui.frame:Show()
	self:Refresh()
end

function ProfilerUI:Toggle()
	if ui and ui.frame:IsShown() then
		ui.frame:Hide()
	else
		self:Open()
	end
end
