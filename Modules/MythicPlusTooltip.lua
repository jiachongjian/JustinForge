-- ============================================================
-- JustinForge 模块11: 鼠标提示大秘境信息 (MythicPlusTooltip.lua)
-- ============================================================
-- 功能描述：
--   鼠标指向满级玩家时，在提示框中追加显示：
--     1. 本赛季大秘境总评分（按分数段着色）
--     2. 当前持有的钥石（副本名 + 等级，按钥石等级着色）
--     3. 本赛季每个大秘境的最佳通关层数与分数
--        （限时完成按剩余时间阈值标注 +3/+2/+1，超时显示灰色）
--
-- 数据来源：
--   - 评分与各副本最佳成绩：C_PlayerInfo.GetPlayerMythicPlusRatingSummary(unit)
--     原生 API 直接支持任意玩家单位，无需观察/检查，无 ElvUI 依赖
--   - 副本名与限时阈值：C_ChallengeMode.GetMapUIInfo 动态获取，随赛季自动更新
--   - 自身钥石：C_MythicPlus.GetOwnedKeystone* 直接读取
--   - 其他玩家钥石：通过 LibKeystone 兼容协议（前缀 LibKS）在队伍/公会
--     频道交换，与 BigWigs / ElvUI+WindTools 用户互通；
--     若本机存在内嵌 LibOpenRaid 的插件（如 Details），也会尝试读取其缓存
--   （实现逻辑参考 ElvUI_WindTools 的 Tooltips/Progression、Keystone
--     与 Core/KeystoneInfo，已去除全部 ElvUI 依赖）
--
-- 实现原理：
--   1. TooltipDataProcessor.AddTooltipPostCall(Unit) 回调中取鼠标单位，
--      按 GUID 缓存评分数据 60 秒，避免重复计算
--   2. LibKS 协议：发送/应答 "R" 请求，接收 "等级,副本ID,评分" 数据，
--      按发送者名字缓存；3 秒节流防止刷屏
--   3. 提示回调与 hook 无法卸载，禁用时通过模块开关短路返回；
--      通讯事件全部注销，实现零开销
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local format = format
local ipairs = ipairs
local pairs = pairs
local sort = table.sort
local strmatch = strmatch
local strrep = strrep
local time = time
local tinsert = tinsert
local tonumber = tonumber
local tostring = tostring

local Ambiguate = Ambiguate
local GetTime = GetTime
local GetUnitName = GetUnitName
local IsInGroup = IsInGroup
local IsInGuild = IsInGuild
local UnitGUID = UnitGUID
local UnitIsPlayer = UnitIsPlayer
local UnitIsUnit = UnitIsUnit
local UnitLevel = UnitLevel

local C_ChallengeMode_GetDungeonScoreRarityColor = C_ChallengeMode.GetDungeonScoreRarityColor
local C_ChallengeMode_GetKeystoneLevelRarityColor = C_ChallengeMode.GetKeystoneLevelRarityColor
local C_ChallengeMode_GetMapTable = C_ChallengeMode.GetMapTable
local C_ChallengeMode_GetMapUIInfo = C_ChallengeMode.GetMapUIInfo
local C_ChallengeMode_GetSpecificDungeonOverallScoreRarityColor = C_ChallengeMode.GetSpecificDungeonOverallScoreRarityColor
local C_ChatInfo_RegisterAddonMessagePrefix = C_ChatInfo.RegisterAddonMessagePrefix
local C_ChatInfo_SendAddonMessage = C_ChatInfo.SendAddonMessage
local C_MythicPlus_GetOwnedKeystoneChallengeMapID = C_MythicPlus.GetOwnedKeystoneChallengeMapID
local C_MythicPlus_GetOwnedKeystoneLevel = C_MythicPlus.GetOwnedKeystoneLevel
local C_PlayerInfo_GetPlayerMythicPlusRatingSummary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary

-- 12.x 秘密值检查（信息受限时单位 GUID 等不可使用），低版本客户端不存在该函数
local issecretvalue = _G.issecretvalue

local MAX_PLAYER_LEVEL = GetMaxLevelForPlayerExpansion()

-- LibKeystone 兼容协议常量
local COMM_PREFIX = "LibKS"
local COMM_THROTTLE = 3 -- 秒

