-- ============================================================
-- JustinForge 模块14: 鼠标提示团本进度 (RaidProgressTooltip.lua)
-- ============================================================
-- 功能描述：
--   鼠标指向满级玩家时，在提示框中追加显示其【当前赛季】团本进度：
--   每个团本按 史诗 → 英雄 → 普通 → 随机 的顺序显示有击杀记录的难度，
--   格式为「难度缩写 + 已击杀/总Boss数」（如 M 6/6）；
--   某难度全通后不再检查更低难度（全通即封顶，低级难度视为已完成）。
--
-- 数据来源（实现逻辑参考 ElvUI_WindTools 的 Tooltips/Progression，
--   已去除全部 ElvUI 依赖，仅保留当前赛季团本）：
--   - 自己：GetStatistic(统计ID) 直接读取角色统计
--   - 其他玩家：成就对比 API（需加载 Blizzard_AchievementUI）
--       SetAchievementComparisonUnit(unit) 请求
--       → INSPECT_ACHIEVEMENT_READY 事件就绪
--       → GetComparisonStatistic(统计ID) 读取
--       → ClearAchievementComparisonUnit() 清理
--     受观察距离限制（与「观察」装备同理），超出距离时请求会静默失败
--   - 团本数据（统计ID/图标）取自 WindTools Core/Metadata.lua 的 W.RaidData
--
-- 实现原理：
--   1. TooltipDataProcessor.AddTooltipPostCall(Unit) 回调中取鼠标单位，
--      按 GUID 缓存进度数据 120 秒，避免频繁发起成就对比请求
--   2. 他人的数据就绪后若鼠标仍指向该玩家，调用 GameTooltip:SetUnit
--      刷新提示框，此时缓存命中直接渲染（不会形成递归请求）
--   3. 提示回调无法卸载，禁用时通过模块开关短路返回；
--      事件全部注销，实现零开销
--   4. 战斗中整体跳过：避免战斗中加载成就界面（LoadAddOn）产生污染
--
-- 新赛季维护（每个资料片赛季更新一次）：
--   1. 用本文件 CURRENT_SEASON_RAIDS 替换为新赛季团本
--   2. 统计ID来源：wowhead 角色统计页（achievements/character-statistics/
--      dungeons-and-raids/<资料片>/），按 随机/普通/英雄/史诗 分组；
--      或等 WindTools 更新后抄取其 Core/Metadata.lua 的 W.RaidData
--   3. 图标 tex 来源：https://wago.tools/db2/LFGDungeons（TypeID=2）
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local format = format
local ipairs = ipairs
local tonumber = tonumber

local CanInspect = CanInspect
local ClearAchievementComparisonUnit = ClearAchievementComparisonUnit
local GetComparisonStatistic = GetComparisonStatistic
local GetStatistic = GetStatistic
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local SetAchievementComparisonUnit = SetAchievementComparisonUnit
local UnitExists = UnitExists
local UnitGUID = UnitGUID
local UnitIsPlayer = UnitIsPlayer
local UnitIsUnit = UnitIsUnit
local UnitLevel = UnitLevel

local C_AddOns_IsAddOnLoaded = C_AddOns.IsAddOnLoaded

-- 12.x 秘密值检查（信息受限时单位 GUID 等不可使用），低版本客户端不存在该函数
local issecretvalue = _G.issecretvalue

local MAX_PLAYER_LEVEL = GetMaxLevelForPlayerExpansion()

-- 进度数据缓存有效期（秒），与 WindTools 一致取 120
local CACHE_TTL = 120

-- ============================================================
-- 配色方案（取自 WindTools，沿用物品品质色系）
-- ============================================================
-- 难度顺序固定：1 随机团队 / 2 普通 / 3 英雄 / 4 史诗
local DIFFICULTIES = {
    { name = "随机团队", abbr = "随机", color = "ff8000" },  -- 橙（传说品质色）
    { name = "普通",     abbr = "PT",   color = "1eff00" },  -- 绿（优秀品质色）
    { name = "英雄",     abbr = "H",    color = "0070dd" },  -- 蓝（精良品质色）
    { name = "史诗",     abbr = "M",    color = "a335ee" },  -- 紫（史诗品质色）
}

