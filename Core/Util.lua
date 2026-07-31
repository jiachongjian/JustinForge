-- JustinForge Core: Utilities
-- Shared helper functions used across modules

local addonName, ns = ...

ns.Util = {}

-- Print a message with addon prefix
function ns.Util:Print(msg)
    print("|cFF4FC3F7[JustinForge]|r " .. tostring(msg))
end

-- Print a debug message (only if debug mode is on)
function ns.Util:Debug(msg)
    if ns.debug then
        print("|cFF888888[JustinForge Debug]|r " .. tostring(msg))
    end
end

-- Extract item ID from an item link
function ns.Util.GetItemIDFromLink(link)
    if not link then return nil end
    local itemID = link:match("item:(%d+)")
    return itemID and tonumber(itemID)
end
