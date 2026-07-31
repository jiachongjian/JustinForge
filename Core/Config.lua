-- JustinForge Core: Settings Panel
-- Registers a native settings category with a checkbox for each module

local addonName, ns = ...

ns.Config = {}

function ns.Config:Init()
    if not Settings or not Settings.RegisterCanvasLayoutCategory then
        ns.Util:Debug("Settings API not available")
        return
    end

    local ok, err = pcall(function()
        local title = ns.L["AddonTitle"]
        local category = Settings.RegisterCanvasLayoutCategory(title, title)

        for _, mod in ipairs(ns.Module:GetAll()) do
            local dbEntry = ns.db.profile[mod.key]

            local setting = Settings.RegisterAddOnSetting(
                category,
                mod.key,
                mod.key,
                addonName,
                dbEntry,
                "enabled",
                Settings.CreateCheckbox(mod.name, mod.description)
            )

            setting:SetValueChangedCallback(function(_, value)
                if value then
                    ns.Module:Enable(mod.key)
                else
                    ns.Module:Disable(mod.key)
                end
            end)
        end

        Settings.RegisterAddOnCategory(category)
    end)

    if not ok then
        ns.Util:Debug("Config init failed: " .. tostring(err))
    end
end
