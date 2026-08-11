----------------------------------------------------------------------
-- CaiseTip / Features / Iteminfo
-- 显示物品堆叠数量、当前持有数量和最大堆叠上限（含银行）
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

-- WoW global API
local select = select
local ItemCount = C_Item.GetItemCount
local ItemInfo = C_Item.GetItemInfo

local BAGSLOT = BAGSLOT
local BANK = BANK
local VERSION = GAME .. GAME_VERSION_LABEL

local isSecret = P.IsSecret


local function AddItemInfoLine(tooltip, data)
    if not P.db.showItemInfo then return end

    if not tooltip or tooltip:IsForbidden() then
        return
    end
    
    if not data or isSecret(data) then return end

    local itemID = data.id
    if not itemID or isSecret(itemID) then return end

    local bagCount = ItemCount(itemID)
    local bankCount = ItemCount(itemID, true, nil, true, true) - bagCount
    local itemStackCount = select(8, ItemInfo(itemID))
    local expacID = select(15, ItemInfo(itemID))

    if bagCount <= 0 and bankCount <= 0 then return end

    if bankCount > 0 then
        tooltip:AddDoubleLine(BAGSLOT .. "/" .. BANK .. ":", bagCount .. "/" .. bankCount, 0.5, 0.8, 1, 1, 1, 1)
    elseif bagCount > 1 then
        tooltip:AddDoubleLine(BAGSLOT .. ":", bagCount, 0.5, 0.8, 1, 1, 1, 1)
    end

    if itemStackCount and itemStackCount > 1 then
        tooltip:AddDoubleLine(L["堆叠上限"] .. ":", itemStackCount, 0.5, 0.8, 1, 1, 1, 1)
    end

    if expacID ~= nil then
        local versionName = _G["EXPANSION_NAME" .. expacID]
        if versionName and versionName ~= "" then
            tooltip:AddDoubleLine(VERSION .. ":", versionName, 0.5, 0.8, 1, 1, 1, 1)
        end
    end
end

function P.ShowItemInfo()

    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, AddItemInfoLine)
end
