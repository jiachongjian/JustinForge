-- ============================================================
-- JustinForge 模块: 鼠标提示扩展 (TooltipEnhance.lua)
-- ============================================================
-- 功能描述：
--   合并原「鼠标提示大秘境信息」与「鼠标提示团本进度」模块，
--   并增强人物提示框显示。鼠标指向玩家时：
--     1. 提示框字号设置（0 = 暴雪默认，作用于提示框内所有文字）
--     2. 姓名行：职业染色、隐藏头衔、同服隐藏服务器名、显示<离开><忙碌><离线>
--     3. 公会行：公会名称~会阶名称，除 ~ 号外均为公会绿色
--     4. 等级行：隐藏"等级""玩家"，数字为系统黄色；种族后插入专精（职业色），
--        并折叠原独立的"专精 职业"行
--     5. 阵营：不显示文字（折叠该行），右上角显示镂空风格阵营徽记；
--        非玩家单位不显示徽记
--     6. 大秘境分数、史诗钥匙（仅自己背包有钥匙时显示，史诗紫色）、
--        物品等级（套装数 n/5 为 #C952F4 紫色）
--     7. 每个地下城的最佳层数与分数（带地下城图标，层数右对齐）
--     8. 当前赛季团本进度（带团本图标，中文难度，右对齐）
--     9. 目标的目标（>>姓名/你<<，职业染色）
--
-- 实现原理：
--   1. TooltipDataProcessor.AddTooltipPostCall(Unit) 回调中取鼠标单位
--   2. 修改已有行（姓名/公会/等级/阵营）+ 追加新行（M+/团本/目标）
--   3. 折叠行 = SetText("") + 字号缩为 1；字体改动统一记录原字体，
--      在 OnTooltipCleared/OnHide 时恢复，避免污染后续提示框
--   4. 回调无法卸载，禁用时通过模块开关短路返回
--   5. M+评分数据缓存 60 秒，团本进度数据缓存 120 秒
--   6. 团本进度对其他玩家使用成就对比 API，受观察距离限制
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
local UnitFactionGroup = UnitFactionGroup
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

-- 阵营徽记（镂空风格，透明背景）
local FACTION_LOGO = {
    Alliance = "Interface\\TargetingFrame\\UI-PVP-Alliance",
    Horde    = "Interface\\TargetingFrame\\UI-PVP-Horde",
}

-- 阵营标示配色（部落红 / 联盟蓝）
local FACTION_LOGO_COLOR = {
    Alliance = { 0.15, 0.4, 1.0 },
    Horde    = { 1.0, 0.15, 0.1 },
}

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "tooltipEnhance",
    name           = L["TooltipEnhance_Name"],
    description    = L["TooltipEnhance_Desc"],
    defaultEnabled = true,
})

-- 字号设置（0 = 暴雪默认）
module.options = {
    { type = "slider", key = "fontSize", name = L["TE_FontSize"],
      min = 0, max = 24, step = 1, default = 0, tooltip = L["TE_FontSizeTip"] },
}

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

-- 本次回调中被折叠的行：[lineIndex] = true
local collapsedLines = {}
-- 被改动过字体的 FontString 原始字体记录：[fs] = { file, size, flags }
local defaultFonts = {}
-- 需做「数值列等宽 + 右缘对齐」的行（地下城分数 / 团本进度）：[lineIndex] = true
local colAlignLines = {}

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
-- 当前赛季团本数据（「至暗之夜」第一赛季，12.0）
-- ============================================================
local CURRENT_SEASON_RAIDS = {
    { -- 虚影尖塔（6 Boss）
        lfgID = 3094, name = "虚影尖塔", tex = 7507136,
        stats = {
            { 61288, 61292, 61284, 61280, 61296, 61276 },
            { 61297, 61281, 61277, 61293, 61289, 61285 },
            { 61278, 61290, 61298, 61282, 61294, 61286 },
            { 61279, 61295, 61299, 61287, 61283, 61291 },
        },
    },
    { -- 进军奎尔丹纳斯（2 Boss）
        lfgID = 3095, name = "奎尔丹纳斯", tex = 7480127,
        stats = {
            { 61300, 61304 },
            { 61305, 61301 },
            { 61302, 61306 },
            { 61307, 61303 },
        },
    },
    { -- 梦境裂隙（1 Boss）
        lfgID = 3165, name = "梦境裂隙", tex = 7570496,
        stats = {
            { 61474 },
            { 61475 },
            { 61476 },
            { 61477 },
        },
    },
}

