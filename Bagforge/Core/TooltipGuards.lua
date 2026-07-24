--[[
	Bagforge - Tooltip guards
	-------------------------------------------------------------------------
	Blizzard's default sell-price tooltip line routes through MoneyFrame.
	BagBrother/Bagnon replace that line with plain GetMoneyString text via TooltipDataProcessor.
	(WoWUIBugs #838 — MoneyFrame still used in default tooltip sell-price path.)
--]]

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
	if data.maxPrice and data.maxPrice >= 1 then
		tip:AddLine(format("%s:", SELL_PRICE), 1, 1, 1, true)
		tip:AddLine(format("    %s: %s", MINIMUM, GetMoneyString(data.price, true)), 1, 1, 1, true)
		tip:AddLine(format("    %s: %s", MAXIMUM, GetMoneyString(data.maxPrice, true)), 1, 1, 1, true)
	else
		tip:AddLine(format("%s: %s", SELL_PRICE, GetMoneyString(data.price, true)), 1, 1, 1, true)
	end
	return true
end)
