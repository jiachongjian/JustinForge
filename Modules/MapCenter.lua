-- JustinForge Module: Map Window Center
-- Centers the world map window on screen each time it opens

local addonName, ns = ...

local L = ns.L

local module = ns.Module:Register({
    key            = "mapCenter",
    name           = L["MapCenter_Name"],
    description    = L["MapCenter_Desc"],
    defaultEnabled = true,
})

local hooked = false

function module:OnEnable()
    if not hooked and WorldMapFrame then
        hooked = true
        WorldMapFrame:HookScript("OnShow", function(self)
            if not module.enabled then return end
            -- Only center in non-maximized (small) mode
            local isMaximized = self.IsMaximized and self:IsMaximized()
            if not isMaximized then
                self:ClearAllPoints()
                self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            end
        end)
    end
end

function module:OnDisable()
    -- HookScript cannot be undone; the enabled flag check in the hook
    -- makes it a no-op when the module is disabled (zero effective overhead).
end
