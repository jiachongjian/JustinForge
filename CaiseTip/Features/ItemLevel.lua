----------------------------------------------------------------------
-- CaiseTip / Modules / ItemLevel
-- 装等（数据获取与缓存）
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

local GetAverageItemLevel = GetAverageItemLevel
local GetTime = GetTime
local CanInspect = CanInspect
local NotifyInspect = NotifyInspect
local ClearInspectPlayer = ClearInspectPlayer
local InCombatLockdown = InCombatLockdown
local UnitExists = UnitExists
local UnitIsPlayer = UnitIsPlayer
local UnitIsUnit = UnitIsUnit
local UnitTokenFromGUID = UnitTokenFromGUID
local C_PaperDollInfo = C_PaperDollInfo
local C_Timer = C_Timer
local strformat = string.format

local isSecret = P.IsSecret

local LOADING = LFG_LIST_LOADING
local NOT_LEVEL = UNIT_LETHAL_LEVEL_TEMPLATE

local CACHE_TTL = 120
local RECHECK_DELAY = 0.5
local INSPECT_TIMEOUT = 2

local cache = {}
local inspectTimeoutTimers = {}

local lastRequestedGUID = nil
local lastRequestTime = 0
local isInspecting = false
local isBlizzardInspecting = false
local isInternalNotify = false

local recheckTimer = nil

--[[
    按 12.1 (Midnight Season 2) 实际平均装等进行分档着色。
    阈值 = 各档 1/6 起点 + 5：
      Mythic 318 -> 323 (橙)
      Hero    305 -> 310 (紫)
      Champion 292 -> 297 (蓝)
      Veteran 279 -> 284 (绿)
    这里不区分装备来源或升级潜力，只看 tooltip 当前展示的平均装等数值。
]]
local function getItemLevelColor(value)
    if value >= 323 then
        return P.db.itemLevelColorOrange
    end

    if value >= 310 then
        return P.db.itemLevelColorPurple
    end

    if value >= 297 then
        return P.db.itemLevelColorBlue
    end

    if value >= 284 then
        return P.db.itemLevelColorGreen
    end

    return P.db.itemLevelColorLow
end

local function formatItemLevel(value)
    if not value or value <= 0 or isSecret(value) then
        return nil
    end

    return strformat("|c%s%.1f|r", getItemLevelColor(value), value)
end

local function setTooltipItemLevelLine(tooltip, itemLevel)
    if not tooltip or not tooltip.GetName then
        return
    end

    local formatted = formatItemLevel(itemLevel)
    if not formatted then
        formatted = "|cffffcc99" .. LOADING .. "|r"
    end

    local text = strformat("%s%s", L["装等："], formatted)
    local tooltipName = tooltip:GetName()

    for i = 1, tooltip:NumLines() do
        local line = _G[tooltipName .. "TextLeft" .. i]
        local lineText = line and line.GetText and line:GetText()
        if lineText and not isSecret(lineText) and lineText:find(L["装等："], 1, true) then
            line:SetText(text)
            return
        end
    end

    tooltip:AddLine(text)
end

local function cancelRecheckTimer()
    if recheckTimer then
        recheckTimer:Cancel()
        recheckTimer = nil
    end
end

local function cancelInspectTimeout(guid)
    local timer = guid and inspectTimeoutTimers[guid]
    if timer then
        timer:Cancel()
        inspectTimeoutTimers[guid] = nil
    end
end

local function showItemLevelNA(tooltip)
    if not tooltip or not tooltip.GetName then
        return
    end

    local naFormatted = "|cff9d9d9d" .. NOT_LEVEL .."|r"
    local text = strformat("%s%s", L["装等："], naFormatted)
    local tooltipName = tooltip:GetName()

    for i = 1, tooltip:NumLines() do
        local line = _G[tooltipName .. "TextLeft" .. i]
        local lineText = line and line.GetText and line:GetText()
        if lineText and not isSecret(lineText) and lineText:find(L["装等："], 1, true) then
            line:SetText(text)
            return
        end
    end
end

local function getCachedItemLevel(guid)
    local data = guid and cache[guid]
    if not data then
        return nil
    end

    if GetTime() - data.timestamp > CACHE_TTL then
        cache[guid] = nil
        return nil
    end

    return data.itemLevel
end

local function setCachedItemLevel(guid, itemLevel)
    if not guid or isSecret(guid) or not itemLevel or itemLevel <= 0 or isSecret(itemLevel) then
        return
    end

    cache[guid] = {
        itemLevel = itemLevel,
        timestamp = GetTime(),
    }
end

local function shouldShowItemLevel()
    return P.db.showItemLevel
end

local function getPlayerItemLevel()
    local _, equipped = GetAverageItemLevel()
    if equipped and equipped > 0 and not isSecret(equipped) then
        return equipped
    end

    return nil
end

