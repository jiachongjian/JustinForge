-- ============================================================
-- JustinForge 模块9: 人物属性面板 (CharacterStats.lua)
-- ============================================================
-- 功能描述：
--   在屏幕上常态显示一个小巧的人物属性面板（无边框无背景），
--   固定按以下顺序展示：
--     1. 主属性（力量/敏捷/智力，自动识别当前专精主属性）
--     2. 副属性（暴击 / 急速 / 精通 / 全能，保留 1 位小数）
--     3. 第三属性（吸血 / 闪避 / 加速，仅当非 0 时显示，整数百分比）
--     4. 坦克属性（躲闪 / 招架 / 格挡，仅坦克专精且非 0 时显示，整数百分比）
--     5. 移速（当前属性决定的基础移动速度，整数百分比）
--   面板不支持拖动，位置由设置面板中的坐标滑条决定（屏幕中心为原点）。
--
-- 实现说明（抽取融合自 Stats+ 与 ExwindTools 两个插件）：
--   - 属性采集 API 与事件集来自两者的交集：
--       UnitStat / GetCritChance / GetHaste / GetMasteryEffect
--       GetCombatRatingBonus + GetVersatilityBonus（全能需两者相加，
--       只用前者会漏掉天赋/基础部分）
--       GetLifesteal / GetAvoidance / GetSpeed
--       GetDodgeChance / GetParryChance / GetBlockChance
--       移速 = 100% + GetSpeed()（加速第三属性加成，站立时也显示面板值）
--   - UI 采用 Stats+ 的「单 FontString 多行文本」方案（最轻量），
--     舍弃 ExwindTools 的逐行 Frame + 订阅架构和两者的全部设置项
--   - 全部属性走事件 + 0.1s 防抖合并刷新
--   - 12.0 secret value 兼容：部分属性返回值可能是 secret（不可比较/
--     算术/table.concat，但可 string.format 并经 SetFormattedText 显示），
--     所有比较/算术运算均经 pcall 保护
-- ============================================================

local addonName, ns = ...

local L = ns.L

-- 屏幕尺寸：坐标滑条范围（以屏幕中心为原点）
local screenWidth = math.floor(UIParent:GetWidth() or 1920)
local screenHeight = math.floor(UIParent:GetHeight() or 1080)
local halfWidth = math.floor(screenWidth / 2)
local halfHeight = math.floor(screenHeight / 2)

-- ============================================================
-- 模块注册（附带坐标设置项，Config.lua 自动生成为滑条）
-- ============================================================
local module = ns.Module:Register({
    key            = "characterStats",
    name           = L["CharacterStats_Name"],
    description    = L["CharacterStats_Desc"],
    defaultEnabled = true,
    options = {
        { type = "slider", key = "posX", name = L["CharacterStats_PosX"], min = -halfWidth,  max = halfWidth,  step = 1, default = 20 - halfWidth },
        { type = "slider", key = "posY", name = L["CharacterStats_PosY"], min = -halfHeight, max = halfHeight, step = 1, default = 0 },
    },
})

-- 面板与字体串（懒创建）
local statsFrame, statsText
-- 事件防抖标志：0.1s 内多次事件只刷新一次
local updatePending = false

-- ------------------------------------------------------------
-- IsSecret: 判断 12.0 secret value（旧版本无此 API，返回 false）
-- ------------------------------------------------------------
-- 注意 API 名为全小写 issecretvalue，与其他模块保持一致
local issecretvalue = _G.issecretvalue
local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
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
-- secret 值可传入 string.format，此时结果为 secret 字符串；
-- secret 字符串无法参与 table.concat，但可作为 SetFormattedText 的
-- 参数正常显示，因此不拦截直接返回，
-- 仅格式化抛错时回退显示 "?"
local function FormatPercent(v)
    local ok, text = pcall(string.format, "%.1f%%", v)
    if not ok or not text then return "?" end
    return text
end

local function FormatInt(v)
    local ok, text = pcall(string.format, "%d", v)
    if not ok or not text then return "?" end
    return text
end

-- 整数百分比（第三属性/坦克属性/移速使用）
-- secret 值无法参与四舍五入运算，退回 %.0f 格式化（结果向下取整）
local function FormatPercentInt(v)
    local ok, text = pcall(string.format, "%d%%", math.floor(v + 0.5))
    if ok and text then return text end
    ok, text = pcall(string.format, "%.0f%%", v)
    if not ok or not text then return "?" end
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
-- IsTankSpec: 当前专精是否为坦克职责
-- ------------------------------------------------------------
local function IsTankSpec()
    local spec = GetSpecialization and GetSpecialization()
    if not spec or not GetSpecializationRole then return false end
    local ok, role = pcall(GetSpecializationRole, spec)
    return ok and role == "TANK"
