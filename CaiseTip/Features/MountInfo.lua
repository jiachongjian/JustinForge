----------------------------------------------------------------------
-- CaiseTip / Modules / MountInfo
-- 坐骑检测（检测悬停目标是否为坐骑）
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

local string_format = string.format

local GetAuraDataByIndex = C_UnitAuras.GetAuraDataByIndex
local GetMountFromSpell = C_MountJournal.GetMountFromSpell
local GetMountInfoByID = C_MountJournal.GetMountInfoByID
local GetMountInfoExtraByID = C_MountJournal.GetMountInfoExtraByID

local isSecret = P.IsSecret
local safeUnit = P.IsSafeUnit

local function GetUnitMount(unit)
    if not safeUnit(unit) then return end

    local i = 1
    while true do
        local aura = GetAuraDataByIndex(unit, i, "HELPFUL")
        if isSecret(aura) or not aura then return end

        -- C_MountJournal.GetMountFromSpell 返回 mountID
        local mountID = aura.spellId and not isSecret(aura.spellId) and GetMountFromSpell(aura.spellId)
        if mountID then
            local name, _, _, _, _, _, _, _, _, _, isCollected = GetMountInfoByID(mountID)
            return name, isCollected, mountID
        end
        i = i + 1
    end
end

local function GetMountCollectionText(isCollected)
    if isCollected == nil then
        return nil
    end

    if isCollected then
        return string_format("|cff00ff00【%s】|r", L["已收集"])
    end

    return string_format("|cffff0000【%s】|r", L["未收集"])
end

function P.ShowMount(tooltip, unit)
    if not P.db.showMount then return end
    local mountName, isCollected, mountID = GetUnitMount(unit)
    if mountID then
        local _, _, source = GetMountInfoExtraByID(mountID)
        if mountName then
            local collectText = GetMountCollectionText(isCollected)
            local mountText = "|cffffffff" .. mountName .. "|r"
            if collectText then
                mountText = string_format("%s %s", mountText, collectText)
            end

            GameTooltip_AddBlankLineToTooltip(tooltip)
            tooltip:AddDoubleLine(MOUNTS, mountText)

            if P.db.showMountSource and source and source ~= "" then
                tooltip:AddLine(source:gsub("|n%s*|n$", ""), 1,1,1)
            end
        end
    end
end