-- ============================================================
-- 阵营徽记纹理（创建一次复用）
-- ============================================================
local factionLogo = GameTooltip:CreateTexture(nil, "OVERLAY", nil, 7)
factionLogo:SetSize(40, 40)
factionLogo:Hide()

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

-- 获取 DB 配置
local function GetDB()
    return ns.db and ns.db.profile and ns.db.profile.tooltipEnhance or {}
end

-- 获取 tooltip 的第 N 行左右 FontString
local function GetLineFonts(tooltip, index)
    local name = tooltip:GetName()
    if not name then return nil, nil end
    return _G[name.."TextLeft"..index], _G[name.."TextRight"..index]
end

-- 记录 FontString 原始字体（首次改动前调用）
local function RememberFont(fs)
    if fs and not defaultFonts[fs] then
        defaultFonts[fs] = { fs:GetFont() }
    end
end

-- 恢复所有被改动过的字体（提示框清空/隐藏时调用，防止污染后续内容）
local function RestoreAllFonts()
    for fs, f in pairs(defaultFonts) do
        fs:SetFont(f[1], f[2], f[3])
    end
end

GameTooltip:HookScript("OnTooltipCleared", function()
    collapsedLines = {}
    colAlignLines = {}
    RestoreAllFonts()
end)
GameTooltip:HookScript("OnHide", function()
    factionLogo:Hide()
    collapsedLines = {}
    colAlignLines = {}
    RestoreAllFonts()
end)

-- 折叠一行：清空文字并把字号缩为 1（视觉上该行消失）
local function CollapseLine(tooltip, idx)
    local left, right = GetLineFonts(tooltip, idx)
    if left then
        RememberFont(left)
        left:SetText("")
        local f, _, fl = left:GetFont()
        if f then left:SetFont(f, 1, fl) end
    end
    if right then
        RememberFont(right)
        right:SetText("")
        local f, _, fl = right:GetFont()
        if f then right:SetFont(f, 1, fl) end
    end
    collapsedLines[idx] = true
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
-- 全局文字样式（字号 + 细描边；0 字号 = 暴雪默认；跳过被折叠的行）
-- 对任意类型提示框（人物/物品/技能等）全局生效
-- ============================================================
local function StyleFonts(tooltip)
    local db = GetDB()
    local size = db.fontSize or 0
    local name = tooltip:GetName()
    if not name then return end
    for i = 1, tooltip:NumLines() do
        if not collapsedLines[i] then
            local left, right = GetLineFonts(tooltip, i)
            if left then
                RememberFont(left)
                local f, curSize, _ = left:GetFont()
                if f then left:SetFont(f, size > 0 and size or curSize, "OUTLINE") end
            end
            if right then
                RememberFont(right)
                local f, curSize, _ = right:GetFont()
                if f then right:SetFont(f, size > 0 and size or curSize, "OUTLINE") end
            end
        end
    end
end

-- ============================================================
-- 追加行的右列右对齐（锚定到提示框右缘，inset 与左列对称）
-- ============================================================
local function GetRightInset(tooltip)
    local name = tooltip:GetName()
    local left1 = name and _G[name .. "TextLeft1"]
    if left1 then
        local ok, _, _, relPoint, x = pcall(left1.GetPoint, left1, 1)
        -- 12.0: 锚点信息可能是 secret 值（如世界光标提示），pcall 无法拦住后续比较，须先判 secret
        if ok and relPoint and x
            and not (issecretvalue and (issecretvalue(relPoint) or issecretvalue(x)))
            and (relPoint == "LEFT" or relPoint == "TOPLEFT") then
            local inset = math.abs(x)
            if inset > 0 and inset < 40 then
                return inset
            end
        end
    end
    return 15
