----------------------------------------------------------------------
-- CaiseTip / Modules / HealthBar
-- 生命条 + 血量文本
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

local strformat = string.format

local CreateColorFromHexString = CreateColorFromHexString

local isSecet = P.IsSecret
local safeUnit = P.IsSafeUnit
local font = P.font

-- 生命条框架

local function IsChineseLocale()
    local locale = GetLocale()
    return locale == "zhCN" or locale == "zhTW"
end

local function GetHealthNumberStyle()
    local style = P.db.healthNumberStyle or "AUTO"
    if style == "AUTO" then
        return IsChineseLocale() and "CN" or "INTL"
    end
    return style
end

local INTL_HEALTH_ABBREV_CONFIG = CreateAbbreviateConfig({
    { breakpoint = 10000000000, abbreviation = "B", significandDivisor = 1000000000, fractionDivisor = 1, abbreviationIsGlobal = false },
    { breakpoint = 1000000000, abbreviation = "B", significandDivisor = 100000000, fractionDivisor = 10, abbreviationIsGlobal = false },
    { breakpoint = 10000000, abbreviation = "M", significandDivisor = 1000000, fractionDivisor = 1, abbreviationIsGlobal = false },
    { breakpoint = 1000000, abbreviation = "M", significandDivisor = 100000, fractionDivisor = 10, abbreviationIsGlobal = false },
    { breakpoint = 10000, abbreviation = "K", significandDivisor = 1000, fractionDivisor = 1, abbreviationIsGlobal = false },
    { breakpoint = 1000, abbreviation = "K", significandDivisor = 100, fractionDivisor = 10, abbreviationIsGlobal = false },
})

local CN_HEALTH_ABBREV_CONFIG = CreateAbbreviateConfig({
    { breakpoint = 10000000000000, abbreviation = "万亿", significandDivisor = 1000000000000, fractionDivisor = 1, abbreviationIsGlobal = false },
    { breakpoint = 1000000000000, abbreviation = "万亿", significandDivisor = 100000000000, fractionDivisor = 10, abbreviationIsGlobal = false },
    { breakpoint = 1000000000, abbreviation = "亿", significandDivisor = 100000000, fractionDivisor = 1, abbreviationIsGlobal = false },
    { breakpoint = 100000000, abbreviation = "亿", significandDivisor = 10000000, fractionDivisor = 10, abbreviationIsGlobal = false },
    { breakpoint = 100000, abbreviation = "万", significandDivisor = 10000, fractionDivisor = 1, abbreviationIsGlobal = false },
    { breakpoint = 10000, abbreviation = "万", significandDivisor = 1000, fractionDivisor = 10, abbreviationIsGlobal = false },
})

local function GetHealthAbbrevConfig()
    if GetHealthNumberStyle() == "CN" then
        return CN_HEALTH_ABBREV_CONFIG
    end

    return INTL_HEALTH_ABBREV_CONFIG
end

local function FormatHealthNumber(value)

    return AbbreviateLargeNumbers(value, {
        config = GetHealthAbbrevConfig(),
    })
end

local function FormatHealthPercent(unit)
    if not unit then
        return 
    end

    local percent = UnitHealthPercent(unit, true, CurveConstants.ScaleTo100)

    return strformat("%d%%", percent)
end

local function BuildHealthText(unit, current, maximum)
    if not unit then
        return ""
    end

    local mode = P.db.healthTextMode
    local currentText = FormatHealthNumber(current)
    local maxText = FormatHealthNumber(maximum)
    local percentText = FormatHealthPercent(unit)

    if mode == "CURRENT" then
        return currentText
    elseif mode == "CURRENT_MAX" then
        return strformat("%s / %s", currentText, maxText)
    elseif mode == "PERCENT" then
        return percentText
    elseif mode == "CURRENT_PERCENT" then
        return strformat("%s / %s", currentText, percentText)
    end

    return strformat("%s / %s (%s)", currentText, maxText, percentText)
end

function P.OnUpdateUnitHealth(self)
    local text = self.HealthText
    if not text then return end

    if not P.db.showHealthBar or not P.db.showHealthText then
        text:SetText("")
        text:Hide()
        return
    end

    local parent = self:GetParent()
    if not parent then return end

    -- 使用插件统一的安全 unit 获取方法
    local unit = P.GetUnit(parent)
    if not unit or not UnitExists(unit) then
        text:SetText("")
        text:Hide()
        return
    end

    -- 获取当前生命值和最大生命值（在战斗或受限制环境下，为秘密值）
    local hp = UnitHealth(unit)
    local max = UnitHealthMax(unit)
    local displayText = BuildHealthText(unit, hp, max)

    text:SetText(displayText)
    text:Show()
end

function P.UpdateHealthBarColor(self)
    local unit = P.GetUnit(self)
    if not unit then
        return
    end
    local isSafeUnit = safeUnit(unit)
    local bar = self.StatusBar
    if bar then
        -- 锁定颜色防止被暴雪自带的 HealthBar_OnValueChanged 覆盖回绿色
        bar.lockColor = true

        local color
        if not isSafeUnit then
            color = CreateColorFromHexString(P.db.friendlyHealthColor)
        else
            color = P.GetUnitColor(unit)
        end
        if color then
            bar:SetStatusBarColor(color:GetRGB())
        end
    end
end
