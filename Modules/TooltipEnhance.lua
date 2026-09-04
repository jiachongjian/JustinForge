-- ============================================================
-- JustinForge 模块: 鼠标提示扩展 (TooltipEnhance.lua)
-- ============================================================
-- 功能描述：
--   合并原「鼠标提示大秘境信息」与「鼠标提示团本进度」模块，
--   并增强人物提示框显示。鼠标指向玩家时：
--     1. 姓名行：职业染色、隐藏头衔、同服隐藏服务器名、显示<离开><忙碌><离线>
--     2. 公会行：<公会名称>[会阶名称]，名称为公会绿色、符号白色
--     3. 等级行：隐藏"等级"字样，数字为系统黄色；
--        原"专精 职业"行就地改为职业染色（不折叠、不改字体）
--     4. 大秘境分数、史诗钥匙（仅自己背包有钥匙时显示，史诗紫色）、
--        物品等级（套装数 n/5 为 #FF69B4 粉色）
--     5. 每个地下城的最佳层数与分数（带地下城图标；限时白色层数带
--        +N 前缀，非限时灰色层数无前缀）
--     6. 当前赛季团本进度（带团本图标，中文难度）
--     7. 目标的目标（>>姓名/你<<，职业染色）
--     8. 世界悬停提示立即消失：鼠标离开世界单位/对象时跳过暴雪默认的
--        「停留 1 秒 + 淡出 1 秒」，提示框立刻隐藏
--   （字号保持原生：原 15 号字功能已移除，避免污染池化复用的 FontString）
--
-- 实现原理：
--   1. TooltipDataProcessor.AddTooltipPostCall(Unit) 回调中取鼠标单位
--   2. 修改已有行（姓名/公会/等级/专精，仅文字与颜色）+ 追加新行（M+/团本/目标）
--   3. 字号保持原生，不做任何字体改动（原 15 号字功能已移除：行 FontString
--      为池化复用，字体残留会持续污染第三方插件追加的内容）
--   4. 零几何/字体写操作：不挪锚点、不定宽、不改字号——行 FontString 为
--      全提示类型池化复用，任何持久属性残留都会污染物品等提示的第三方内容
--      （原右对齐功能已移除：AddDoubleLine 右列采用暴雪原生紧随布局）
--   5. 回调无法卸载，禁用时通过模块开关短路返回
--   6. M+评分数据缓存 60 秒，团本进度数据缓存 120 秒
--   7. 团本进度对其他玩家使用成就对比 API，受观察距离限制
--   8. 立即消失：hook GameTooltip 实例的 FadeOut（C++ 内置方法：先停留
--      1 秒保持不透明，再花 1 秒淡出），触发时立即 Hide。注意 GameTooltip
--      经 XML mixin 属性在创建时已拷贝 GameTooltipDataMixin 的函数副本，
--      事后 hook GameTooltipDataMixin 本身不会影响该实例，必须 hook 实例
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local format = format
local ipairs = ipairs
local pairs = pairs
local select = select
local sort = table.sort
local strrep = strrep
local tconcat = table.concat
local BreakUpLargeNumbers = BreakUpLargeNumbers
local floor = math.floor
local tinsert = tinsert
local tostring = tostring
local tonumber = tonumber

local CanInspect = CanInspect
local ClearAchievementComparisonUnit = ClearAchievementComparisonUnit
local GetAverageItemLevel = GetAverageItemLevel
local GetComparisonStatistic = GetComparisonStatistic
local GetGuildInfo = GetGuildInfo
local GetInventoryItemLink = GetInventoryItemLink
local GetRealmName = GetRealmName
local GetStatistic = GetStatistic
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local SetAchievementComparisonUnit = SetAchievementComparisonUnit
local UnitClass = UnitClass
local UnitExists = UnitExists
local UnitGUID = UnitGUID
local UnitIsAFK = UnitIsAFK
local UnitIsConnected = UnitIsConnected
local UnitIsDND = UnitIsDND
local UnitIsPlayer = UnitIsPlayer
local UnitIsUnit = UnitIsUnit
local UnitLevel = UnitLevel
local UnitName = UnitName
local UnitRace = UnitRace

