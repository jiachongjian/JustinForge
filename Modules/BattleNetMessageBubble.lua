-- ============================================================
-- JustinForge 模块24: 战网好友消息气泡 (BattleNetMessageBubble.lua)
-- ============================================================
-- 收到战网好友密语时显示常驻气泡，优先使用好友备注作为显示名。
-- 气泡只能通过右上角关闭按钮手动关闭，新密语会更新当前气泡内容。
-- 设置页支持坐标调整及预览/取消预览，预览与真实提示共用相同样式。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local select = select
local type = type
local pcall = pcall
local math_floor = math.floor
local math_pi = math.pi
local IsSecretValue = _G.issecretvalue or function() return false end

local screenWidth = math_floor(UIParent:GetWidth() or 1920)
local screenHeight = math_floor(UIParent:GetHeight() or 1080)
local halfWidth = math_floor(screenWidth / 2)
local halfHeight = math_floor(screenHeight / 2)

local DEFAULT_POS_Y = 260
local ROUNDED_RECT = "Interface\\AddOns\\JustinForge\\Media\\RoundedRect.tga"
local BATTLENET_ICON = "Interface\\FriendsFrame\\Battlenet-BattlenetIcon"
local SOLID_TEXTURE = "Interface\\Buttons\\WHITE8X8"

local module = ns.Module:Register({
    key            = "battleNetMessageBubble",
    name           = L["BNMB_Name"],
    description    = L["BNMB_Desc"],
    defaultEnabled = true,
    options = {
        { type = "slider", key = "posX", name = L["BNMB_PosX"], tooltip = L["BNMB_PosTip"], min = -halfWidth, max = halfWidth, step = 1, default = 0 },
        { type = "slider", key = "posY", name = L["BNMB_PosY"], tooltip = L["BNMB_PosTip"], min = -halfHeight, max = halfHeight, step = 1, default = DEFAULT_POS_Y },
        { type = "button", key = "preview", name = L["BNMB_Preview"], buttonText = L["BNMB_PreviewBtn"], tooltip = L["BNMB_PreviewTip"] },
        { type = "button", key = "stopPreview", name = L["BNMB_StopPreview"], buttonText = L["BNMB_StopPreviewBtn"], tooltip = L["BNMB_StopPreviewTip"] },
    },
})

local bubble
local previewing = false
local HideBubble
local eventFrame = CreateFrame("Frame")

local function GetOption(key)
    local db = ns.db and ns.db.profile and ns.db.profile[module.key]
    return db and db[key]
end

local function ApplyPosition()
    if not bubble then return end
    bubble:ClearAllPoints()
    bubble:SetPoint("CENTER", UIParent, "CENTER", GetOption("posX") or 0, GetOption("posY") or DEFAULT_POS_Y)
end

local function AddRoundedMask(frame, texture)
    local mask = frame:CreateMaskTexture()
    mask:SetTexture(ROUNDED_RECT)
    mask:SetAllPoints(texture)
    texture:AddMaskTexture(mask)
end

