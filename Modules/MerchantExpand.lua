-- JustinForge Module: Merchant Window Expand
-- Expands the merchant frame from 10 to 20 items per page

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local module = ns.Module:Register({
    key            = "merchantExpand",
    name           = L["MerchantExpand_Name"],
    description    = L["MerchantExpand_Desc"],
    defaultEnabled = true,
})

local initialized = false
local originalHeight
local originalItemsPerPage = 10

-- Number of columns per row in the default merchant layout
local NUM_COLS = 5

local function InitializeMerchantExpand()
    if initialized then return end
    if not MerchantFrame or not MerchantItem1 then return end

    -- Save original values for restoration
    originalHeight = MerchantFrame:GetHeight()
    if MERCHANT_ITEMS_PER_PAGE then
        originalItemsPerPage = MERCHANT_ITEMS_PER_PAGE
    end

    -- Read layout from existing buttons
    local b1 = MerchantItem1
    local point, relativeTo, relativePoint, x1, y1 = b1:GetPoint()

    -- Horizontal step: difference between button 1 and button 2
    local b2 = MerchantItem2
    local _, _, _, x2 = b2:GetPoint()
    local hStep = x2 - x1

    -- Vertical step: difference between button 1 and button 6 (first of second row)
    local b6 = MerchantItem6
    local _, _, _, _, y6 = b6:GetPoint()
    local vStep = y6 - y1

    -- Create extra buttons (11-20), extending in the original layout direction
    for i = 11, 20 do
        if not _G["MerchantItem" .. i] then
            local button = CreateFrame("Button", "MerchantItem" .. i, MerchantFrame, "MerchantItemTemplate", i)
            if button then
                local row = math.floor((i - 1) / NUM_COLS)
                local col = (i - 1) % NUM_COLS
                local x = x1 + col * hStep
                local y = y1 + row * vStep
                button:SetPoint(point, relativeTo, relativePoint, x, y)
                button:Hide()
            else
                Util:Debug("Failed to create MerchantItem" .. i)
            end
        end
    end

    -- Adjust frame height to accommodate 2 extra rows
    local extraRows = 2
    local extraHeight = extraRows * math.abs(vStep)
    MerchantFrame:SetHeight(originalHeight + extraHeight)

    -- Update items per page (Blizzard code will iterate up to this number)
    MERCHANT_ITEMS_PER_PAGE = 20

    initialized = true
    Util:Debug("MerchantExpand initialized: 20 items per page")
end

local function RestoreMerchantExpand()
    if not initialized then return end

    -- Hide extra buttons
    for i = 11, 20 do
        local button = _G["MerchantItem" .. i]
        if button then
            button:Hide()
        end
    end

    -- Restore frame height
    if originalHeight and MerchantFrame then
        MerchantFrame:SetHeight(originalHeight)
    end

    -- Restore items per page
    MERCHANT_ITEMS_PER_PAGE = originalItemsPerPage

    -- Refresh merchant display if open
    if MerchantFrame and MerchantFrame:IsShown() and MerchantFrame_Update then
        MerchantFrame_Update()
    end

    initialized = false
    Util:Debug("MerchantExpand restored: " .. originalItemsPerPage .. " items per page")
end

function module:OnEnable()
    InitializeMerchantExpand()
end

function module:OnDisable()
    RestoreMerchantExpand()
end
