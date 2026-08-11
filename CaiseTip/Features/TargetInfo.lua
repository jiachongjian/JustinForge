----------------------------------------------------------------------
-- CaiseTip / Modules / TargetInfo
-- 目标的目标显示
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

local strformat = string.format

local isSecret = P.IsSecret
local safeUnit = P.IsSafeUnit
local Colors = P.Colors

-- 鼠标提示目标的目标职业染色
-- FreebTip
local function GetTarget(unit)
    if not safeUnit(unit) then return end

    local isMe = UnitIsUnit(unit, "player")

    if not isSecret(isMe) and isMe then
        return Colors.Red:WrapTextInColorCode(strformat(">>%s<<", strupper(YOU)))
    else
        local color = P.GetUnitColor(unit)
        return color:WrapTextInColorCode(UnitName(unit))
    end
end

function P.ShowTarget(self, unit)
    if (UnitExists(unit .. "target")) then
        local tarRicon = GetRaidTargetIndex(unit .. "target")
        local tar = GetTarget(unit .. "target")
        if not isSecret(tarRicon) and tarRicon then
            tar = strformat("%s %s", (ICON_LIST[tarRicon] .. "10|t") or "", tar)
        end
        local tarColor = P.GetUnitColor(unit .. "target")

        GameTooltip_AddBlankLineToTooltip(self)
        GameTooltip_AddColoredDoubleLine(self, TARGET, tar, NORMAL_FONT_COLOR, tarColor)
    end
end