-- 评分数据缓存有效期（秒）
local RATING_CACHE_TTL = 60

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "mythicPlusTooltip",
    name           = L["MythicPlusTooltip_Name"],
    description    = L["MythicPlusTooltip_Desc"],
    defaultEnabled = true,
})

-- 评分数据缓存：[guid] = { updated = 时间戳, data = RatingSummary }
local ratingCache = {}

-- 其他玩家钥石缓存：[玩家名字(不含服务器)] = { level, mapID, rating }
local keystoneCache = {}

-- 本赛季地图信息：[challengeModeID] = { name, timeLimit }，false 表示无效
local mapInfoCache = {}
-- 本赛季地图排序权重：[challengeModeID] = 序号（按暴雪赛季列表顺序展示）
local seasonOrder = {}

-- ------------------------------------------------------------
-- SafePositive: 安全判断是否大于 0（兼容 12.0 secret value）
-- ------------------------------------------------------------
-- secret 值参与比较会抛错，pcall 保护后保守返回 false
local function SafePositive(v)
    if v == nil then return false end
    local ok, result = pcall(function() return v > 0 end)
    return ok and result == true
end

-- ------------------------------------------------------------
-- BuildSeasonMaps: 构建本赛季地图信息（启用时调用一次）
-- ------------------------------------------------------------
local function BuildSeasonMaps()
    mapInfoCache = {}
    seasonOrder = {}
    local mapTable = C_ChallengeMode_GetMapTable and C_ChallengeMode_GetMapTable()
    if not mapTable then return end
    for index, mapID in ipairs(mapTable) do
        local name, _, timeLimit = C_ChallengeMode_GetMapUIInfo(mapID)
        if name then
            mapInfoCache[mapID] = { name = name, timeLimit = timeLimit }
            seasonOrder[mapID] = index
        end
    end
end

-- ------------------------------------------------------------
-- GetMapInfo: 获取地图信息（赛季外地图按需补充查询并缓存）
-- ------------------------------------------------------------
local function GetMapInfo(mapID)
    local info = mapInfoCache[mapID]
    if info == nil then
        local name, _, timeLimit = C_ChallengeMode_GetMapUIInfo(mapID)
        info = name and { name = name, timeLimit = timeLimit } or false
        mapInfoCache[mapID] = info
    end
    return info or nil
end

-- ------------------------------------------------------------
-- GetRatingData: 获取单位的大秘境评分数据（带 60 秒缓存）
-- ------------------------------------------------------------
local function GetRatingData(unit, guid)
    local cached = ratingCache[guid]
    local now = time()
    if cached and now - cached.updated < RATING_CACHE_TTL then
        return cached.data
    end
    local data = C_PlayerInfo_GetPlayerMythicPlusRatingSummary(unit)
    if not data then
        return nil
    end
    ratingCache[guid] = { updated = now, data = data }
    return data
end

-- ------------------------------------------------------------
-- LibOpenRaid 兼容读取（可选）：本机存在 Details 等内嵌库时利用其缓存
-- ------------------------------------------------------------
local openRaidLib
local function GetOpenRaidLib()
    if openRaidLib == nil then
        openRaidLib = (_G.LibStub and _G.LibStub("LibOpenRaid-1.0", true)) or false
    end
    return openRaidLib or nil
end

-- ------------------------------------------------------------
-- GetUnitKeystone: 获取单位当前钥石
-- ------------------------------------------------------------
-- 返回 challengeMapID, level；未知返回 nil
-- 优先级：LibOpenRaid 缓存 > 自身 API > LibKS 通讯缓存
local function GetUnitKeystone(unit)
    -- LibOpenRaid（Details 用户广播的数据，仅读取缓存，不主动请求）
    local orLib = GetOpenRaidLib()
    if orLib and orLib.GetKeystoneInfo then
        local info = orLib.GetKeystoneInfo(unit)
        if info and info.level and info.level > 0 then
            local mapID = info.challengeMapID or info.mapID
            if mapID and mapID > 0 then
                return mapID, info.level
            end
        end
    end

    -- 自身钥石直接读取原生 API
    if UnitIsUnit(unit, "player") then
        local level = C_MythicPlus_GetOwnedKeystoneLevel()
        local mapID = C_MythicPlus_GetOwnedKeystoneChallengeMapID()
        if level and level > 0 and mapID and mapID > 0 then
            return mapID, level
        end
        return nil
    end

    -- LibKS 通讯缓存（按发送者名字匹配）
    local name = GetUnitName(unit, true)
    name = name and Ambiguate(name, "none")
    local data = name and keystoneCache[name]
    if data and data.level > 0 and data.mapID > 0 then
        return data.mapID, data.level
    end
    return nil
