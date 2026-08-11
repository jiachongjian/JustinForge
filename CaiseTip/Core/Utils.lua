----------------------------------------------------------------------
-- CaiseTip / Core / Utils
-- 通用工具函数
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

-- Lua standard library
local select = select
local type = type
local strformat = string.format

-- WoW global API
local issecretvalue = issecretvalue
local issecrettable = issecrettable
local ShouldUnitIdentityBeSecret = C_Secrets.ShouldUnitIdentityBeSecret
local UnitExists = UnitExists
local UnitIsPlayer = UnitIsPlayer
local print = print

local Colors = P.Colors
local t = P.Tex

-- ==================== 秘密值工具 ====================

--- 检查值是否为秘密值
function P.IsSecret(value)
    if value == nil then return false end
    if issecretvalue and issecretvalue(value) then 
        return true
    end
    if issecrettable and type(value) == "table" and issecrettable(value) then
        return true
    end
    return false
end

function P.IsSafeUnit(unit)
    -- issecretvalue 内部安全（nil 返回 false，秘密值返回 true）
    if P.IsSecret(unit) then return false end
    -- 类型/空值检查（能走到这里说明不是秘密值，可以安全比较）
    if type(unit) ~= "string" or unit == "" then return false end
    -- 安全调用
    if ShouldUnitIdentityBeSecret(unit) then return false end
    return true
end

-- ==================== 颜色工具 ====================

function P.GetUnitColor(unit)
    if not P.IsSafeUnit(unit) then
        return Colors.White
    end

    local color
    local isPlayer = UnitIsPlayer(unit)
    local isAICompanion = UnitInPartyIsAI(unit)

    if isPlayer or isAICompanion then
        local _, class = UnitClass(unit)
        color = RAID_CLASS_COLORS[class]
    elseif UnitIsTapDenied(unit) then
        return Colors.LightGray
    else
        local reaction = UnitReaction(unit, "player")
        if P.IsSecret(reaction) or reaction == nil then
            color = Colors.White
        else
            color = FACTION_BAR_COLORS[reaction]
        end
    end

    return color or Colors.White
end

-- ==================== 单位工具 ====================

--- 获取鼠标悬停 / 当前目标的有效 unit token
function P.GetUnit(tooltip)

    local tooltipData = tooltip:GetPrimaryTooltipData()
    if P.IsSecret(tooltipData) then
        return
    end

    local guid = tooltipData and not P.IsSecret(tooltipData.guid) and tooltipData.guid

    local unit = nil
    if guid then 
        unit = guid and UnitTokenFromGUID(guid)
    end
    if not unit and UnitExists("mouseover") and not P.IsSecret("mouseover") then
        unit = "mouseover"
    end

    return unit, guid
end

-- ==================== 查找工具 ====================
function P.FindLine(tooltip, predicate)
    if not tooltip or not predicate then return nil end
    local numLines = tooltip:NumLines()
    for i = 1, numLines do
        local leftLine = _G[tooltip:GetName() .. "TextLeft" .. i]
        local rightLine = _G[tooltip:GetName() .. "TextRight" .. i]
        if leftLine and predicate(leftLine) then
            return leftLine, i
        end
        if rightLine and predicate(rightLine) then
            return rightLine, i
        end
    end
    return nil
    
end

-- ==================== 边框工具 ====================
-- 纹理渲染优化：关闭捕捉并设置偏置，防止手动对齐后依然发虚
local function SetPixelSnap(f)
    for _, region in ipairs({ f:GetRegions() }) do
        if region:IsObjectType("Texture") then
            region:SetSnapToPixelGrid(false)
            region:SetTexelSnappingBias(0)
        end
    end
end

local function GetBorderStyle(style)
    return style or (P.db and P.db.borderStyle) or "PIXEL"
end

local function GetBackdropStyle(style)
    style = GetBorderStyle(style)

    if style == "BLIZZARD" then
        return {
            bgFile = t.blank,
            edgeFile = t.defaultborder,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        }
    end

    return {
        bgFile = t.blank,
        edgeFile = t.blank,
        edgeSize = P.mult,
    }
end