local C_AddOns_IsAddOnLoaded = C_AddOns.IsAddOnLoaded
local C_ChallengeMode_GetDungeonScoreRarityColor = C_ChallengeMode.GetDungeonScoreRarityColor
local C_ChallengeMode_GetMapTable = C_ChallengeMode.GetMapTable
local C_ChallengeMode_GetMapUIInfo = C_ChallengeMode.GetMapUIInfo
local C_ChallengeMode_GetSpecificDungeonOverallScoreRarityColor = C_ChallengeMode.GetSpecificDungeonOverallScoreRarityColor
local C_MythicPlus_GetOwnedKeystoneChallengeMapID = C_MythicPlus.GetOwnedKeystoneChallengeMapID
local C_MythicPlus_GetOwnedKeystoneLevel = C_MythicPlus.GetOwnedKeystoneLevel
local C_PlayerInfo_GetInspectItemLevel = C_PlayerInfo.GetInspectItemLevel
local C_PlayerInfo_GetPlayerMythicPlusRatingSummary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary
local RAID_CLASS_COLORS = RAID_CLASS_COLORS

-- 12.x 秘密值检查
local issecretvalue = _G.issecretvalue

-- secret boolean 防护：秘密布尔值禁止做任何布尔判断（not/and/or/if），
-- 一律先经本函数转为 nil（按"未知"处理），调用方用 == true / == false 显式比较
local function SafeBool(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

-- 暴雪数字格式（千分位分隔），失败回退普通字符串
local function BreakUp(v)
    local ok, res = pcall(BreakUpLargeNumbers, v)
    if ok and res then return res end
    return tostring(v)
end

local MAX_PLAYER_LEVEL = GetMaxLevelForPlayerExpansion()

-- 缓存有效期
local RATING_CACHE_TTL = 60
local RAID_CACHE_TTL = 120

-- 暴雪默认标题黄色
local TITLE_COLOR = { r = 1, g = 0.82, b = 0 }

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "tooltipEnhance",
    name           = L["TooltipEnhance_Name"],
    description    = L["TooltipEnhance_Desc"],
    defaultEnabled = true,
})

-- 无可配置项：仅追加信息与改换文字颜色/格式，字号/字体保持原生

-- ============================================================
-- 数据缓存
-- ============================================================
-- M+评分缓存：[guid] = { updated = 时间戳, data = RatingSummary }
local ratingCache = {}
-- 团本进度缓存：[guid] = { updated = 时间戳, raids = { [团本序号] = { [难度] = "x/y" } } }
local raidCache = {}
-- 本赛季地图信息：[challengeModeID] = { name, timeLimit, tex }
local mapInfoCache = {}
local seasonOrder = {}
-- 已发出成就对比请求的 GUID 集合
local pendingGUIDs = {}
local achievementUILoaded = false

-- ============================================================
-- 配色方案（团本难度）
-- ============================================================
local DIFFICULTIES = {
    { abbr = "随机", color = "ff8000" },  -- 橙
    { abbr = "普通", color = "1eff00" },  -- 绿
    { abbr = "英雄", color = "0070dd" },  -- 蓝
    { abbr = "史诗", color = "a335ee" },  -- 紫
}

-- ============================================================
-- 当前赛季团本数据（「至暗之夜」第二赛季，12.1）
-- 击杀统计 ID 来源：wowhead 角色统计（已逐个核对）；
-- lfgID / 图标来源：wago.tools LFGDungeons（普通难度条目）
-- ============================================================
local CURRENT_SEASON_RAIDS = {
    { -- 烈毒之渊（8 Boss：奈克扎利/陵墓哨兵/失落的探险者/恶毒者瓦什尼克/斯佐拉克/双生毒牙/盘卷祭坛/乌拉特克）
        lfgID = 3313, name = "烈毒之渊", tex = 8039391,
        stats = {
            { 63533, 63537, 63541, 63547, 63548, 63549, 63550, 63551 },
            { 63534, 63538, 63552, 63555, 63558, 63561, 63564, 63567 },
            { 63535, 63539, 63553, 63556, 63559, 63562, 63565, 63568 },
            { 63536, 63540, 63554, 63557, 63560, 63563, 63566, 63569 },
        },
    },
    { -- 潮缚石窟（世界首领巢穴，1 Boss：尼姆瑞莎·唤波者）
        -- 无随机团队难度，第 1 槽位使用「世界」版本统计（通过团队查找器排队击杀计入此项）
        lfgID = 3277, name = "潮缚石窟", tex = 8164250,
        stats = {
            { 63613 },
            { 63614 },
            { 63615 },
            { 63616 },
        },
    },
}

