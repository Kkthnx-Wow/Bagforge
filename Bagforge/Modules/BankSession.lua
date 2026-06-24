--[[
	Bagforge - BankSession
	-------------------------------------------------------------------------
	BankPanel taint handling, Blizzard BankFrame suppression, deposit-context
	refresh, and close-hook guards shared by every bank view.
--]]

local _, ns = ...
local C_Timer = C_Timer
local ItemButtonUtil = ItemButtonUtil
local hooksecurefunc = hooksecurefunc

local BankSession = {}
ns.BankSession = BankSession

local suppressedBankFrame
local suppressedBankAlpha
local suppressedBankStrata
local isClosingBank = false
local isSwitchingView = false

function BankSession.IsClosingBank()
	return isClosingBank
end

function BankSession.IsSwitchingView()
	return isSwitchingView
end

function BankSession.SetClosingBank(value)
	isClosingBank = value
end

function BankSession.SetSwitchingView(value)
	isSwitchingView = value
end

function BankSession:EnsureBankPanel(view)
	local panel = _G["BankPanel"]
	if not panel or not view then
		return
	end
	panel:SetAlpha(0)
	panel:EnableMouse(false)
	panel:EnableKeyboard(false)
	if panel.MoneyFrame then
		panel.MoneyFrame:Hide()
	end
	if panel.AutoDepositFrame then
		panel.AutoDepositFrame:Hide()
	end
	if panel.Header then
		panel.Header:Hide()
	end
	panel:Show()
	if panel.SetBankType and view.bankType then
		panel:SetBankType(view.bankType)
	end
end

function BankSession:HideBankPanel()
	local panel = _G["BankPanel"]
	if panel then
		panel:Hide()
	end
end

function BankSession:IsBankOpen()
	local frame = _G["BankFrame"]
	return frame and frame:IsShown()
end

function BankSession:RefreshItemContext()
	if ItemButtonUtil and ItemButtonUtil.TriggerEvent and ItemButtonUtil.Event then
		ItemButtonUtil.TriggerEvent(ItemButtonUtil.Event.ItemContextChanged)
	end
end

function BankSession:InstallBankFrameHooks(bankModule)
	local bankFrame = _G["BankFrame"]
	if not bankFrame or bankFrame.bfOnShowHooked then
		return
	end
	bankFrame.bfOnShowHooked = true
	bankFrame:HookScript("OnShow", function()
		C_Timer.After(0, function()
			if not BankSession:IsBankOpen() then
				return
			end
			local open = bankModule:OpenView()
			if open then
				BankSession:EnsureBankPanel(open)
			end
			BankSession:RefreshItemContext()
		end)
	end)
end

function BankSession:InstallCloseHooks(views)
	for i = 1, #views do
		local frame = views[i].frame
		if frame then
			hooksecurefunc(frame, "Hide", function()
				if isClosingBank or isSwitchingView then
					return
				end
				local bankFrame = _G["BankFrame"]
				if not bankFrame or not bankFrame:IsShown() then
					return
				end
				isClosingBank = true
				if C_Bank and C_Bank.CloseBankFrame then
					C_Bank.CloseBankFrame()
				else
					local close = _G["CloseBankFrame"]
					if close then
						close()
					end
				end
				C_Timer.After(0, function()
					isClosingBank = false
				end)
			end)
		end
	end
end

function BankSession:SuppressBlizzardBankFrame(bankModule)
	if not bankModule:HasEnabledView() then
		BankSession:RestoreBlizzardBankFrame()
		return
	end

	local frame = _G["BankFrame"]
	if not frame or suppressedBankFrame == frame then
		return
	end

	suppressedBankFrame = frame
	suppressedBankAlpha = frame:GetAlpha()
	suppressedBankStrata = frame:GetFrameStrata()
	frame:SetAlpha(0)
	frame:SetFrameStrata("BACKGROUND")
end

function BankSession:RestoreBlizzardBankFrame()
	local frame = suppressedBankFrame
	if not frame then
		return
	end

	if suppressedBankAlpha then
		frame:SetAlpha(suppressedBankAlpha)
	end
	if suppressedBankStrata then
		frame:SetFrameStrata(suppressedBankStrata)
	end
	suppressedBankFrame = nil
	suppressedBankAlpha = nil
	suppressedBankStrata = nil
end

function BankSession:CloseAll(views)
	isClosingBank = true
	for i = 1, #views do
		views[i]:Close()
	end
	BankSession:RestoreBlizzardBankFrame()
	BankSession:HideBankPanel()
	C_Timer.After(0, function()
		isClosingBank = false
	end)
end