-- ============================================================
-- 当前赛季团本数据（「至暗之夜」第一赛季，12.0）
-- ============================================================
-- stats 子表按下标对应 DIFFICULTIES 的 4 个难度，
-- 每个元素为该难度下各 Boss 击杀次数的角色统计ID（非成就ID）
-- 上赛季团本（如法力熔炉Manaforge Omega 2805）不收录，保持「仅当前赛季」
local CURRENT_SEASON_RAIDS = {
    { -- 虚影尖塔（6 Boss）
        lfgID = 3094, name = "虚影尖塔", tex = 7507136,
        stats = {
            { 61288, 61292, 61284, 61280, 61296, 61276 },  -- 随机
            { 61297, 61281, 61277, 61293, 61289, 61285 },  -- 普通
            { 61278, 61290, 61298, 61282, 61294, 61286 },  -- 英雄
            { 61279, 61295, 61299, 61287, 61283, 61291 },  -- 史诗
        },
    },
    { -- 进军奎尔丹纳斯（2 Boss）
        lfgID = 3095, name = "奎尔丹纳斯", tex = 7480127,
        stats = {
            { 61300, 61304 },  -- 随机
            { 61305, 61301 },  -- 普通
            { 61302, 61306 },  -- 英雄
            { 61307, 61303 },  -- 史诗
        },
    },
    { -- 梦境裂隙（1 Boss）
        lfgID = 3165, name = "梦境裂隙", tex = 7570496,
        stats = {
            { 61474 },  -- 随机
            { 61475 },  -- 普通
            { 61476 },  -- 英雄
            { 61477 },  -- 史诗
        },
    },
}

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "raidProgressTooltip",
    name           = L["RaidProgressTooltip_Name"],
    description    = L["RaidProgressTooltip_Desc"],
    defaultEnabled = true,
})

-- 进度数据缓存：[guid] = { updated = 时间戳, raids = { [团本序号] = { [难度] = "x/y" } } }
local cache = {}

-- 已发出成就对比请求、等待数据就绪的 GUID 集合
local pendingGUIDs = {}

-- 成就界面（Blizzard_AchievementUI）是否已加载
local achievementUILoaded = false

-- ------------------------------------------------------------
-- SafeKillTimes: 安全读取某个 Boss 的击杀次数（兼容 12.0 secret value）
-- ------------------------------------------------------------
-- getStatFunc 为 GetStatistic（自己）或 GetComparisonStatistic（其他玩家）
-- 12.0 下返回值可能是 secret（比较/tonumber 会抛错），pcall 保护后保守返回 0
local function SafeKillTimes(getStatFunc, statID)
    local ok, value = pcall(getStatFunc, statID)
    if not ok or value == nil then return 0 end
    if issecretvalue and issecretvalue(value) then return 0 end
    return tonumber(value, 10) or 0
end

