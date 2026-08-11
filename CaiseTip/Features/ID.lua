----------------------------------------------------------------------
-- CaiseTip / Features / ID
-- 显示单位/物品/法术的 ID
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

local isSecret = P.IsSecret

local ITEMS = ITEMS
local SPELLS = SPELLS
local ID = ID

local idColor = "ff999999"
local typeStrings = {
    item = ("|c%s%s%s:|r"):format(idColor, ITEMS, ID),
    spell = ("|c%s%s%s:|r"):format(idColor, SPELLS, ID),
}

local function ShouldShowID()
    return P.db.showIDs
end

local function AddIDLine(tooltip, id, type)
    if not id or not ShouldShowID() then return end

    GameTooltip_AddBlankLineToTooltip(tooltip)
    tooltip:AddDoubleLine(type, ("|c%s%s|r"):format(idColor, id))
    tooltip:Show()
end

local function showID(tooltip, type, data)
    if tooltip:IsForbidden() then return end
    if not data or isSecret(data) then return end

    if data and data.id and not isSecret(data.id) then
        if type == "Item" then 
            AddIDLine(tooltip, data.id, typeStrings.item)
        elseif type == "Spell" or type == "UnitAura" then
            AddIDLine(tooltip, data.id, typeStrings.spell)
        end
    end
end

function P.ShowID()
    for k, v in pairs(Enum.TooltipDataType) do
        TooltipDataProcessor.AddTooltipPostCall(v, function(tooltip, data)
            showID(tooltip, k, data)
        end)
    end
end