local function CreateShadow(f, size)
    if f._tipsd then return end
    if not P.db.showShadow then
        return
    end

    local frame = f
    if f:IsObjectType("Texture") then frame = f:GetParent() end

    local shadow = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    shadow:SetFrameLevel(0)
    -- 手动像素偏移：4个物理像素
    shadow:SetPoint("TOPLEFT", frame, "TOPLEFT", -4, 4)
    shadow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 4, -4)
    shadow:SetBackdrop({
        edgeFile = t.shadow,
        edgeSize = 4,
    })
    shadow:SetBackdropBorderColor(0, 0, 0, 0.4)
    SetPixelSnap(shadow)

    f._tipsd = shadow
    return shadow
end

local function CreatePxBD(f, alpha, style)
    if f._pxbd then return end

    local frame = f
    if f:IsObjectType("Texture") then frame = f:GetParent() end
    local lvl = frame:GetFrameLevel()
    local pxbd = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    pxbd:SetPoint("TOPLEFT", frame, "TOPLEFT", -P.mult, P.mult)
    pxbd:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", P.mult, -P.mult)
    pxbd:SetFrameLevel(lvl == 0 and 0 or lvl - 1)
    P.CreateBackdrop(pxbd, alpha, style)

    f._pxbd = pxbd
    return pxbd
end

function P.CreatePxSBD(f, alpha, style)
    style = GetBorderStyle(style)

    local bg = CreatePxBD(f, alpha, style)
    if style == "PIXEL" then
        CreateShadow(bg)
    elseif bg and bg._tipsd then
        bg._tipsd:Hide()
    end

    return bg
end

function P.GetBorderBaseColor(style)
    if GetBorderStyle(style) == "BLIZZARD" then
        return 1, 1, 1, 1
    end

    return 0, 0, 0, 1
end

function P.ApplyBackdropStyle(f, style)
    style = GetBorderStyle(style)
    f:SetBackdrop(GetBackdropStyle(style))
    f._borderStyle = style

    -- 主提示框使用暴雪边框时隐藏像素阴影；像素边框时按设置显示
    if style == "PIXEL" and P.db.showShadow and not f._tipsd then
        CreateShadow(f)
    elseif f._tipsd then
        if style == "PIXEL" and P.db.showShadow then
            f._tipsd:Show()
        else
            f._tipsd:Hide()
        end
    end

    local r, g, b, a = P.GetBorderBaseColor(style)
    f:SetBackdropBorderColor(r, g, b, a)
    SetPixelSnap(f)
end

function P.UpdateBackdropColor(f, alpha)
    local colorHex = P.db.bgColor
    local color = CreateColorFromHexString(colorHex)

    f:SetBackdropColor(color.r, color.g, color.b, alpha or P.db.bgAlpha or 0.7)
end

function P.CreateBackdrop(f, alpha, style)
    P.ApplyBackdropStyle(f, style)
    P.UpdateBackdropColor(f, alpha)
end


local blizzTextures = {
    "Inset",
    "inset",
    "InsetFrame",
    "LeftInset",
    "RightInset",
    "NineSlice",
    "BG",
    "Bg",
    "border",
    "Border",
    "Background",
    "BorderFrame",
    "bottomInset",
    "BottomInset",
    "bgLeft",
    "bgRight",
    "FilligreeOverlay",
    "PortraitOverlay",
    "ArtOverlayFrame",
    "Portrait",
    "portrait",
    "ScrollFrameBorder",
    "ScrollUpBorder",
    "ScrollDownBorder"
}

function P.StripBlizzardTextures(frame)
    if not frame or not frame.GetNumRegions then return end
    local frameName = frame.GetName and frame:GetName()
    -- check for blizzTextures
    for _, texture in pairs(blizzTextures) do
        local blizzFrame = frame[texture] or (frameName and _G[frameName..texture])
        if blizzFrame then
            P.StripBlizzardTextures(blizzFrame)
        end
    end
    for i = 1, frame:GetNumRegions() do
        local region = select(i, frame:GetRegions())
        if region and region.GetObjectType and region:GetObjectType() == "Texture" then
            region:SetTexture("")
            region:SetAtlas("")
        end
    end
end

-- ==================== 调试工具 ====================

--- 调试输出
function P.Debug(...)
    if P.db and P.db.debug then
        print("|cff00eeff[CaiseTip]|r", ...)
    end
end