end

local function RightAlignLines(tooltip, fromLine)
    local name = tooltip:GetName()
    if not name then return end
    local inset = GetRightInset(tooltip)
    for i = fromLine, tooltip:NumLines() do
        local right = _G[name .. "TextRight" .. i]
        if right then
            right:ClearAllPoints()
            right:SetPoint("RIGHT", tooltip, "RIGHT", -inset, 0)
            right:SetJustifyH("RIGHT")
        end
    end
end

-- ============================================================
-- AlignNumericCols: 数值行等宽列 + 右缘对齐
-- （地下城分数 / 团本进度专用；必须在 StyleFonts 之后调用，
--  用 FontString:GetStringWidth() 实测渲染宽度取最大值定列宽，
--  规避非等宽字体造成的「同位数不同宽」参差，无需外部等宽字体）
-- ============================================================
local function AlignNumericCols(tooltip)
    if not next(colAlignLines) then return end
    local name = tooltip:GetName()
    if not name then return end
    local inset = GetRightInset(tooltip)

    -- 实测各数值行渲染宽度（须在字体设置后），取最大值定整个数值列的宽度
    local maxW = 0
    local rights = {}
    for line in pairs(colAlignLines) do
        local right = _G[name .. "TextRight" .. line]
        if right then
            tinsert(rights, right)
            local ok, w = pcall(right.GetStringWidth, right)
            if ok and w and w > maxW then maxW = w end
        end
    end
    if #rights == 0 or maxW <= 0 then return end

    local colW = maxW + 4 -- 右缘留 4px 内边距，避免贴边
    for _, right in ipairs(rights) do
        pcall(function()
            right:ClearAllPoints()
            right:SetPoint("RIGHT", tooltip, "RIGHT", -inset, 0)
            right:SetJustifyH("RIGHT")
            right:SetWidth(colW)
        end)
    end
end

-- 强制追加行右列不换行：右列宽度取文本内容实际渲染宽度（须在 StyleFonts 之后调用）。
-- 物品等级等整行较长（含全角括号）时，AddDoubleLine 预设的右列宽度偏小会导致内容换行，
-- 这里收敛为内容真实宽度，保证单行右对齐显示。
local function SingleLineAlign(tooltip, fromLine)
    local name = tooltip:GetName()
    if not name then return end
    for i = fromLine, tooltip:NumLines() do
        -- 已加入等宽数值列的行（地下城分数/团本进度）交给 AlignNumericCols，这里跳过
        if not colAlignLines[i] then
            local right = _G[name .. "TextRight" .. i]
            if right then
                pcall(function()
                    local w = right:GetStringWidth()
                    if w and w > 0 then
                        right:SetWidth(w + 2)
                    else
                        right:SetWidth(0)
                    end
                end)
            end
        end
    end
end

-- 全局字号/描边：注册到各内容类型的「后置回调」，确保在行构建完成、显示之前生效，
-- 避免单纯 OnShow 时机导致默认字体闪现后被系统覆盖（物品/技能等）。
-- 单位类型已由 OnTooltipUnit 单独处理，这里只覆盖其余类型。
do
    local dtypes = {
        Enum.TooltipDataType.Item,
        Enum.TooltipDataType.Spell,
        Enum.TooltipDataType.Action,
        Enum.TooltipDataType.Achievement,
        Enum.TooltipDataType.Macro,
    }
    for _, dt in ipairs(dtypes) do
        pcall(TooltipDataProcessor.AddTooltipPostCall, dt, function(tooltip)
            if module.enabled then
                StyleFonts(tooltip)
            end
        end)
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
-- 人物提示框修改：等级行（合并专精，折叠原"专精 职业"行）
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

    -- 重建等级行：黄色等级 + 种族 + 职业色专精 + 职业色职业
    if levelIdx then
        local left = _G["GameTooltipTextLeft"..levelIdx]
        if left then
            local parts = { format("|cffffff00%s|r", BreakUp(level)) }
            if race and race ~= "" then tinsert(parts, race) end
            if specText then tinsert(parts, format("|cff%s%s|r", classHex, specText)) end
            if className then tinsert(parts, format("|cff%s%s|r", classHex, className)) end
            left:SetText(tconcat(parts, " "))
        end
    end

    -- 折叠原独立的「专精 职业」行
    if specIdx then
        CollapseLine(tooltip, specIdx)
    end
