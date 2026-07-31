-- JustinForge Core: Initialization
-- Creates the addon namespace, default config, and handles ADDON_LOADED

local addonName, ns = ...

ns.version = "1.0.0"
ns.debug = false

-- Default configuration
local defaults = {
    profile = {
        guildCloak     = { enabled = true },
        mapCenter      = { enabled = true },
        merchantExpand = { enabled = true },
    },
}

-- Recursively merge default values into DB (only fills missing keys)
local function mergeDefaults(db, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if db[k] == nil then
                db[k] = {}
            end
            if type(db[k]) == "table" then
                mergeDefaults(db[k], v)
            end
        else
            if db[k] == nil then
                db[k] = v
            end
        end
    end
end

-- Event frame for ADDON_LOADED
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(self, event, loadedAddon)
    if loadedAddon ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")

    -- Load SavedVariables
    if not JustinForgeDB then
        JustinForgeDB = {}
    end
    if not JustinForgeDB.profile then
        JustinForgeDB.profile = {}
    end
    mergeDefaults(JustinForgeDB, defaults)

    ns.db = JustinForgeDB

    -- Enable all modules based on saved state
    if ns.Module then
        ns.Module:EnableAll()
    end

    -- Initialize settings panel
    if ns.Config then
        ns.Config:Init()
    end
end)