local function CreateBubble()
    local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:SetSize(360, 84)
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(80)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetBackdrop({
        bgFile = SOLID_TEXTURE,
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 15,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.018, 0.038, 0.075, 0.97)
    frame:SetBackdropBorderColor(0.32, 0.57, 0.82, 0.95)

    local shadow = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    shadow:SetPoint("TOPLEFT", -7, 7)
    shadow:SetPoint("BOTTOMRIGHT", 7, -7)
    shadow:SetColorTexture(0, 0, 0, 0.55)

    local tailBorder = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    tailBorder:SetSize(18, 18)
    tailBorder:SetPoint("CENTER", frame, "BOTTOM", 0, -3)
    tailBorder:SetColorTexture(0.32, 0.57, 0.82, 0.95)
    tailBorder:SetRotation(math_pi / 4)

    local tail = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
    tail:SetSize(13, 13)
    tail:SetPoint("CENTER", tailBorder, "CENTER")
    tail:SetColorTexture(0.018, 0.038, 0.075, 0.97)
    tail:SetRotation(math_pi / 4)

    local accent = frame:CreateTexture(nil, "ARTWORK")
    accent:SetHeight(1)
    accent:SetPoint("TOPLEFT", 13, -5)
    accent:SetPoint("TOPRIGHT", -13, -5)
    accent:SetColorTexture(0.25, 0.62, 1, 0.85)

    local iconBorder = frame:CreateTexture(nil, "BACKGROUND")
    iconBorder:SetSize(46, 46)
    iconBorder:SetPoint("LEFT", 18, -2)
    iconBorder:SetColorTexture(0.19, 0.48, 0.78, 1)
    AddRoundedMask(frame, iconBorder)

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(38, 38)
    icon:SetPoint("CENTER", iconBorder, "CENTER")
    icon:SetTexture(BATTLENET_ICON)
    AddRoundedMask(frame, icon)

    local caption = frame:CreateFontString(nil, "OVERLAY")
    caption:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
    caption:SetPoint("TOPLEFT", 72, -14)
    caption:SetText(L["BNMB_Caption"])
    caption:SetTextColor(0.55, 0.69, 0.84, 1)
    caption:SetShadowColor(0, 0, 0, 0.9)
    caption:SetShadowOffset(1, -1)

    local suffix = frame:CreateFontString(nil, "OVERLAY")
    suffix:SetFont(STANDARD_TEXT_FONT, 16, "OUTLINE")
    suffix:SetPoint("RIGHT", frame, "RIGHT", -25, -10)
    suffix:SetText(L["BNMB_MessageSuffix"])
    suffix:SetTextColor(0.93, 0.96, 1, 1)
    suffix:SetShadowColor(0, 0, 0, 0.9)
    suffix:SetShadowOffset(1, -1)

    local name = frame:CreateFontString(nil, "OVERLAY")
    name:SetFont(STANDARD_TEXT_FONT, 16, "OUTLINE")
    name:SetHeight(22)
    name:SetPoint("LEFT", frame, "LEFT", 72, -10)
    name:SetPoint("RIGHT", suffix, "LEFT", -6, 0)
    name:SetJustifyH("LEFT")
    name:SetMaxLines(1)
    name:SetWordWrap(false)
    name:SetTextColor(0.32, 0.74, 1, 1)
    name:SetShadowColor(0, 0, 0, 0.9)
    name:SetShadowOffset(1, -1)
    frame.name = name

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetSize(25, 25)
    close:SetPoint("TOPRIGHT", 3, 3)
    close:SetFrameLevel(frame:GetFrameLevel() + 10)
    close:SetScript("OnClick", function()
        HideBubble()
    end)
    close:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(L["BNMB_Close"])
        GameTooltip:Show()
    end)
    close:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    local fadeIn = frame:CreateAnimationGroup()
    local alpha = fadeIn:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0)
    alpha:SetToAlpha(1)
    alpha:SetDuration(0.18)
    alpha:SetSmoothing("OUT")
    fadeIn:SetScript("OnFinished", function()
        frame:SetAlpha(1)
    end)
    frame.fadeIn = fadeIn

    frame:Hide()
    return frame
end

local function EnsureBubble()
    if not bubble then
        bubble = CreateBubble()
    end
    ApplyPosition()
    return bubble
end

HideBubble = function()
    previewing = false
    if not bubble then return end
    bubble.fadeIn:Stop()
    bubble:SetAlpha(1)
    bubble:Hide()
    GameTooltip:Hide()
end

local function ShowBubble(displayName, isPreview)
    local frame = EnsureBubble()
    previewing = isPreview and true or false
    frame.name:SetText(displayName)
    frame.fadeIn:Stop()
    frame:SetAlpha(0)
    frame:Show()
    frame.fadeIn:Play()
end

local function IsNonEmptyText(value)
    if IsSecretValue(value) then return true end
    return type(value) == "string" and value ~= ""
end

local function ResolveDisplayName(sender, accountID)
    local accountInfo
    if type(accountID) == "number" and not IsSecretValue(accountID) and accountID > 0 then
        local ok, info = pcall(C_BattleNet.GetAccountInfoByID, accountID)
        if ok then
            accountInfo = info
        end
    end

    if accountInfo then
        if IsNonEmptyText(accountInfo.note) then
            return accountInfo.note
        end
        if type(BNet_GetBNetAccountName) == "function" then
            local ok, accountName = pcall(BNet_GetBNetAccountName, accountInfo)
            if ok and IsNonEmptyText(accountName) then
                return accountName
            end
        end
        if IsNonEmptyText(accountInfo.accountName) then
            return accountInfo.accountName
        end
        if IsNonEmptyText(accountInfo.battleTag) then
            return accountInfo.battleTag
        end
    end

    if IsNonEmptyText(sender) then
        return sender
    end
    return L["BNMB_UnknownFriend"]
end

local function StartPreview()
    ShowBubble(L["BNMB_PreviewName"], true)
end

local function StopPreview()
    if previewing then
        HideBubble()
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event ~= "CHAT_MSG_BN_WHISPER" or not module.enabled then return end
    local sender = select(2, ...)
    local accountID = select(13, ...)
    ShowBubble(ResolveDisplayName(sender, accountID), false)
end)

function module:OnEnable()
    eventFrame:RegisterEvent("CHAT_MSG_BN_WHISPER")
    Util:Debug("BattleNetMessageBubble: 已启用")
end

function module:OnDisable()
    eventFrame:UnregisterAllEvents()
    HideBubble()
    Util:Debug("BattleNetMessageBubble: 已禁用")
end

function module:OnOptionChanged(key, value)
    if (key == "posX" or key == "posY") and bubble and bubble:IsShown() then
        ApplyPosition()
    end
end

function module:OnButtonClicked(optKey)
    if optKey == "preview" then
        StartPreview()
    elseif optKey == "stopPreview" then
        StopPreview()
    end
end
