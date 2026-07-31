-- JustinForge Core: Module Registry
-- Provides Register / Enable / Disable / EnableAll / GetAll interfaces

local addonName, ns = ...

ns.Module = {}

local modules = {}
local order = {}

-- Register a new module
-- info fields: key, name, description, defaultEnabled, OnEnable, OnDisable
function ns.Module:Register(info)
    if not info or not info.key then
        error("Module:Register requires a 'key' field")
    end
    modules[info.key] = info
    table.insert(order, info.key)
    info.enabled = false
    return info
end

-- Enable a specific module by key
function ns.Module:Enable(key)
    local mod = modules[key]
    if not mod then return end
    if mod.enabled then return end
    mod.enabled = true
    if ns.db and ns.db.profile and ns.db.profile[key] then
        ns.db.profile[key].enabled = true
    end
    if mod.OnEnable then
        mod:OnEnable()
    end
    ns.Util:Debug("Module enabled: " .. key)
end

-- Disable a specific module by key
function ns.Module:Disable(key)
    local mod = modules[key]
    if not mod then return end
    if not mod.enabled then return end
    mod.enabled = false
    if ns.db and ns.db.profile and ns.db.profile[key] then
        ns.db.profile[key].enabled = false
    end
    if mod.OnDisable then
        mod:OnDisable()
    end
    ns.Util:Debug("Module disabled: " .. key)
end

-- Enable all modules based on saved DB state (called after ADDON_LOADED)
function ns.Module:EnableAll()
    for _, key in ipairs(order) do
        local mod = modules[key]
        local dbEntry = ns.db and ns.db.profile and ns.db.profile[key]
        if dbEntry and dbEntry.enabled then
            mod.enabled = true
            if mod.OnEnable then
                mod:OnEnable()
            end
            ns.Util:Debug("Module enabled: " .. key)
        else
            mod.enabled = false
        end
    end
end

-- Get all registered modules in registration order
function ns.Module:GetAll()
    local result = {}
    for _, key in ipairs(order) do
        table.insert(result, modules[key])
    end
    return result
end

-- Get a specific module by key
function ns.Module:Get(key)
    return modules[key]
end