end

-- ------------------------------------------------------------
-- LibKS 协议通讯（LibKeystone 兼容实现）
-- ------------------------------------------------------------
local commFrame = CreateFrame("Frame")
local lastSentTime = { PARTY = 0, GUILD = 0 }
local lastRequestTime = { PARTY = 0, GUILD = 0 }

-- 发送自身钥石数据到指定频道（3 秒节流）
local function SendOwnKeystone(channel)
    if channel == "PARTY" and not IsInGroup() then return end
    if channel == "GUILD" and not IsInGuild() then return end
    local now = GetTime()
    if now - lastSentTime[channel] < COMM_THROTTLE then return end
    lastSentTime[channel] = now

    local level = C_MythicPlus_GetOwnedKeystoneLevel() or 0
    local mapID = C_MythicPlus_GetOwnedKeystoneChallengeMapID() or 0
    local summary = C_PlayerInfo_GetPlayerMythicPlusRatingSummary("player")
    local rating = (summary and summary.currentSeasonScore) or 0
    C_ChatInfo_SendAddonMessage(COMM_PREFIX, format("%d,%d,%d", level, mapID, rating), channel)
end

-- 向指定频道请求其他玩家的钥石数据（3 秒节流）
local function RequestKeystones(channel)
    if channel == "PARTY" and not IsInGroup() then return end
    if channel == "GUILD" and not IsInGuild() then return end
    local now = GetTime()
    if now - lastRequestTime[channel] < COMM_THROTTLE then return end
    lastRequestTime[channel] = now
    C_ChatInfo_SendAddonMessage(COMM_PREFIX, "R", channel)
end

commFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        if prefix ~= COMM_PREFIX then return end
        -- 收到数据请求：应答自身钥石（节流由 SendOwnKeystone 处理）
        if msg == "R" then
            if channel == "PARTY" or channel == "GUILD" then
                SendOwnKeystone(channel)
            end
            return
        end
        -- 收到数据广播："等级,副本ID,评分"
        local levelStr, mapIDStr, ratingStr = strmatch(msg, "^(%d+),(%d+),(%d+)$")
        if levelStr and mapIDStr and ratingStr then
            local name = sender and Ambiguate(sender, "none")
            if name then
                keystoneCache[name] = {
                    level = tonumber(levelStr),
                    mapID = tonumber(mapIDStr),
                    rating = tonumber(ratingStr),
                }
            end
        end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "CHALLENGE_MODE_START" then
        RequestKeystones("PARTY")
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        -- 大秘境完成后钥石可能变化，延迟 2 秒等待 API 更新后广播并重新请求
        C_Timer.After(2, function()
            SendOwnKeystone("PARTY")
            RequestKeystones("PARTY")
        end)
    end
end)