end

-- ============================================================
-- 人物提示框修改：阵营行（折叠文字，显示镂空徽记）
-- ============================================================
local function ModifyFactionLine(tooltip, unit)
    local ok, englishFaction = pcall(UnitFactionGroup, unit)
    if not ok or not englishFaction then
        factionLogo:Hide()
        return
    end
    if issecretvalue and issecretvalue(englishFaction) then
        factionLogo:Hide()
        return
    end

    -- 折叠阵营文字行
    for i = 2, tooltip:NumLines() do
        local left = _G["GameTooltipTextLeft"..i]
        if left then
            local text = left:GetText()
            if text and (text == "联盟" or text == "部落" or
                         text:find("^联盟") or text:find("^部落") or
                         text:find("^Alliance") or text:find("^Horde")) then
                CollapseLine(tooltip, i)
                break
            end
        end
    end

    -- 仅联盟/部落显示徽记（中立如未选阵营熊猫人不显示）
    local tex = FACTION_LOGO[englishFaction]
    if tex then
        factionLogo:SetTexture(tex)
        local c = FACTION_LOGO_COLOR[englishFaction]
        if c then
            factionLogo:SetVertexColor(c[1], c[2], c[3])
        else
            factionLogo:SetVertexColor(1, 1, 1)
        end
        factionLogo:ClearAllPoints()
        factionLogo:SetPoint("TOPRIGHT", GameTooltip, "TOPRIGHT", -10, -10)
        factionLogo:Show()
    else
        factionLogo:Hide()
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
-- 追加：每个地下城的最佳层数与分数（带图标，层数右对齐）
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
            if okFin and isFinished then
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
                right  = format("%s|cffffffff%s|r %s", pluses, levelNum, scoreText),
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
        -- 记录数值行（层数+分数），供等宽列右对齐
        colAlignLines[tooltip:NumLines()] = true
    end
end

-- ============================================================
-- 追加：团本进度（带图标，中文难度，右对齐）
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
                    -- 记录数值行（难度+进度），供等宽列右对齐
                    colAlignLines[tooltip:NumLines()] = true
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
    -- 非玩家单位也可能触发本回调，先隐藏徽记（防止从玩家移到 NPC 时残留）
    factionLogo:Hide()

    local unit
    if data and data.unit then
        unit = data.unit
    else
        _, unit = tooltip:GetUnit()
    end
    if not unit or (issecretvalue and issecretvalue(unit)) then return end
    if SafeBool(UnitIsPlayer(unit)) ~= true then return end

    -- 重置折叠行与等宽列记录
    collapsedLines = {}
    colAlignLines = {}

    -- ---- 阶段1：修改已有行（所有玩家） ----
    ModifyNameLine(tooltip, unit)
    ModifyGuildLine(tooltip, unit)
    ModifyLevelAndSpecLine(tooltip, unit)
    ModifyFactionLine(tooltip, unit)

    -- 记录追加区起点（阶段2新行），用于统一右对齐
    local appendStart = tooltip:NumLines() + 1

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

    -- ---- 阶段3：追加行右列右对齐 + 全局字号描边 + 数值列等宽 ----
    RightAlignLines(tooltip, appendStart)
    StyleFonts(tooltip)
    AlignNumericCols(tooltip)
    SingleLineAlign(tooltip, appendStart)

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
    factionLogo:Hide()
    RestoreAllFonts()
    Util:Debug("TooltipEnhance: 已禁用")
end
