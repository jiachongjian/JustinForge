-- ============================================================
-- JustinForge 模块9: 人物属性面板 (CharacterStats.lua)
-- ============================================================
-- 功能描述：
--   在屏幕上常态显示一个小巧的人物属性面板，固定按以下顺序展示：
--     1. 主属性（力量/敏捷/智力，自动识别当前专精主属性）
--     2. 副属性（暴击 / 急速 / 精通 / 全能）
--     3. 第三属性（吸血 / 闪避 / 加速，仅当非 0 时显示）
--     4. 坦克属性（护甲 / 躲闪 / 招架 / 格挡，仅当非 0 时显示）
--     5. 移动速度（实时当前速度百分比）
--   面板可用鼠标左键拖动，位置自动保存。
--
-- 实现说明（抽取融合自 Stats+ 与 ExwindTools 两个插件）：
--   - 属性采集 API 与事件集来自两者的交集：
--       UnitStat / GetCritChance / GetHaste / GetMasteryEffect
--       GetCombatRatingBonus + GetVersatilityBonus（全能需两者相加，
--       只用前者会漏掉天赋/基础部分）
--       GetLifesteal / GetAvoidance / GetSpeed / UnitArmor
--       GetDodgeChance / GetParryChance / GetBlockChance
--       GetUnitSpeed("player") / 7 * 100（7 码/秒 = 100% 基准移速）
--   - UI 采用 Stats+ 的「单 FontString 多行文本」方案（最轻量），
--     舍弃 ExwindTools 的逐行 Frame + 订阅架构和两者的全部设置项
--   - 移动速度变化频繁，不走事件，用 OnUpdate 节流刷新（0.25s）；
--     其余属性走事件 + 0.1s 防抖合并刷新
--   - 12.0 secret value 兼容：部分属性返回值可能是 secret（不可比较/
--     算术，但可 string.format），所有比较运算均经 pcall 保护
-- ============================================================

local addonName, ns = ...

local L = ns.L

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "characterStats",
    name           = L["CharacterStats_Name"],
    description    = L["CharacterStats_Desc"],
    defaultEnabled = true,
})

-- 面板与字体串（懒创建）
local statsFrame, statsText
-- 事件防抖标志：0.1s 内多次事件只刷新一次
local updatePending = false
-- OnUpdate 节流计时器（移动速度刷新间隔）
local speedElapsed = 0
local SPEED_INTERVAL = 0.25

-- ------------------------------------------------------------
-- IsSecret: 判断 12.0 secret value（旧版本无此 API，返回 false）
-- ------------------------------------------------------------
local function IsSecret(v)
    return IsSecretValue and IsSecretValue(v)
end

-- ------------------------------------------------------------
-- IsPositive: 判断数值是否大于 0（决定条件行是否显示）
-- ------------------------------------------------------------
-- secret 值无法比较，保守起见视为有效直接显示；
-- 普通数值经 pcall 保护比较，异常时视为 0 不显示
local function IsPositive(v)
    if v == nil then return false end
    if IsSecret(v) then return true end
    local ok, positive = pcall(function() return v > 0 end)
    return ok and positive == true
end

-- ------------------------------------------------------------
-- FormatPercent / FormatNumber: 安全格式化（兼容 secret 值）
-- ------------------------------------------------------------
-- secret 值可传入 string.format 但不能参与算术与字符串拼接；
-- 若格式化结果仍是 secret 字符串（无法参与后续颜色码拼接），显示 "?"
local function FormatPercent(v)
    local ok, text = pcall(string.format, "%.1f%%", v)
    if not ok or not text or IsSecret(text) then return "?" end
    return text
end

local function FormatInt(v)
    local ok, text = pcall(string.format, "%d", v)
    if not ok or not text or IsSecret(text) then return "?" end
    return text
end

