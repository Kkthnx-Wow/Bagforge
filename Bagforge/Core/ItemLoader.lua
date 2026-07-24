--[[
	Bagforge - ItemLoader (static per-slot Item mixin cache)
	-------------------------------------------------------------------------
	BetterBags pattern: one permanent Item mixin per physical bag slot. The
	mixin is bound to bag+slot, not item identity, so it stays valid when
	Blizzard sort moves items. Avoids CreateFromBagAndSlot GC churn on every
	scan and gives ContinuableContainer a stable continuable per slot.
--]]

local _, ns = ...
local F = ns.F

local ItemMixinClass = _G["Item"]
local C_Container = C_Container
local C_Item = C_Item
local GetContainerItemID = C_Container.GetContainerItemID
local IsItemDataCachedByID = C_Item and C_Item.IsItemDataCachedByID
local wipe = wipe

local ItemLoader = {}
ns.ItemLoader = ItemLoader

local mixinsBySlotKey = {}

--- Permanent Item mixin for this bag slot (create once, reuse forever).
function ItemLoader.GetMixin(bag, slot)
	if not (ItemMixinClass and ItemMixinClass.CreateFromBagAndSlot and bag and slot) then
		return nil
	end
	local key = F.SlotKey(bag, slot)
	local mixin = mixinsBySlotKey[key]
	if not mixin then
		mixin = ItemMixinClass:CreateFromBagAndSlot(bag, slot)
		mixinsBySlotKey[key] = mixin
	end
	return mixin
end

--- Item link from the cached mixin when container info omits it.
function ItemLoader.GetItemLink(bag, slot)
	local mixin = ItemLoader.GetMixin(bag, slot)
	if not (mixin and mixin.IsValid and mixin:IsValid() and mixin.GetItemLink) then
		return nil
	end
	local ok, link = pcall(mixin.GetItemLink, mixin)
	if ok and link then
		return link
	end
	return nil
end

--- Queue uncached occupied slots into a ContinuableContainer. Returns true if any staged.
function ItemLoader.StageUncachedSlots(bags, container)
	if not (container and container.AddContinuable and IsItemDataCachedByID) then
		return false
	end
	local staged = false
	for i = 1, #bags do
		local bag = bags[i]
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local itemID = GetContainerItemID(bag, slot)
			if itemID and not IsItemDataCachedByID(itemID) then
				local mixin = ItemLoader.GetMixin(bag, slot)
				if mixin then
					container:AddContinuable(mixin)
					staged = true
				end
			end
		end
	end
	return staged
end

--- Drop cached Item mixins (e.g. on zone change / reload). Slots are recreated on demand.
function ItemLoader.Clear()
	wipe(mixinsBySlotKey)
end
