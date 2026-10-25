-- Bagforge luacheck config (WoW 12.0.7 / Lua 5.1 sandbox)
std = "lua51"
max_line_length = false
self = false

-- Idiomatic unused args we don't care about
ignore = {
	"212/self",
	"212/_.*", -- underscore-prefixed intentionally-unused
	"432/self",
}

-- The addon vararg (addonName, ns) and its global handle.
globals = {
	"Bagforge",
	"BagforgeDB",
	"BagforgeCharDB",
	"SLASH_BAGFORGE1",
	"SLASH_BAGFORGE2",
	"BINDING_HEADER_BAGFORGE",
}

-- WoW API surface. Declaring a C_* namespace whitelists all its field reads.
read_globals = {
	-- language/global helpers present in the sandbox
	"wipe", "tinsert", "tremove", "tContains", "CopyTable", "Mixin", "CreateFromMixins",
	"strsplit", "strjoin", "strtrim", "strmatch", "strfind", "gsub", "format",
	"hooksecurefunc", "issecurevariable", "securecall", "geterrorhandler",
	"GetTime", "GetTimePreciseSec", "debugprofilestop", "time", "date",
	"CreateFrame", "UIParent", "GameTooltip", "GameFontNormal", "GameFontHighlight",
	"CreateColor", "ColorMixin", "CreateTextureMarkup", "CreateAtlasMarkup",
	"EnumerateFrames", "PlaySound", "IsLoggedIn", "InCombatLockdown", "IsShiftKeyDown",
	"IsControlKeyDown", "IsAltKeyDown", "IsModifiedClick", "GetCursorInfo", "ClearCursor",
	"GetCursorPosition", "GetContainerNumSlots", "GetItemInfo", "GetItemInfoInstant",
	"GetItemCount", "GetCoinTextureString", "GetMoney", "PickupContainerItem",
	"UseContainerItem", "SplitContainerItem", "IsItemDataCachedByID",
	"CreateObjectPool", "CreateFramePool", "CreateTexturePool",
	"BackdropTemplateMixin", "SettingsPanel", "Settings", "InterfaceOptions_AddCategory",
	"ContainerFrameUtil_GetShownFrameForID", "SortBags", "SortBankBags", "SortReagentBankBags",
	"EasyMenu", "MenuUtil", "ToggleDropDownMenu", "UIDropDownMenu_Initialize",
	"Item", "ItemLocation", "ContinuableContainer", "ItemMixin",
	"Enum", "Constants", "LE_ITEM_QUALITY_POOR", "BANK_CONTAINER", "REAGENTBANK_CONTAINER",
	"NUM_BAG_SLOTS", "NUM_BANKBAGSLOTS", "BACKPACK_CONTAINER", "KEYRING_CONTAINER",
	"BreakUpLargeNumbers", "AbbreviateNumbers", "FormatLargeNumber",
	"RAID_CLASS_COLORS", "ITEM_QUALITY_COLORS", "NORMAL_FONT_COLOR", "HIGHLIGHT_FONT_COLOR",
	"RED_FONT_COLOR", "GREEN_FONT_COLOR", "GRAY_FONT_COLOR",
	"UnitClass", "UnitName", "UnitLevel", "GetRealmName", "UnitGUID", "UnitFactionGroup",
	"SetTooltipMoney", "GameTooltip_Hide", "GameTooltip_SetDefaultAnchor",
	"PlayerHasToy", "C_Container", "C_Item", "C_AddOns", "C_Timer", "C_CVar",
	"C_ToyBox", "C_TooltipInfo", "C_PlayerInfo", "C_Bank", "C_CurrencyInfo",
	"C_TransmogCollection", "C_Spell", "C_Widget", "C_Texture", "C_EquipmentSet",
	"C_NewItems", "C_ClassColor", "C_QuestLog", "C_MerchantFrame", "C_Reputation",
	"BankFrame", "MerchantFrame", "GameTooltipTextLeft1",
}