-- ------------------------------------------------------------
-- CollectRaidProgress: 采集指定玩家的团本进度并写入缓存
-- ------------------------------------------------------------
-- isSelf：true 用 GetStatistic，false 用 GetComparisonStatistic
-- （后者要求事先 SetAchievementComparisonUnit 成功且数据已就绪）
local function CollectRaidProgress(guid, isSelf)
    local getStatFunc = isSelf and GetStatistic or GetComparisonStatistic
    local raids

    for raidIndex, raid in ipairs(CURRENT_SEASON_RAIDS) do
        local progress
        -- 从史诗(4)向随机(1)逐难度统计有击杀的记录
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
                progress[difficulty] = format("%d/%d", killed, #statIDs)
                -- 该难度已全通：封顶，不再检查更低难度
                if killed == #statIDs then break end
            end
        end
        if progress then
            raids = raids or {}
            raids[raidIndex] = progress
        end
    end

    cache[guid] = { updated = GetTime(), raids = raids }
end

-- ------------------------------------------------------------
-- AddRaidLines: 将缓存中的进度渲染到提示框
-- ------------------------------------------------------------
local function AddRaidLines(tooltip, guid)
    local entry = cache[guid]
    if not entry or not entry.raids then return end

    tooltip:AddLine(" ")
    tooltip:AddLine(L["RPT_Header"], 1, 0.82, 0)

    for raidIndex, raid in ipairs(CURRENT_SEASON_RAIDS) do
        local progress = entry.raids[raidIndex]
        if progress then
            for difficulty = #DIFFICULTIES, 1, -1 do
                local text = progress[difficulty]
                if text then
                    local diff = DIFFICULTIES[difficulty]
                    -- 左侧：团本图标 + 团本名 + 彩色难度名
                    local left = format("|T%d:0|t %s |cff%s%s|r",
                        raid.tex, raid.name, diff.color, diff.name)
                    -- 右侧：彩色难度缩写 + 击杀进度
                    local right = format("|cff%s%s %s|r", diff.color, diff.abbr, text)
                    tooltip:AddDoubleLine(left, right, nil, nil, nil, 1, 1, 1)
                end
            end
        end
    end

    tooltip:Show()
end

-- ------------------------------------------------------------
-- RequestComparison: 对其他玩家发起成就对比请求（懒加载成就界面）
-- ------------------------------------------------------------
local function RequestComparison(unit, guid)
    -- 观察距离外的玩家无法对比，直接放弃（与「观察」装备的限制一致）
    if not CanInspect(unit) then return end

    -- 懒加载成就界面：仅在首次需要时加载，避免模块启用即占用内存
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

    -- SetAchievementComparisonUnit 由 Blizzard_AchievementUI 提供
    if not SetAchievementComparisonUnit then return end

    ClearAchievementComparisonUnit()
    local ok, result = pcall(SetAchievementComparisonUnit, unit)
    if ok and result then
        pendingGUIDs[guid] = true
    end
end

-- ------------------------------------------------------------
-- 事件处理：成就对比数据就绪
-- ------------------------------------------------------------
local progressFrame = CreateFrame("Frame")
progressFrame:SetScript("OnEvent", function(_, event, eventGUID)
    if event ~= "INSPECT_ACHIEVEMENT_READY" then return end
    if not eventGUID or not pendingGUIDs[eventGUID] then return end
    pendingGUIDs[eventGUID] = nil

    -- GUID 可能是 secret 值时无法作表键/比较，但此处它来自事件参数且
    -- 已成功作为表键写入过 pendingGUIDs，说明它是普通字符串
    CollectRaidProgress(eventGUID, false)
    ClearAchievementComparisonUnit()

    -- 鼠标仍指向该玩家时刷新提示框（重新触发提示回调，缓存命中直接渲染）
    if UnitExists("mouseover") then
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

-- ------------------------------------------------------------
-- OnTooltipUnit: 单位鼠标提示后置回调
-- ------------------------------------------------------------
local function OnTooltipUnit(tooltip)
    -- 回调无法卸载，通过模块开关短路（零开销）
    if not module.enabled then return end
    if tooltip ~= GameTooltip then return end
    -- 战斗中跳过：避免战斗中加载成就界面造成污染，且战斗中观察本就不可靠
    if InCombatLockdown() then return end

    local _, unit = tooltip:GetUnit()
    -- 单位本身可能是 secret 值，UnitIsPlayer 等 API 拒绝 secret 参数，直接跳过
    if not unit or (issecretvalue and issecretvalue(unit)) then return end
    if not UnitIsPlayer(unit) then return end
    -- 等级可能是 secret 值，pcall 保护，异常时保守跳过
    local okLevel, isMaxLevel = pcall(function() return UnitLevel(unit) == MAX_PLAYER_LEVEL end)
    if not okLevel or not isMaxLevel then return end

    local guid = UnitGUID(unit)
    if not guid or (issecretvalue and issecretvalue(guid)) then return end

    -- 缓存命中（120 秒内）直接渲染
    local entry = cache[guid]
    if entry and GetTime() - entry.updated < CACHE_TTL then
        AddRaidLines(tooltip, guid)
        return
    end

    -- 自己：直接读取角色统计，无需成就对比
    if UnitIsUnit(unit, "player") then
        CollectRaidProgress(guid, true)
        AddRaidLines(tooltip, guid)
        return
    end

    -- 其他玩家：发起成就对比请求，数据就绪后由事件回调刷新提示框
    RequestComparison(unit, guid)
end

-- 回调无法卸载，仅注册一次，内部通过 module.enabled 开关控制
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnTooltipUnit)

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
function module:OnEnable()
    progressFrame:RegisterEvent("INSPECT_ACHIEVEMENT_READY")
    Util:Debug("RaidProgressTooltip: 已启用")
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
function module:OnDisable()
    progressFrame:UnregisterAllEvents()
    -- 有未完成的对比请求时清理对比状态，避免占用成就界面对比槽
    ClearAchievementComparisonUnit()
    pendingGUIDs = {}
    Util:Debug("RaidProgressTooltip: 已禁用")
end