-- ------------------------------------------------------------
-- GetPrimaryStat: 识别当前主属性
-- ------------------------------------------------------------
-- 比较力量(1)/敏捷(2)/智力(4)谁最大（UnitStat 索引跳过 3 耐力）
-- 比较失败（secret 等异常）时退回专精主属性常量
local function GetPrimaryStat()
    local str = UnitStat("player", 1)
    local agi = UnitStat("player", 2)
    local int = UnitStat("player", 4)
    local ok, name, value = pcall(function()
        if agi >= str and agi >= int then
            return L["CS_Agility"], agi
        elseif int >= str then
            return L["CS_Intellect"], int
        else
            return L["CS_Strength"], str
        end
    end)
    if ok then return name, value end
    return L["CS_Primary"], str
end

-- ------------------------------------------------------------
-- GetVersatility: 全能百分比 = 评分加成 + 其他来源加成
-- ------------------------------------------------------------
-- 12.0 下加法可能因 secret 值失败，失败时退回仅评分加成
local function GetVersatility()
    local ratingBonus = GetCombatRatingBonus(CR_VERSATILITY_DAMAGE_DONE)
    local ok, total = pcall(function()
        return ratingBonus + GetVersatilityBonus(CR_VERSATILITY_DAMAGE_DONE)
    end)
    return ok and total or ratingBonus
end

-- ------------------------------------------------------------
-- GetMoveSpeed: 实时移动速度百分比（7 码/秒 = 100%）
-- ------------------------------------------------------------
local function GetMoveSpeed()
    local current = GetUnitSpeed("player")
    local ok, pct = pcall(function() return (current / 7) * 100 end)
    return ok and pct or 0
end

-- ------------------------------------------------------------
-- Refresh: 重建全部属性文本
-- ------------------------------------------------------------
-- 行结构：{ label, valueText }；条件行值为 0 时直接跳过
local function Refresh()
    if not statsText then return end

    local lines = {}

    -- 1. 主属性（自动识别）
    local primaryName, primaryValue = GetPrimaryStat()
    table.insert(lines, { primaryName, FormatInt(primaryValue) })

    -- 2. 副属性（固定四项，始终显示）
    table.insert(lines, { L["CS_Crit"],    FormatPercent(GetCritChance()) })
    table.insert(lines, { L["CS_Haste"],   FormatPercent(GetHaste()) })
    table.insert(lines, { L["CS_Mastery"], FormatPercent(GetMasteryEffect()) })
    table.insert(lines, { L["CS_Versa"],   FormatPercent(GetVersatility()) })

    -- 3. 第三属性（仅当非 0 时显示）
    local leech = GetLifesteal()
    if IsPositive(leech) then
        table.insert(lines, { L["CS_Leech"], FormatPercent(leech) })
    end
    local avoidance = GetAvoidance()
    if IsPositive(avoidance) then
        table.insert(lines, { L["CS_Avoidance"], FormatPercent(avoidance) })
    end
    local speed = GetSpeed()
    if IsPositive(speed) then
        table.insert(lines, { L["CS_Speed"], FormatPercent(speed) })
    end

    -- 4. 坦克属性（仅当非 0 时显示）
    local _, armor = UnitArmor("player")
    if IsPositive(armor) then
        table.insert(lines, { L["CS_Armor"], FormatInt(armor) })
    end
    local dodge = GetDodgeChance()
    if IsPositive(dodge) then
        table.insert(lines, { L["CS_Dodge"], FormatPercent(dodge) })
    end
    local parry = GetParryChance()
    if IsPositive(parry) then
        table.insert(lines, { L["CS_Parry"], FormatPercent(parry) })
    end
    local block = GetBlockChance()
    if IsPositive(block) then
        table.insert(lines, { L["CS_Block"], FormatPercent(block) })
    end

    -- 5. 移动速度（实时）
    table.insert(lines, { L["CS_MoveSpeed"], FormatPercent(GetMoveSpeed()) })

    -- 拼接多行文本：标签金色 + 数值白色
    local parts = {}
    for _, line in ipairs(lines) do
        table.insert(parts, "|cffffd100" .. line[1] .. "|r |cffffffff" .. line[2] .. "|r")
    end
    statsText:SetText(table.concat(parts, "\n"))

    -- 面板尺寸自适应文本
    statsFrame:SetSize(
        statsText:GetStringWidth() + 16,
        statsText:GetStringHeight() + 16
    )