end

-- ------------------------------------------------------------
-- GetMoveSpeed: 属性决定的移动速度百分比（100% 基础 + 加速加成）
-- ------------------------------------------------------------
-- 站立时也显示面板值；secret 值导致算术失败时退回仅加速加成
local function GetMoveSpeed()
    local speed = GetSpeed()
    local ok, pct = pcall(function() return 100 + speed end)
    return ok and pct or speed
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

    -- 3. 第三属性（仅当非 0 时显示，整数百分比）
    local leech = GetLifesteal()
    if IsPositive(leech) then
        table.insert(lines, { L["CS_Leech"], FormatPercentInt(leech) })
    end
    local avoidance = GetAvoidance()
    if IsPositive(avoidance) then
        table.insert(lines, { L["CS_Avoidance"], FormatPercentInt(avoidance) })
    end
    local speed = GetSpeed()
    if IsPositive(speed) then
        table.insert(lines, { L["CS_Speed"], FormatPercentInt(speed) })
    end

    -- 4. 坦克属性（仅坦克专精且非 0 时显示，整数百分比）
    if IsTankSpec() then
        local dodge = GetDodgeChance()
        if IsPositive(dodge) then
            table.insert(lines, { L["CS_Dodge"], FormatPercentInt(dodge) })
        end
        local parry = GetParryChance()
        if IsPositive(parry) then
            table.insert(lines, { L["CS_Parry"], FormatPercentInt(parry) })
        end
        local block = GetBlockChance()
        if IsPositive(block) then
            table.insert(lines, { L["CS_Block"], FormatPercentInt(block) })
        end
    end

    -- 5. 移速（属性决定的基础移动速度，整数百分比）
    table.insert(lines, { L["CS_MoveSpeed"], FormatPercentInt(GetMoveSpeed()) })

    -- 拼接多行文本：标签金色 + 数值白色
    -- secret 字符串无法参与 table.concat，改用 SetFormattedText：
    -- 格式串只含普通字符串，可能为 secret 的文本作为参数传入，由客户端渲染
    local fmt = {}
    local values = {}
    for _, line in ipairs(lines) do
        table.insert(fmt, "|cffffd100%s|r |cffffffff%s|r")
        table.insert(values, line[1])
        table.insert(values, line[2])
    end
    statsText:SetFormattedText(table.concat(fmt, "\n"), unpack(values))

    -- 面板尺寸自适应文本（无边框背景，尺寸即文本尺寸）
    -- 文本含 secret 时宽高可能也是 secret（不可算术），pcall 保护，失败保持原尺寸
    local okSize, width, height = pcall(function()
        return statsText:GetStringWidth(), statsText:GetStringHeight()
    end)
    if okSize and width and height then
        statsFrame:SetSize(width, height)
    end
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
    local f = CreateFrame("Frame", "JustinForgeStatsFrame", UIParent)
    f:SetSize(120, 180)
    f:SetClampedToScreen(true)
    -- 无边框无背景，不拦截鼠标（纯文本展示）
    f:EnableMouse(false)

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetPoint("TOPLEFT", 0, 0)
    f.text:SetJustifyH("LEFT")
    f.text:SetSpacing(2)

    return f
end

-- ------------------------------------------------------------
-- ApplyPosition: 按 DB 中的坐标定位（屏幕中心为原点）
-- ------------------------------------------------------------
-- 面板左边缘锚定屏幕中心水平线、垂直中心对齐：
-- posX/posY 为相对屏幕中心的偏移（左/下为负，右/上为正）
local function ApplyPosition()
    local db = ns.db and ns.db.profile and ns.db.profile.characterStats
    statsFrame:ClearAllPoints()
    statsFrame:SetPoint("LEFT", UIParent, "CENTER",
        (db and db.posX) or (20 - halfWidth),
        (db and db.posY) or 0)
end

-- ------------------------------------------------------------
-- OnOptionChanged: 设置面板坐标滑条变化时即时重定位
-- ------------------------------------------------------------
function module:OnOptionChanged(key, value)
    if key == "posX" or key == "posY" then
        if statsFrame then
            ApplyPosition()
        end
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
    ApplyPosition()
    statsFrame:RegisterEvent("UNIT_STATS")
    statsFrame:RegisterEvent("COMBAT_RATING_UPDATE")
    statsFrame:RegisterEvent("MASTERY_UPDATE")
    statsFrame:RegisterEvent("LIFESTEAL_UPDATE")
    statsFrame:RegisterEvent("AVOIDANCE_UPDATE")
    statsFrame:RegisterEvent("SPEED_UPDATE")
    statsFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    statsFrame:RegisterEvent("PLAYER_AVG_ITEM_LEVEL_UPDATE")
    statsFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    statsFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
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
end
