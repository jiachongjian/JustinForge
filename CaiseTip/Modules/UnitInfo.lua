----------------------------------------------------------------------
-- CaiseTip / Modules / UnitInfo
-- 等级/种族/职业/专精/阵营
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

local strformat = string.format

local GetCreatureDifficultyColor = GetCreatureDifficultyColor
local RGBToColorCode = RGBToColorCode
local WrapTextInColorCode = WrapTextInColorCode
local UnitBattlePetLevel = UnitBattlePetLevel
local UnitIsBattlePetCompanion = UnitIsBattlePetCompanion
local UnitIsWildBattlePet = UnitIsWildBattlePet
local UnitLevel = UnitLevel

local isSecret = P.IsSecret
local Colors = P.Colors

local bosslvl = Colors.Red:WrapTextInColorCode("??")

local function GetLevel(unit)
    local lvl
    if UnitIsWildBattlePet(unit) or UnitIsBattlePetCompanion(unit) then
        lvl = UnitBattlePetLevel(unit)
    else
        lvl = UnitLevel(unit)
    end

    if not lvl or isSecret(lvl) then return end

    -- 等级显示与染色
    local levelText
    if lvl == -1 then
        levelText = bosslvl
    else
        local diffColor = GetCreatureDifficultyColor(lvl)
        levelText = strformat("%s%d|r", RGBToColorCode(diffColor.r, diffColor.g, diffColor.b), lvl)
    end
    return levelText
end

local classification = {
    elite = ("|cffFFCC00 %s|r"):format(ELITE),
    rare = ("|cffCC00FF %s|r"):format(MAP_LEGEND_RARE),
    rareelite = ("|cffCC00FF %s|r"):format(MAP_LEGEND_RAREELITE),
    worldboss = ("|cffFF0000?? %s|r"):format(BOSS)
}

local function GetClassification(unit)
    local text
    -- 精英/稀有后缀
    local classify = UnitClassification(unit)
    if not isSecret(classify) then
        text = classification[classify]
    end
    return text
end

local function GetRace(unit)
    local text
    -- 阵营颜色
    local factionGroup = UnitFactionGroup(unit)
    local raceHex = Colors.White
    if not isSecret(factionGroup) then
        if factionGroup == "Alliance" then
            raceHex = Colors.Alliance
        elseif factionGroup == "Horde" then
            raceHex = Colors.Horde
        end
    end

    -- 种族/生物类型 按照阵营染色
    local race = UnitRace(unit)
    local creatureType = UnitCreatureType(unit)
    if race and not isSecret(race) and race ~= "" then
        text = raceHex:WrapTextInColorCode(race)
    elseif creatureType and not isSecret(creatureType) and creatureType ~= "" then
        text = creatureType
    end
    return text
end

local function GetClass(unit, isPlayer)
    local text
    if isPlayer then
        local localizedClass, englishClass = UnitClass(unit)
        if englishClass and not isSecret(englishClass) and localizedClass and not isSecret(localizedClass) then
            local classColor = RAID_CLASS_COLORS[englishClass]
            if classColor then
                text = classColor:WrapTextInColorCode(localizedClass)
            end
        end
    end
    return text
end

function P.LevelLine(tooltip, unit, isPlayer)
    local levelText = GetLevel(unit)
    local classificationText = GetClassification(unit)
    local raceText = GetRace(unit)
    local classText = GetClass(unit, isPlayer)

    for i = 2, tooltip:NumLines() do
        local line = _G[tooltip:GetName() .. "TextLeft" .. i]
        local text = line:GetText()
        if text and not isSecret(text) and text:find(LEVEL) then
            P._levelLineIndex = i
            
            -- 找到第一个非空行，设置等级/种族/职业信息
            line:SetText(strformat("%s%s %s %s", levelText or "", classificationText or "", raceText or "", classText or ""))
        end
    end
end