end

-- ------------------------------------------------------------
-- ScheduleRefresh: 事件防抖，0.1s 后合并刷新
-- ------------------------------------------------------------
local function ScheduleRefresh()
    if updatePending then return end
    updatePending = true
    C_Timer.After(0.1, function()
        updatePending = false
        Refresh()
    end)
end

-- ------------------------------------------------------------
-- CreateStatsFrame: 创建面板（懒创建，仅一次）
-- ------------------------------------------------------------
local function CreateStatsFrame()
    local f = CreateFrame("Frame", "JustinForgeStatsFrame", UIParent, "BackdropTemplate")
    f:SetSize(120, 180)
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.5)
    f:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.8)

    -- 左键拖动，拖动结束时保存位置
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        local db = ns.db and ns.db.profile and ns.db.profile.characterStats
        if db then
            db.point, db.posX, db.posY = point, x, y
        end
    end)

    -- 移动速度走 OnUpdate 节流刷新（速度变化不产生事件）
    f:SetScript("OnUpdate", function(_, elapsed)
        speedElapsed = speedElapsed + elapsed
        if speedElapsed >= SPEED_INTERVAL then
            speedElapsed = 0
            Refresh()
        end
    end)

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetPoint("TOPLEFT", 8, -8)
    f.text:SetJustifyH("LEFT")
    f.text:SetSpacing(2)

    return f
end

-- ------------------------------------------------------------
-- RestorePosition: 从 DB 恢复面板位置（默认屏幕左侧中部）
-- ------------------------------------------------------------
local function RestorePosition()
    local db = ns.db and ns.db.profile and ns.db.profile.characterStats
    statsFrame:ClearAllPoints()
    if db and db.point then
        statsFrame:SetPoint(db.point, UIParent, db.point, db.posX or 0, db.posY or 0)
    else
        statsFrame:SetPoint("LEFT", UIParent, "LEFT", 20, 0)
    end
end

-- ------------------------------------------------------------
-- OnEvent: 属性变化事件统一走防抖刷新
-- ------------------------------------------------------------
local function OnEvent(_, event, arg1)
    -- UNIT_STATS 等 unit 事件只关心玩家自己
    if event == "UNIT_STATS" and arg1 ~= "player" then return end
    ScheduleRefresh()
end

-- ------------------------------------------------------------
-- OnEnable: 创建并显示面板，注册属性事件
-- ------------------------------------------------------------
function module:OnEnable()
    if not statsFrame then
        statsFrame = CreateStatsFrame()
        statsText = statsFrame.text
        statsFrame:SetScript("OnEvent", OnEvent)
    end
    RestorePosition()
    statsFrame:RegisterEvent("UNIT_STATS")
    statsFrame:RegisterEvent("COMBAT_RATING_UPDATE")
    statsFrame:RegisterEvent("MASTERY_UPDATE")
    statsFrame:RegisterEvent("LIFESTEAL_UPDATE")
    statsFrame:RegisterEvent("AVOIDANCE_UPDATE")
    statsFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    statsFrame:RegisterEvent("PLAYER_AVG_ITEM_LEVEL_UPDATE")
    statsFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    statsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    statsFrame:Show()
    Refresh()
end

-- ------------------------------------------------------------
-- OnDisable: 解绑事件并隐藏面板（零开销）
-- ------------------------------------------------------------
function module:OnDisable()
    if statsFrame then
        statsFrame:UnregisterAllEvents()
        statsFrame:Hide()
    end
    speedElapsed = 0
end