-- ============================================================
-- 辅助函数
-- ============================================================

-- 安全判断是否大于 0（兼容 12.0 secret value）
local function SafePositive(v)
    if v == nil then return false end
    local ok, result = pcall(function() return v > 0 end)
    return ok and result == true
end

-- 安全读取击杀次数
local function SafeKillTimes(getStatFunc, statID)
    local ok, value = pcall(getStatFunc, statID)
    if not ok or value == nil then return 0 end
    if issecretvalue and issecretvalue(value) then return 0 end
    return tonumber(value, 10) or 0
end

-- ============================================================
-- 世界悬停提示立即消失
-- 鼠标离开世界单位/对象时，暴雪 SetWorldCursor 走「ClearHandlerInfo +
-- FadeOut」分支；FadeOut 为 C++ 内置方法：先停留 1 秒保持不透明，再花
-- 1 秒淡出（观感为"提示框延迟消失"）。hook FadeOut 命中后立即 Hide。
-- 注意：GameTooltip 经 XML mixin 属性在创建时已拷贝 GameTooltipDataMixin
-- 的函数副本，事后 hook mixin 表不会影响已创建的实例（旧版 hook
-- GameTooltipDataMixin.SetWorldCursor 从未生效的原因），必须 hook 实例。
-- 回调无法卸载，禁用时通过模块开关短路返回。
-- ============================================================
if GameTooltip and GameTooltip.FadeOut then
    hooksecurefunc(GameTooltip, "FadeOut", function(self)
        if module.enabled then
            self:Hide()
        end
    end)
end

