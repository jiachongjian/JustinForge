----------------------------------------------------------------------
-- CaiseTip / Modules / SpecInfo
-- 专精信息显示
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

local isSecret = P.IsSecret

local function IsDataSafe()
    if GameTooltip:IsForbidden() or not GameTooltip:IsShown() then
        return false
    end

    local data = GameTooltip:GetPrimaryTooltipData()
    if not data or isSecret(data) then
        return false
    end

    if not data.type or isSecret(data.type) then
        return false
    end

    -- 只允许普通单位 tooltip 刷新
    if data.type ~= Enum.TooltipDataType.Unit then
        return false
    end

    local unit = P.GetUnit(GameTooltip)
    if not unit or type(unit) ~= "string" or unit == "" then
        return false
    end

    if isSecret(unit) or not UnitExists(unit) then
        return false
    end

    if C_Secrets and C_Secrets.ShouldUnitIdentityBeSecret(unit) then
        return false
    end

    if not data.lines or type(data.lines) ~= "table" or isSecret(data.lines) then
        return false
    end

    for _, line in ipairs(data.lines) do
        if isSecret(line) then
            return false
        end

        if line.type and isSecret(line.type) then
            return false
        end

        if (line.leftText and isSecret(line.leftText)) or (line.rightText and isSecret(line.rightText)) then
            return false
        end

        if (line.leftColor and isSecret(line.leftColor)) or (line.rightColor and isSecret(line.rightColor)) then
            return false
        end
    end

    return true
end

local function RefreshStates(keyCode, keyName, state)
    if GameTooltip:IsForbidden() or not GameTooltip:IsShown() then return end
    if not keyName:find("SHIFT") and not keyName:find("CTRL") and not keyName:find("ALT") then return end

    if IsDataSafe() then
        GameTooltip:RefreshData()
    end
end

EventRegistry:RegisterFrameEventAndCallback("MODIFIER_STATE_CHANGED", RefreshStates)