local function canStartInspect(unit, guid)
    if not unit or not guid then
        return false
    end

    if isSecret(unit) or isSecret(guid) then
        return false
    end

    if InCombatLockdown() or not UnitExists(unit) or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then
        return false
    end

    if isInspecting or isBlizzardInspecting then
        return false
    end

    local ok, canInspect = pcall(CanInspect, unit)
    if not ok or isSecret(canInspect) or not canInspect then
        return false
    end

    return true
end

local function stopInspectRequest(releaseChannel)
    cancelRecheckTimer()

    if releaseChannel and isInspecting then
        ClearInspectPlayer()
    end

    isInspecting = false
    lastRequestedGUID = nil
end

local function startInspectRequest(tooltip, unit, guid)
    if not canStartInspect(unit, guid) then
        return false
    end

    if getCachedItemLevel(guid) then
        return false
    end

    lastRequestedGUID = guid
    lastRequestTime = GetTime()
    isInspecting = true
    isInternalNotify = true

    NotifyInspect(unit)
    --setTooltipItemLevelLine(tooltip, nil)
    return true
end

local function asyncCheckInspect(tooltip, unit, guid)
    stopInspectRequest(true)

    if tooltip ~= GameTooltip then
        return
    end

    cancelRecheckTimer()
    recheckTimer = C_Timer.NewTimer(RECHECK_DELAY, function()
        recheckTimer = nil

        if not GameTooltip:IsShown() then
            return
        end

        local curUnit, curGUID = P.GetUnit(GameTooltip)
        if not curUnit or not curGUID or isSecret(curUnit) or isSecret(curGUID) then
            return
        end

        if curGUID ~= guid then
            return
        end

        startInspectRequest(GameTooltip, curUnit, curGUID)
    end)
end

local function tryRefreshCurrentTooltip(guid, itemLevel)
    if not GameTooltip:IsShown() then
        return
    end

    local _, currentGUID = P.GetUnit(GameTooltip)
    if not currentGUID or isSecret(currentGUID) then
        return
    end

    if currentGUID ~= guid then
        return
    end

    setTooltipItemLevelLine(GameTooltip, itemLevel)
end

local function onInspectReady(guid)
    if not isInspecting then
        return
    end

    if not guid or isSecret(guid) then
        stopInspectRequest(true)
        return
    end

    if guid ~= lastRequestedGUID then
        stopInspectRequest(true)
        return
    end

    local unit = UnitTokenFromGUID(guid)
    if unit and not isSecret(unit) and UnitExists(unit) then
        local itemLevel = C_PaperDollInfo.GetInspectItemLevel(unit)
        if itemLevel and itemLevel > 0 and not isSecret(itemLevel) then
            cancelInspectTimeout(guid)
            setCachedItemLevel(guid, itemLevel)
            tryRefreshCurrentTooltip(guid, itemLevel)
        end
    end

    stopInspectRequest(true)
end

hooksecurefunc("NotifyInspect", function()
    if isInternalNotify then
        isInternalNotify = false
        return
    end

    isBlizzardInspecting = true
    stopInspectRequest(false)
end)

hooksecurefunc("InspectUnit", function()
    isBlizzardInspecting = true
    stopInspectRequest(false)
end)

hooksecurefunc("ClearInspectPlayer", function()
    isBlizzardInspecting = false
    isInspecting = false
    lastRequestedGUID = nil
    isInternalNotify = false
end)

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("INSPECT_READY")
eventFrame:SetScript("OnEvent", function(_, _, guid)
    onInspectReady(guid)
end)

function P.ShowItemLevel(tooltip, unit)
    if not shouldShowItemLevel() or not tooltip or not unit then
        return
    end

    if isSecret(unit) or not UnitIsPlayer(unit) then
        return
    end

    if UnitIsUnit(unit, "player") then
        local itemLevel = getPlayerItemLevel()
        if itemLevel then
            setTooltipItemLevelLine(tooltip, itemLevel)
        end
        return
    end

    local _, guid = P.GetUnit(tooltip)
    if not guid or isSecret(guid) then
        return
    end

    local cachedItemLevel = getCachedItemLevel(guid)
    if cachedItemLevel then
        cancelInspectTimeout(guid)
        setTooltipItemLevelLine(tooltip, cachedItemLevel)
        return
    end
    setTooltipItemLevelLine(tooltip, nil)

    cancelInspectTimeout(guid)
    inspectTimeoutTimers[guid] = C_Timer.NewTimer(INSPECT_TIMEOUT, function()
        inspectTimeoutTimers[guid] = nil
        if not GameTooltip:IsShown() then
            return
        end
        local _, currentGUID = P.GetUnit(GameTooltip)
        if currentGUID ~= guid then
            return
        end
        showItemLevelNA(GameTooltip)
    end)

    asyncCheckInspect(tooltip, unit, guid)
end

function P.ClearPendingItemLevel()
    cancelRecheckTimer()
    stopInspectRequest(false)
    for guid, timer in pairs(inspectTimeoutTimers) do
        timer:Cancel()
        inspectTimeoutTimers[guid] = nil
    end
end