-- 获取职业颜色 hex 和 RGB
local function GetClassColor(classFile)
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if color then
        return format("%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255), color.r, color.g, color.b
    end
    return "ffffff", 1, 1, 1
end

-- 安全获取单位名称和服务器（同服返回 nil 服务器以隐藏）
local function GetUnitNameAndServer(unit)
    local ok, name, server = pcall(UnitName, unit)
    if not ok or not name then return nil, nil end
    if issecretvalue and (issecretvalue(name) or (server and issecretvalue(server))) then return nil, nil end
    if not server or server == "" then return name, nil end
    -- 与自己同服则隐藏服务器名（忽略空格差异）
    local myRealm = GetRealmName()
    if myRealm then
        if server:gsub("%s", "") == myRealm:gsub("%s", "") then
            return name, nil
        end
    end
    return name, server
end

-- ============================================================
-- 赛季地图信息
-- ============================================================
local function BuildSeasonMaps()
    mapInfoCache = {}
    seasonOrder = {}
    local mapTable = C_ChallengeMode_GetMapTable and C_ChallengeMode_GetMapTable()
    if not mapTable then return end
    for index, mapID in ipairs(mapTable) do
        -- GetMapUIInfo 第 4 返回值为地下城图标 texture
        local name, _, timeLimit, texture = C_ChallengeMode_GetMapUIInfo(mapID)
        if name then
            mapInfoCache[mapID] = { name = name, timeLimit = timeLimit, tex = texture }
            seasonOrder[mapID] = index
        end
    end
end

local function GetMapInfo(mapID)
    local info = mapInfoCache[mapID]
    if info == nil then
        local name, _, timeLimit, texture = C_ChallengeMode_GetMapUIInfo(mapID)
        info = name and { name = name, timeLimit = timeLimit, tex = texture } or false
        mapInfoCache[mapID] = info
    end
    return info or nil
end

-- ============================================================
-- M+评分数据获取（带 60 秒缓存）
-- ============================================================
local function GetRatingData(unit, guid)
    local cached = ratingCache[guid]
    local now = GetTime()
    if cached and now - cached.updated < RATING_CACHE_TTL then
        return cached.data
    end
    local data = C_PlayerInfo_GetPlayerMythicPlusRatingSummary(unit)
    if not data then return nil end
    ratingCache[guid] = { updated = now, data = data }
    return data
end

-- ============================================================
-- 物品等级与套装数
-- ============================================================
local function GetUnitItemLevel(unit)
    if SafeBool(UnitIsUnit(unit, "player")) == true then
        local ok, _, equipped = pcall(GetAverageItemLevel)
        if ok and equipped then
            if issecretvalue and issecretvalue(equipped) then return nil end
            return equipped
        end
        return nil
    end
    if not C_PlayerInfo_GetInspectItemLevel then return nil end
    local ok, ilvl = pcall(C_PlayerInfo_GetInspectItemLevel, unit)
    if ok and ilvl then
        if issecretvalue and issecretvalue(ilvl) then return nil end
        return ilvl
    end
    return nil
end

local function GetUnitSetCount(unit)
    local setCounts = {}
    for slot = 1, 19 do
        local okLink, link = pcall(GetInventoryItemLink, unit, slot)
        if okLink and link then
            if issecretvalue and issecretvalue(link) then
            else
                local okInfo, itemSet = pcall(function()
                    return select(16, C_Item.GetItemInfo(link))
                end)
                if okInfo and itemSet then
                    if issecretvalue and issecretvalue(itemSet) then
                    else
                        setCounts[itemSet] = (setCounts[itemSet] or 0) + 1
                    end
                end
            end
        end
    end
    local maxCount = 0
    for _, count in pairs(setCounts) do
        if count > maxCount then maxCount = count end
    end
    return maxCount
end

-- ============================================================
-- 团本进度数据采集
-- ============================================================
local function CollectRaidProgress(guid, isSelf)
    local getStatFunc = isSelf and GetStatistic or GetComparisonStatistic
    local raids

    for raidIndex, raid in ipairs(CURRENT_SEASON_RAIDS) do
        local progress
        for difficulty = #DIFFICULTIES, 1, -1 do
            local statIDs = raid.stats[difficulty]
            local killed = 0
            for _, statID in ipairs(statIDs) do
                if SafeKillTimes(getStatFunc, statID) > 0 then
                    killed = killed + 1
                end
            end
            if killed > 0 then
                progress = progress or {}
                progress[difficulty] = format("%s/%d", BreakUp(killed), #statIDs)
                if killed == #statIDs then break end
            end
        end
        if progress then
            raids = raids or {}
            raids[raidIndex] = progress
        end
    end

    raidCache[guid] = { updated = GetTime(), raids = raids }
end

local function RequestComparison(unit, guid)
    if not CanInspect(unit) then return end
    if not achievementUILoaded then
        if not C_AddOns_IsAddOnLoaded("Blizzard_AchievementUI") then
            if not pcall(AchievementFrame_LoadUI) then return end
        end
        if C_AddOns_IsAddOnLoaded("Blizzard_AchievementUI") then
            achievementUILoaded = true
        else
            return
        end
    end
    if not SetAchievementComparisonUnit then return end
    ClearAchievementComparisonUnit()
    local ok, result = pcall(SetAchievementComparisonUnit, unit)
    if ok and result then
        pendingGUIDs[guid] = true
    end
end

-- ============================================================
-- 人物提示框修改：姓名行
-- ============================================================
local function ModifyNameLine(tooltip, unit)
    local left1 = _G["GameTooltipTextLeft1"]
    if not left1 then return end

    local name, server = GetUnitNameAndServer(unit)
    if not name then return end

    local okClass, _, classFile = pcall(UnitClass, unit)
    local hex = "ffffff"
    if okClass and classFile then
        hex = GetClassColor(classFile)
    end

    -- 姓名（-服务器），同服隐藏服务器字段
    local nameText
    if server and server ~= "" then
        nameText = format("|cff%s%s-%s|r", hex, name, server)
    else
        nameText = format("|cff%s%s|r", hex, name)
    end

    -- 状态：<离线>/<离开>/<忙碌>
    local okAFK, isAFK = pcall(UnitIsAFK, unit)
    local okDND, isDND = pcall(UnitIsDND, unit)
    local okConn, isConn = pcall(UnitIsConnected, unit)
    isAFK, isDND, isConn = SafeBool(isAFK), SafeBool(isDND), SafeBool(isConn)
    if okConn and isConn == false then
        nameText = nameText .. " |cffff0000<离线>|r"
    elseif okAFK and isAFK == true then
        nameText = nameText .. " |cffff0000<离开>|r"
    elseif okDND and isDND == true then
        nameText = nameText .. " |cffff0000<忙碌>|r"
    end

    left1:SetText(nameText)
end

-- ============================================================
-- 人物提示框修改：公会行
-- ============================================================
local function ModifyGuildLine(tooltip, unit)
    local ok, guildName, rankName = pcall(GetGuildInfo, unit)
    if not ok or not guildName or guildName == "" then return end
    if issecretvalue and (issecretvalue(guildName) or (rankName and issecretvalue(rankName))) then return end

    -- 直接按公会名纯文本查找（默认行可能带尖括号/颜色代码，不能依赖格式匹配）
    for i = 2, tooltip:NumLines() do
        local left = _G["GameTooltipTextLeft"..i]
        if left then
            local text = left:GetText()
            if text and text:find(guildName, 1, true) then
                local newText
                -- <公会名称>[会阶]，尖括号/方括号符号为白色
                if rankName and rankName ~= "" then
                    newText = format(
                        "|cffffffff<|r|cff1eff00%s|r|cffffffff>|r" ..
                        "|cffffffff[|r|cff1eff00%s|r|cffffffff]|r",
                        guildName, rankName)
                else
                    newText = format("|cffffffff<|r|cff1eff00%s|r|cffffffff>|r", guildName)
                end
                left:SetText(newText)
                return
            end
        end
    end
end

-- ============================================================
-- 人物提示框修改：等级行（隐藏"等级"字样、数字黄色）+ 专精职业行（就地改职业色）
-- 不折叠任何行，不改变字体，仅修改文字颜色
-- ============================================================
local function ModifyLevelAndSpecLine(tooltip, unit)
    local okLv, level = pcall(UnitLevel, unit)
    if not okLv or not level then return end
    if issecretvalue and issecretvalue(level) then return end

    local okRace, race = pcall(UnitRace, unit)
    if not okRace then race = nil end
    if race and issecretvalue and issecretvalue(race) then race = nil end

    local okClass, className, classFile = pcall(UnitClass, unit)
    if not okClass then className, classFile = nil, nil end
    if className and issecretvalue and issecretvalue(className) then className, classFile = nil, nil end
    local classHex = "ffffff"
    if classFile then classHex = GetClassColor(classFile) end

    -- 定位等级行与等级行之下的「专精 职业」行
    -- （限定 i > levelIdx，避免公会名含职业名时误判）
    local numLines = tooltip:NumLines()
    local levelIdx, specIdx, specText
    for i = 2, numLines do
        local left = _G["GameTooltipTextLeft"..i]
        if left then
            local text = left:GetText()
            if text and text ~= "" then
                if not levelIdx and (text:find("等级") or text:find("Level")) then
                    levelIdx = i
                elseif levelIdx and i > levelIdx and className and not specIdx
                    and text:find(className, 1, true) then
                    -- 剥离颜色代码与职业名，剩余即专精名
                    local stripped = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                    stripped = stripped:gsub(className, "")
                    stripped = stripped:gsub("^%s+", ""):gsub("%s+$", "")
                    if stripped ~= "" then
                        specIdx, specText = i, stripped
                    end
                end
            end
        end
    end

    -- 重建等级行：隐藏"等级"字样，数字用系统黄色
    if levelIdx then
        local left = _G["GameTooltipTextLeft"..levelIdx]
        if left then
            local parts = { format("|cffffff00%s|r", BreakUp(level)) }
            if race and race ~= "" then tinsert(parts, race) end
            left:SetText(tconcat(parts, " "))
        end
    end

    -- 专精职业行：就地改为职业染色（不折叠，不改字体）
    if specIdx and specText and className then
        local left = _G["GameTooltipTextLeft"..specIdx]
        if left then
            left:SetText(format("|cff%s%s %s|r", classHex, specText, className))
        end
    end
end

-- ============================================================
-- 追加：大秘境分数 / 史诗钥匙 / 物品等级
-- ============================================================
local function AddSummaryLines(tooltip, unit, summary)
    local hasScore = summary and SafePositive(summary.currentSeasonScore)

    -- 史诗钥匙：仅自己（背包有钥匙时），史诗紫色「地下城名称（层数）」
    local keyText
    if SafeBool(UnitIsUnit(unit, "player")) == true then
        local okKey, text = pcall(function()
            local kLevel = C_MythicPlus_GetOwnedKeystoneLevel()
            local kMap = C_MythicPlus_GetOwnedKeystoneChallengeMapID()
            if kLevel and kLevel > 0 and kMap and kMap > 0 then
                local info = GetMapInfo(kMap)
                return format("|cffa335ee%s（%s）|r", info and info.name or "?", BreakUp(kLevel))
            end
            return nil
        end)
        if okKey then keyText = text end
    end

    local ilvl = GetUnitItemLevel(unit)

    if not hasScore and not keyText and not ilvl then return end

    -- M+ 分数：紧贴上一行，不在中间加空行
    if hasScore then
        local okColor, color = pcall(C_ChallengeMode_GetDungeonScoreRarityColor, summary.currentSeasonScore)
        local okText, scoreText = pcall(function()
            local s = tostring(summary.currentSeasonScore)
            if okColor and color then
                return color:WrapTextInColorCode(s)
            end
            return s
        end)
        if not okText then scoreText = "?" end
        tooltip:AddDoubleLine(L["TE_MPScore"], scoreText,
            TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 1, 1, 1)
    end

    -- 史诗钥匙
    if keyText then
        tooltip:AddDoubleLine(L["TE_Keystone"], keyText,
            TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 1, 1, 1)
    end

    -- 物品等级：（套装数/5 粉色 #FF69B4）装等 1 位小数（与套装无空格）
    if ilvl then
        local setCount = GetUnitSetCount(unit)
        local okFmt, ilvlText = pcall(function()
            local intPart, decPart = floor(ilvl), floor(ilvl * 10) % 10
            return format("|cffff69b4（%s/5）|r%s.%d",
                BreakUp(setCount), BreakUp(intPart), decPart)
        end)
        if not okFmt then ilvlText = "?" end
        tooltip:AddDoubleLine(L["TE_ItemLevel"], ilvlText,
            TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 1, 1, 1)
    end
end

-- ============================================================
-- 追加：每个地下城的最佳层数与分数（带图标）
-- ============================================================
local function AddDungeonScores(tooltip, summary)
    if not summary or not summary.runs then return end
    if not next(summary.runs) then return end

    local entries = {}
    for _, run in pairs(summary.runs) do
        local info = GetMapInfo(run.challengeModeID)
        if info and SafePositive(run.bestRunLevel) then
            local okLv, levelNum = pcall(BreakUp, run.bestRunLevel)
            if not okLv or not levelNum or levelNum == "" then levelNum = "?" end

            -- 限时白色层数 + +N 前缀；超时灰色无前缀
            local pluses = ""
            local timed = false
            local okFin, isFinished = pcall(function() return run.finishedSuccess end)
            if okFin and SafeBool(isFinished) == true then
                timed = true
                if info.timeLimit and run.bestRunDurationMS then
                    local okUp, upgrades = pcall(function()
                        local sec = run.bestRunDurationMS / 1000
                        return (sec <= info.timeLimit * 0.6 and 3)
                            or (sec <= info.timeLimit * 0.8 and 2)
                            or 1
                    end)
                    if okUp and upgrades then
                        pluses = strrep("+", upgrades)
                    end
                end
            end

            local scoreColor = C_ChallengeMode_GetSpecificDungeonOverallScoreRarityColor(run.mapScore)
            local okScore, scoreText = pcall(function()
                local s = BreakUp(run.mapScore)
                return scoreColor and scoreColor:WrapTextInColorCode(s) or s
            end)
            if not okScore then scoreText = "?" end

            tinsert(entries, {
                order  = seasonOrder[run.challengeModeID] or 999,
                timed  = timed,
                level  = run.bestRunLevel,
                mapScore = run.mapScore,
                left   = info.tex and format("|T%d:0|t %s", info.tex, info.name) or info.name,
                -- 层数：限时白色（带 +N 前缀），非限时灰色
                right  = format("%s|cff%s%s|r %s", pluses,
                    timed and "ffffff" or "9d9d9d", levelNum, scoreText),
            })
        end
    end

    if #entries == 0 then return end

    -- 最佳记录：限时前提下层数最高，其次分数最高（左侧加黄色星号 ★）
    local bestEntry
    for _, e in ipairs(entries) do
        if e.timed then
            if bestEntry == nil then
                bestEntry = e
            else
                local prev = bestEntry
                local okLvl, higher = pcall(function() return e.level > prev.level end)
                local better = false
                if okLvl and higher then
                    better = true
                elseif not (okLvl and higher) then
                    local okScr, higherScr = pcall(function() return e.mapScore > prev.mapScore end)
                    if okScr and higherScr then better = true end
                end
                if better then bestEntry = e end
            end
        end
    end

    sort(entries, function(a, b) return a.order < b.order end)

    tooltip:AddLine(" ")
    for _, e in ipairs(entries) do
        local right = e.right
        if e == bestEntry then
            right = format("|cffffff00★|r %s", right)
        end
        tooltip:AddDoubleLine(e.left, right,
            TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 1, 1, 1)
    end
end

-- ============================================================
-- 追加：团本进度（带图标，中文难度）
-- ============================================================
local function AddRaidLines(tooltip, guid)
    local entry = raidCache[guid]
    if not entry or not entry.raids then return end

    tooltip:AddLine(" ")

    for raidIndex, raid in ipairs(CURRENT_SEASON_RAIDS) do
        local progress = entry.raids[raidIndex]
        if progress then
            for difficulty = #DIFFICULTIES, 1, -1 do
                local text = progress[difficulty]
                if text then
                    local diff = DIFFICULTIES[difficulty]
                    -- 左侧：团本图标 + 团本名（默认黄色，不再重复难度名）
                    local left = format("|T%d:0|t %s", raid.tex, raid.name)
                    -- 右侧：彩色中文难度 + 击杀进度
                    local right = format("|cff%s%s %s|r", diff.color, diff.abbr, text)
                    tooltip:AddDoubleLine(left, right,
                        TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 1, 1, 1)
                end
            end
        end
    end
end

-- ============================================================
-- 追加：目标的目标
-- ============================================================
local function AddTargetOfTarget(tooltip, unit)
    local targetUnit = unit.."target"
    local okExists, exists = pcall(UnitExists, targetUnit)
    if not okExists or SafeBool(exists) ~= true then return end

    local okIsPlayer, isPlayerTarget = pcall(UnitIsPlayer, targetUnit)
    isPlayerTarget = SafeBool(isPlayerTarget)

    local targetText
    local okIsUnit, isPlayer = pcall(UnitIsUnit, targetUnit, "player")
    if okIsUnit and SafeBool(isPlayer) == true then
        -- 目标是玩家自己：>>你<<，用玩家职业染色
        local _, _, playerClass = pcall(UnitClass, "player")
        local hex = "ffffff"
        if playerClass then hex = GetClassColor(playerClass) end
        targetText = format("|cff%s>>你<<|r", hex)
    else
        local okName, targetName = pcall(UnitName, targetUnit)
        if not okName or not targetName then return end
        if issecretvalue and issecretvalue(targetName) then return end

        if okIsPlayer and isPlayerTarget then
            local _, _, targetClass = pcall(UnitClass, targetUnit)
            if targetClass then
                local hex = GetClassColor(targetClass)
                targetName = format("|cff%s%s|r", hex, targetName)
            end
        end
        targetText = format(">>%s<<", targetName)
    end

    tooltip:AddDoubleLine(L["TE_TargetTarget"], targetText,
        TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 1, 1, 1)
end

-- ============================================================
-- 事件处理：成就对比数据就绪
-- ============================================================
local progressFrame = CreateFrame("Frame")
progressFrame:SetScript("OnEvent", function(_, event, eventGUID)
    if event ~= "INSPECT_ACHIEVEMENT_READY" then return end
    if not eventGUID or not pendingGUIDs[eventGUID] then return end
    pendingGUIDs[eventGUID] = nil

    CollectRaidProgress(eventGUID, false)
    ClearAchievementComparisonUnit()

    -- 鼠标仍指向该玩家时刷新提示框
    if SafeBool(UnitExists("mouseover")) == true then
        local ok, same = pcall(function()
            local g = UnitGUID("mouseover")
            if not g or (issecretvalue and issecretvalue(g)) then return false end
            return g == eventGUID
        end)
        if ok and same then
            GameTooltip:SetUnit("mouseover")
        end
    end
end)

-- ============================================================
-- 主回调：单位鼠标提示后置回调
-- ============================================================
local function OnTooltipUnit(tooltip, data)
    if not module.enabled then return end
    if tooltip ~= GameTooltip then return end

    local unit
    if data and data.unit then
        unit = data.unit
    else
        _, unit = tooltip:GetUnit()
    end
    if not unit or (issecretvalue and issecretvalue(unit)) then return end
    if SafeBool(UnitIsPlayer(unit)) ~= true then return end

    -- ---- 阶段1：修改已有行（所有玩家） ----
    ModifyNameLine(tooltip, unit)
    ModifyGuildLine(tooltip, unit)
    ModifyLevelAndSpecLine(tooltip, unit)

    -- ---- 阶段2：满级玩家追加 M+ 与团本信息 ----
    local okLevel, isMaxLevel = pcall(function() return UnitLevel(unit) == MAX_PLAYER_LEVEL end)
    local guid = UnitGUID(unit)
    local guidOK = guid and not (issecretvalue and issecretvalue(guid))

    if okLevel and isMaxLevel and guidOK then
        local summary = GetRatingData(unit, guid)
        AddSummaryLines(tooltip, unit, summary)
        -- 目标的目标：紧接物品等级之后、无空格
        AddTargetOfTarget(tooltip, unit)
        AddDungeonScores(tooltip, summary)

        -- 战斗中跳过团本进度（避免加载成就界面造成污染）
        if not InCombatLockdown() then
            local entry = raidCache[guid]
            if entry and GetTime() - entry.updated < RAID_CACHE_TTL then
                AddRaidLines(tooltip, guid)
            elseif SafeBool(UnitIsUnit(unit, "player")) == true then
                CollectRaidProgress(guid, true)
                AddRaidLines(tooltip, guid)
            else
                RequestComparison(unit, guid)
            end
        end
    else
        -- ---- 目标的目标（非满级也支持） ----
        AddTargetOfTarget(tooltip, unit)
    end

    tooltip:Show()
end

-- 回调无法卸载，仅注册一次
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnTooltipUnit)

-- ============================================================
-- OnEnable: 模块启用
-- ============================================================
function module:OnEnable()
    BuildSeasonMaps()
    progressFrame:RegisterEvent("INSPECT_ACHIEVEMENT_READY")
    Util:Debug("TooltipEnhance: 已启用")
end

-- ============================================================
-- OnDisable: 模块禁用
-- ============================================================
function module:OnDisable()
    progressFrame:UnregisterAllEvents()
    ClearAchievementComparisonUnit()
    pendingGUIDs = {}
    Util:Debug("TooltipEnhance: 已禁用")
end