-- ------------------------------------------------------------
-- OnTooltipUnit: 单位鼠标提示后置回调
-- ------------------------------------------------------------
local function OnTooltipUnit(tooltip)
    -- 回调无法卸载，通过模块开关短路（零开销）
    if not module.enabled then return end
    if tooltip ~= GameTooltip then return end

    local _, unit = tooltip:GetUnit()
    -- 单位本身可能是 secret 值（信息受限场景，如 SetWorldCursor），
    -- UnitIsPlayer 等 API 拒绝 secret 参数，直接跳过
    if not unit or (issecretvalue and issecretvalue(unit)) then return end
    if not UnitIsPlayer(unit) then return end
    -- 等级可能是 secret 值（信息受限场景），pcall 保护，异常时保守跳过
    local okLevel, isMaxLevel = pcall(function() return UnitLevel(unit) == MAX_PLAYER_LEVEL end)
    if not okLevel or not isMaxLevel then return end

    local guid = UnitGUID(unit)
    -- 秘密值（信息受限场景）不可使用，直接跳过
    if not guid or (issecretvalue and issecretvalue(guid)) then return end

    local summary = GetRatingData(unit, guid)
    local keyMapID, keyLevel = GetUnitKeystone(unit)

    local hasScore = summary and SafePositive(summary.currentSeasonScore)
    if not hasScore and not keyMapID then return end

    tooltip:AddLine(" ")
    tooltip:AddLine(L["MPT_Header"], 1, 0.82, 0)

    -- 本赛季总评分（按分数段着色）
    if hasScore then
        local color = C_ChallengeMode_GetDungeonScoreRarityColor(summary.currentSeasonScore)
        if color then
            tooltip:AddDoubleLine(L["MPT_Score"], summary.currentSeasonScore, nil, nil, nil, color.r, color.g, color.b)
        else
            tooltip:AddDoubleLine(L["MPT_Score"], summary.currentSeasonScore, nil, nil, nil, 1, 1, 1)
        end
    end

    -- 当前钥石（副本名 + 等级，按钥石等级着色）
    if keyMapID and keyLevel then
        local info = GetMapInfo(keyMapID)
        local text = format("%s (%d)", info and info.name or "?", keyLevel)
        if C_ChallengeMode_GetKeystoneLevelRarityColor then
            local keyColor = C_ChallengeMode_GetKeystoneLevelRarityColor(keyLevel)
            if keyColor then
                text = keyColor:WrapTextInColorCode(text)
            end
        end
        tooltip:AddDoubleLine(L["MPT_Keystone"], text, nil, nil, nil, 1, 1, 1)
    end

    -- 各副本最佳成绩：层数（带 +N 标注）+ 分数
    if summary and summary.runs then
        local lines = {}
        for _, run in pairs(summary.runs) do
            local info = GetMapInfo(run.challengeModeID)
            if info and SafePositive(run.bestRunLevel) then
                -- 限时完成显示白色层数，超时显示灰色（secret 值格式化会抛错，pcall 保护）
                local okLv, levelText = pcall(function()
                    if run.finishedSuccess then
                        return format("|cffffffff%d|r", run.bestRunLevel)
                    end
                    return format("|cffaaaaaa%d|r", run.bestRunLevel)
                end)
                if not okLv then levelText = "?" end
                -- 限时升级数：60% 时间内 +3，80% 内 +2，其余限时 +1
                -- （secret 值不可算术，pcall 保护，失败时仅显示层数不加 +N 前缀）
                if run.finishedSuccess and info.timeLimit and run.bestRunDurationMS then
                    local okUp, upgrades = pcall(function()
                        local sec = run.bestRunDurationMS / 1000
                        return (sec <= info.timeLimit * 0.6 and 3)
                            or (sec <= info.timeLimit * 0.8 and 2)
                            or 1
                    end)
                    if okUp and upgrades then
                        levelText = strrep("+", upgrades) .. levelText
                    end
                end

                local scoreColor = C_ChallengeMode_GetSpecificDungeonOverallScoreRarityColor(run.mapScore)
                local okScore, scoreText = pcall(function()
                    return scoreColor and scoreColor:WrapTextInColorCode(run.mapScore)
                        or tostring(run.mapScore)
                end)
                if not okScore then scoreText = "?" end

                tinsert(lines, {
                    order = seasonOrder[run.challengeModeID] or 999,
                    left = info.name,
                    right = levelText .. " " .. scoreText,
                })
            end
        end

        sort(lines, function(a, b) return a.order < b.order end)
        for _, line in ipairs(lines) do
            tooltip:AddDoubleLine(line.left, line.right, 1, 1, 1, 1, 1, 1)
        end
    end

    tooltip:Show()
end

-- 回调无法卸载，仅注册一次，内部通过 module.enabled 开关控制
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnTooltipUnit)

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
function module:OnEnable()
    BuildSeasonMaps()
    C_ChatInfo_RegisterAddonMessagePrefix(COMM_PREFIX)
    commFrame:RegisterEvent("CHAT_MSG_ADDON")
    commFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    commFrame:RegisterEvent("CHALLENGE_MODE_START")
    commFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
    -- 启用时主动请求一次队伍/公会钥石数据
    RequestKeystones("PARTY")
    RequestKeystones("GUILD")
    Util:Debug("MythicPlusTooltip: 已启用")
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
function module:OnDisable()
    commFrame:UnregisterAllEvents()
    Util:Debug("MythicPlusTooltip: 已禁用")
end
