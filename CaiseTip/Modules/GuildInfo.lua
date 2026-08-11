----------------------------------------------------------------------
-- CaiseTip / Modules / GuildInfo
-- 公会名/会阶（含缩写逻辑）
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

-- Lua standard library
local strbyte = string.byte
local strgmatch = string.gmatch
local tconcat = table.concat
local tinsert = table.insert
local strformat = string.format

-- WoW global API
local GetGuildInfo = GetGuildInfo
local GetLocale = GetLocale
local IsInGuild = IsInGuild
local IsShiftKeyDown = IsShiftKeyDown
local UnitIsUnit = UnitIsUnit
local WrapTextInColorCode = WrapTextInColorCode
local strlenutf8 = strlenutf8

local isSecret = P.IsSecret
local Colors = P.Colors


local function Utf8Truncate(text, maxChars)
    local chars = {}
    local count = 0
    for char in strgmatch(text, "[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > maxChars then break end
        tinsert(chars, char)
    end
    return tconcat(chars, "")
end


local function Abbreviate(text, maxLen)
    if not text then return end
    local len = strlenutf8(text)
    if len > maxLen then
        return Utf8Truncate(text, maxLen) .. "..."
    end
    return text
end

local function HasChinese(text)
    for char in strgmatch(text, "[%z\1-\127\194-\244][\128-\191]*") do
        local byte = strbyte(char, 1)
        if byte >= 0xE4 and byte <= 0xE9 then
            return true
        end
    end
    return false
end

local function GetGuildMaxLen(text)
    local customLen

    -- 自动检测
    local locale = GetLocale()
    if locale == "zhCN" or locale == "zhTW" then
        if HasChinese(text) then
            customLen = 8 -- 中文环境（含中文字符）
        else
            customLen = 30 -- 中文环境（不含中文字符）
        end
    elseif locale == "koKR" then
        customLen = 10  -- 韩文环境（字符更宽）
    elseif locale == "ruRU" then
        customLen = 25 -- 俄文环境
    else
        customLen = 30 -- 英文及其他欧洲语言
    end
    return customLen
end

-- 检查是否应该展示公会全名
local function ShouldShowFullGuild()
    if not P.db.showFullGuildWithModifier then return false end

    local mod = P.db.guildModifier
    if mod == "CTRL" then return IsControlKeyDown() end
    if mod == "ALT" then return IsAltKeyDown() end
    if mod == "SHIFT" then return IsShiftKeyDown() end
    return false
end

local function GetGuildName(unit, guildName, guildRankName, guildRealm, guildRankIndex)

    -- 匹配逻辑
    local myGuildName, _, _, myGuildRealm = GetGuildInfo("player")
    local isMyGuild = IsInGuild() and (guildName == myGuildName) and (guildRealm == myGuildRealm)
    local isMe = UnitIsUnit(unit, "player")

    -- 选取颜色
    local guildHex = (isMyGuild and not isMe) and Colors.MyGuild or Colors.OtherGuild

    -- 拼接显示文本 (处理 10 字缩写逻辑)

    local maxLen = GetGuildMaxLen(guildName)
    local displayText
    if ShouldShowFullGuild() then
        displayText = guildName  -- 按了修饰键，显示全名
    else
        displayText = Abbreviate(guildName, maxLen)  -- 没按，缩写
    end

    if P.db.showGuildRealm and guildRealm and guildRealm ~= "" then
        displayText = displayText .. Colors.LightGray:WrapTextInColorCode("-" .. guildRealm)
    end

    local guildText = guildHex:WrapTextInColorCode(strformat("<%s>", displayText))

    if P.db.showRank and guildRankName then
        local rankText = guildRankName
        if P.db.showRankIndex then
            rankText = strformat("%s (%d)", guildRankName, guildRankIndex)
        end
        guildText = strformat("%s %s", guildText, Colors.LightGray:WrapTextInColorCode(rankText))
    end

    return guildText
end


function P.GuildLine(tooltip, unit)
    if not P.db.showGuild then return end

    local guildName, guildRankName, guildRankIndex, guildRealm = GetGuildInfo(unit)
    if isSecret(guildName) or not guildName then return end

    -- 找到第 2 行（第 1 行玩家名，第 2 行公会行）
    local guildLine = _G[tooltip:GetName() .. "TextLeft2"]
    if isSecret(guildLine) or not guildLine then return end

    -- GetGuildName 已包含：缩写 + 颜色 + 会阶 + 服务器
    local guildText = GetGuildName(unit, guildName, guildRankName, guildRealm, guildRankIndex)
    if guildText and not isSecret(guildText) and guildText ~= "" then
        guildLine:SetText(guildText)
    end
end
