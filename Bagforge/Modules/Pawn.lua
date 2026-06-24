--[[
	Bagforge - Pawn integration
	-------------------------------------------------------------------------
	When the Pawn addon is installed, show its green upgrade arrow on bag/bank
	items that are an upgrade for the player. Mirrors BetterBags' integration
	(integrations/pawn.lua): after each draw we ask Pawn whether an item link
	should carry an upgrade arrow and toggle the button's overlay accordingly.

	We don't compute anything ourselves - Pawn owns the scoring/comparison. Our
	job is purely display: publish a checker as `ns.PawnIsUpgrade`, which the
	item button reads while it's painting each slot, and force a redraw whenever
	the answer might change (Pawn loads, gear swaps, scales change).
--]]

local _, ns = ...
local F, L = ns.F, ns.L

ns:RegisterDefaults({
	pawn = {
		enable = true, -- only has any effect when the Pawn addon is present
	},
})

local Pawn = ns:NewModule("Pawn", "pawn")
Pawn.title = L["Pawn"]
Pawn.order = 40
Pawn.group = "display"

-- Pawn defines these globals only when installed, so their presence is also our
-- "is Pawn loaded" probe. PawnShouldItemLinkHaveUpgradeArrow is the API Pawn's
-- own PawnBags.lua tells bag authors to use (it can answer nil = "ask again
-- shortly" when throttled); the Unbudgeted variant is the older fallback.
local function PawnAvailable()
	return type(_G["PawnShouldItemLinkHaveUpgradeArrow"]) == "function" or type(_G["PawnShouldItemLinkHaveUpgradeArrowUnbudgeted"]) == "function"
end

-- Coalesce Pawn's "ask again later" answers into a single deferred repaint: when
-- Pawn returns nil it has throttled itself for this frame, so we schedule one
-- redraw and re-ask on the next paint (PawnBags.lua's RetryButtonsNeedingUpdate
-- pattern). Self-terminating - once every visible item resolves it's cached, so
-- nothing nils and the retry stops firing.
local scheduleRetry = F.DebounceNoArgs(0.15, function()
	ns:RefreshBags(false)
end)

-- Per-link cache of Pawn's last *definitive* (non-nil) answer. The budgeted API
-- returns nil for any item it skipped THIS frame, not just on first sight - so
-- without a cache an already-resolved arrow would re-ask, get nil on a busy
-- frame, hide, and re-show next retry: a permanent blink + repaint loop. Caching
-- the resolved boolean means resolved items are never re-asked (so they can't
-- nil and can't blink). Wiped wholesale whenever the verdict could change (gear
-- swap, scale edit, toggle) in Pawn:Apply().
local resultCache = {}

--- Returns true only when Pawn positively reports `link` as an upgrade.
--- Secret-guarded (item links can be secret in instances/combat) and pcall'd so
--- a Pawn-side error can never break a bag draw. Resolved answers are cached; a
--- nil answer (throttled) holds the arrow hidden for now and queues a retry.
function Pawn:IsUpgrade(link)
	if not link or F.IsSecret(link) then
		return false
	end

	-- Definitive answer already known - never re-ask (avoids the budgeted-nil blink).
	local cached = resultCache[link]
	if cached ~= nil then
		return cached
	end

	local fn = _G["PawnShouldItemLinkHaveUpgradeArrow"]
	if fn then
		local ok, result = pcall(fn, link, true) -- true = also check player level
		if not ok then
			return false
		end
		if result == nil then
			scheduleRetry()
			return false
		end
		local up = result == true
		resultCache[link] = up
		return up
	end

	-- Older Pawn builds: the unbudgeted check (no throttle/nil contract).
	local unbudgeted = _G["PawnShouldItemLinkHaveUpgradeArrowUnbudgeted"]
	if unbudgeted then
		local ok, result = pcall(unbudgeted, link, true)
		local up = ok and result == true
		resultCache[link] = up
		return up
	end
	return false
end

-- Register as a Pawn third-party bag: Pawn then leaves our own buttons alone
-- (it can't see them anyway) and calls our RefreshAll whenever a settings change
-- means every arrow should be re-evaluated. Best-effort and one-shot.
local function RegisterThirdPartyBag()
	local register = _G["PawnRegisterThirdPartyBag"]
	if type(register) == "function" and not Pawn._registered then
		Pawn._registered = pcall(register, ns.title, {
			RefreshAll = function()
				Pawn:Apply()
			end,
		}) or nil
	end
end

-- ---------------------------------------------------------------------------
-- Wiring
--   Publishing the checker (or clearing it) is all the item button needs; a
--   redraw then repaints every visible slot with the right arrow state.
-- ---------------------------------------------------------------------------
function Pawn:Apply()
	-- Verdicts may all have changed (new gear/scale, or toggled off) - drop the
	-- cache so the next paint re-asks Pawn fresh.
	wipe(resultCache)
	if PawnAvailable() and ns.db.pawn.enable then
		ns.PawnIsUpgrade = function(link)
			return Pawn:IsUpgrade(link)
		end
		if ns.API and ns.API.RegisterCornerWidget and not Pawn._cornerRegistered then
			Pawn._cornerRegistered = ns.API:RegisterCornerWidget({
				key = "pawn.upgrade",
				source = "Pawn",
				corner = "left",
				priority = 10,
				update = function(_, entry)
					if not entry or not entry.hyperlink then
						return false
					end
					return Pawn:IsUpgrade(entry.hyperlink), "bags-greenarrow", 20, 22
				end,
			})
		end
	else
		ns.PawnIsUpgrade = nil
	end
	-- Repaint open windows from current data (no rescan: only the arrow state
	-- changed). The shared coordinator redraws the backpack and nudges the bank.
	ns:RefreshBags(false)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function Pawn:OnEnable()
	-- Silent no-op when Pawn isn't installed - no arrows, no events, no cost.
	if not PawnAvailable() then
		ns.PawnIsUpgrade = nil
		return
	end

	RegisterThirdPartyBag()
	self:Apply()

	-- Equipping/changing gear or editing a Pawn scale changes what counts as an
	-- upgrade; refresh so the arrows track it. A full gear / equipment-set swap
	-- fires PLAYER_EQUIPMENT_CHANGED once per slot (~16 in a burst), so debounce
	-- to re-evaluate and repaint once per swap instead of once per slot - the
	-- same event-storm coalescing the rest of the addon uses.
	local refresh = F.DebounceNoArgs(0.1, function()
		Pawn:Apply()
	end)
	ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", refresh)
end

function Pawn:OnSettingChanged(key)
	if key == "enable" then
		self:Apply()
	end
end

-- ---------------------------------------------------------------------------
-- Settings panel
-- ---------------------------------------------------------------------------
function Pawn:RegisterOptions(category, builder)
	builder:Checkbox(category, self, "enable", L["Show Upgrade Arrows"], L["Show Pawn's green upgrade arrow on items that are an upgrade for you. Requires the Pawn addon."])
end
