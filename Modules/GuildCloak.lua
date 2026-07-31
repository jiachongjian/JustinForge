-- JustinForge Module: Guild Cloak Auto-Restore
-- Detects when a guild cloak is equipped and restores the previous back item

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local INVSLOT_BACK = INVSLOT_BACK or 15

-- Guild cloak item IDs (provided by user)
-- Edit this table to add or remove cloak IDs
local GUILD_CLOAK_ITEM_IDS = {
    [65360] = true,
    [65274] = true,
    [63353] = true,
    [63206] = true,
    [63352] = true,
    [63207] = true,
}

local module = ns.Module:Register({
    key            = "guildCloak",
    name           = L["GuildCloak_Name"],
    description    = L["GuildCloak_Desc"],
    defaultEnabled = true,
})

local eventFrame
local previousBackLink
local isRestoring = false

local function GetBackItemID()
    return GetInventoryItemID("player", INVSLOT_BACK)
end

local function OnEquipmentChanged(_, equipmentSlot, hasCurrent)
    if equipmentSlot ~= INVSLOT_BACK then return end
    if isRestoring then return end

    -- Only process when an item is now in the slot
    if not hasCurrent then return end

    local currentID = GetBackItemID()
    if not currentID then return end

    if GUILD_CLOAK_ITEM_IDS[currentID] then
        -- Guild cloak detected, restore previous item
        if previousBackLink then
            isRestoring = true
            local linkToRestore = previousBackLink
            previousBackLink = nil
            C_Timer.After(0.5, function()
                if not module.enabled then
                    isRestoring = false
                    return
                end
                EquipItemByName(linkToRestore, INVSLOT_BACK)
                C_Timer.After(0.5, function()
                    isRestoring = false
                    -- Update tracking with restored item
                    local restoredID = GetBackItemID()
                    if restoredID and not GUILD_CLOAK_ITEM_IDS[restoredID] then
                        previousBackLink = GetInventoryItemLink("player", INVSLOT_BACK)
                    end
                end)
            end)
        end
    else
        -- Normal item equipped, update tracking
        previousBackLink = GetInventoryItemLink("player", INVSLOT_BACK)
    end
end

function module:OnEnable()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEquipmentChanged)
    end
    eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

    -- Initialize tracking with current back item
    local currentID = GetBackItemID()
    if currentID and not GUILD_CLOAK_ITEM_IDS[currentID] then
        previousBackLink = GetInventoryItemLink("player", INVSLOT_BACK)
    else
        previousBackLink = nil
    end
end

function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterEvent("PLAYER_EQUIPMENT_CHANGED")
    end
    previousBackLink = nil
    isRestoring = false
end
