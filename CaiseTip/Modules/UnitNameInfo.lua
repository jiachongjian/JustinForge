----------------------------------------------------------------------
-- CaiseTip / Modules / UnitNameInfo
-- 单位名称
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

-- Lua standard library
local type = type
local strformat = string.format

-- WoW global API
local UnitIsAFK = UnitIsAFK
local UnitIsConnected = UnitIsConnected
local UnitIsDND = UnitIsDND
local UnitName = UnitName
local UnitPVPName = UnitPVPName
local UnitRealmRelationship = UnitRealmRelationship

local isSecret = P.IsSecret
local safeUnit = P.IsSafeUnit

local AFK = AFK
local DND = DND
local PLAYER_OFFLINE = PLAYER_OFFLINE
local ERR_UNIT_NOT_FOUND = ERR_UNIT_NOT_FOUND

local function GetUnitName(unit)

    local name, server = UnitName(unit)
    local pvpname = UnitPVPName(unit)
    local relationship = UnitRealmRelationship(unit)

    if isSecret(name) or not name or type(name) ~= "string" or name == "" then return ERR_UNIT_NOT_FOUND end

    if P.db.showTitle then
        if pvpname and not isSecret(pvpname) and pvpname ~= "" then
            name = pvpname
        end
    end

    if server and not isSecret(server) and server ~= "" then
        if P.db.showServer then
            name = strformat("%s-%s", name, server)
        elseif relationship == LE_REALM_RELATION_COALESCED then
            name = strformat("%s%s", name, FOREIGN_SERVER_LABEL)
        elseif relationship == LE_REALM_RELATION_VIRTUAL then
            name = strformat("%s%s", name, INTERACTIVE_SERVER_LABEL)
        end
    end

    local status
    if not isSecret(UnitIsAFK(unit)) and UnitIsAFK(unit) then
        status = AFK
    end
    if not isSecret(UnitIsDND(unit)) and UnitIsDND(unit) then
        status = DND
    end
    if not isSecret(UnitIsConnected(unit)) and not UnitIsConnected(unit) then
        status = PLAYER_OFFLINE
    end

    if status then
        name = strformat("%s |cff00cc00<%s>|r", name, status)
    end

    return name
end

function P.NameLine(tooltip, lineData)
    local unit = lineData.unitToken
    if not safeUnit(unit) then return end

    lineData.leftText = GetUnitName(unit)
    lineData.leftColor = P.GetUnitColor(unit)
end


