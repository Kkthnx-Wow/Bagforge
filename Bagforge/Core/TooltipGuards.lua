--[[
	Bagforge - Tooltip guards
	-------------------------------------------------------------------------
	Blizzard's default sell-price tooltip line routes through MoneyFrame, which
	can taint (and error on secret coin values in combat). BagBrother/Bagnon
	replace that line with plain GetMoneyString text via TooltipDataProcessor.
--]]

local _, ns = ...
local F = ns.F

local format = string.format
local TooltipDataProcessor = TooltipDataProcessor
local Enum = Enum

if not (TooltipDataProcessor and Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.SellPrice) then
	return
end

local SELL_PRICE = _G["SELL_PRICE"]
local MINIMUM = _G["MINIMUM"]
local MAXIMUM = _G["MAXIMUM"]
local GetMoneyString = GetMoneyString

TooltipDataProcessor.AddLinePreCall(Enum.TooltipDataLineType.SellPrice, function(tip, data)
	if not data or not data.price or tip.isShopping then
		return
	end
	if F.IsSecret(data.price) or (data.maxPrice and F.IsSecret(data.maxPrice)) then
		return true
	end
	if data.maxPrice and F.NotSecret(data.maxPrice) and data.maxPrice >= 1 then
		tip:AddLine(format("%s:", SELL_PRICE), 1, 1, 1, true)
		tip:AddLine(format("    %s: %s", MINIMUM, GetMoneyString(data.price, true)), 1, 1, 1, true)
		tip:AddLine(format("    %s: %s", MAXIMUM, GetMoneyString(data.maxPrice, true)), 1, 1, 1, true)
	else
		tip:AddLine(format("%s: %s", SELL_PRICE, GetMoneyString(data.price, true)), 1, 1, 1, true)
	end
	return true
end)
