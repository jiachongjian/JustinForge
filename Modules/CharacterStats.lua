-- ============================================================
-- JustinForge 模块9: 人物属性面板 (CharacterStats.lua)
-- ============================================================
-- 功能描述：
--   在屏幕上常态显示一个小巧的人物属性面板（无边框无背景），
--   固定按以下顺序展示：
--     1. 主属性（力量/敏捷/智力，按当前专精自动识别）
--     2. 副属性（暴击 / 急速 / 精通 / 全能，整数百分比）
--     3. 第三属性（吸血 / 闪避 / 加速，仅当非 0 时显示，整数百分比）
--     4. 坦克属性（躲闪 / 招架 / 格挡，仅坦克专精且非 0 时显示，整数百分比）
--     5. 移速（实时移动速度百分比，100% = 基础跑步速度，每秒刷新）
--   面板左上角为锚点、向右下扩展，不支持拖动，
--   位置由设置面板中的坐标滑条决定（屏幕中心为原点）。
--   每行格式为「名称  数值」：名称与数值同色、间隔两个空格（按属性类型着色，
--   主属性为当前职业色）。文字固定细描边，字号/行间距可在设置面板中调整。
--
-- 实现说明（数据计算/条件层以 ExwindTools 的 PStat_* 采集逻辑为蓝本从底层重构）：
--   - 主属性：专精 ID 查表确定主属性类型（避免数值比较，对 12.0 secret value
--     天然安全），数值取 UnitStat 第二返回值（effective，含装备/Buff 的面板总值）
--   - 暴击：GetSpellCritChance()（与参考插件统一口径）
--   - 全能：GetCombatRatingBonus + GetVersatilityBonus 相加（只用前者会漏掉
--     天赋/基础部分）；非 secret 时按专精校准 zeroValue 并存入 DB，
--     secret 时用技能描述反推估算，估算不可用退回 "x% + y%" 双段显示
--   - 移速：GetUnitSpeed("player") 第二返回值 / 7 * 100（7 = 基础跑步速度），
--     1 秒 Ticker 驱动刷新，脱离事件降低开销；secret 时原样 %.1f 显示
--   - 坦克判定：专精表查坦克标志，表外专精回退 GetSpecializationRole API
--   - 事件：对齐参考事件集合（含 UNIT_AURA 覆盖属性类 Buff、SPELL_TEXT_UPDATE
--     配合描述解析），unit 事件过滤玩家 + 0.1s 防抖合并刷新
--   - 12.0 secret value 兼容：值不可比较/算术/table.concat，可 string.format
--     并经 SetFormattedText 显示；所有比较/算术运算均经 pcall 保护
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
        { type = "slider", key = "fontSize", name = L["CharacterStats_FontSize"], min = 8, max = 24, step = 1, default = 12 },
        { type = "slider", key = "lineSpacing", name = L["CharacterStats_LineSpacing"], min = 0, max = 12, step = 1, default = 2 },
        { type = "checkbox", key = "showTertiary", name = L["CharacterStats_ShowTertiary"], default = true },
    },
})

-- 面板（懒创建；文本挂于 statsFrame.statText）
local statsFrame
-- 事件防抖标志：0.1s 内多次事件只刷新一次
local updatePending = false
-- 移速刷新计时器（OnEnable 启动，OnDisable 取消，禁用后零开销）
local moveSpeedTicker = nil

-- ------------------------------------------------------------
-- 专精信息表：specID → 主属性 UnitStat 索引(1=力量 2=敏捷 4=智力) + 坦克标志
-- ------------------------------------------------------------
-- 数据来源：ExwindTools ExwindDB.Specs（12.0 全专精，含噬灭恶魔猎手）
-- 查表法替代数值大小比较：secret value 下 UnitStat 返回值不可比较，查表天然安全
local SPEC_INFO = {
    -- 法师（智力）
    [62] = { primary = 4 }, [63] = { primary = 4 }, [64] = { primary = 4 },
    -- 圣骑士（神圣智力 / 防护·惩戒力量）
    [65] = { primary = 4 }, [66] = { primary = 1, tank = true }, [70] = { primary = 1 },
    -- 战士（力量）
    [71] = { primary = 1 }, [72] = { primary = 1 }, [73] = { primary = 1, tank = true },
    -- 德鲁伊（平衡·恢复智力 / 野性·守护敏捷）
    [102] = { primary = 4 }, [103] = { primary = 2 }, [104] = { primary = 2, tank = true }, [105] = { primary = 4 },
    -- 死亡骑士（力量）
    [250] = { primary = 1, tank = true }, [251] = { primary = 1 }, [252] = { primary = 1 },
    -- 猎人（敏捷）
    [253] = { primary = 2 }, [254] = { primary = 2 }, [255] = { primary = 2 },
    -- 牧师（智力）
    [256] = { primary = 4 }, [257] = { primary = 4 }, [258] = { primary = 4 },
    -- 潜行者（敏捷）
    [259] = { primary = 2 }, [260] = { primary = 2 }, [261] = { primary = 2 },
    -- 萨满祭司（元素·恢复智力 / 增强敏捷）
    [262] = { primary = 4 }, [263] = { primary = 2 }, [264] = { primary = 4 },
    -- 术士（智力）
    [265] = { primary = 4 }, [266] = { primary = 4 }, [267] = { primary = 4 },
    -- 武僧（酒仙·踏风敏捷 / 织雾智力）
    [268] = { primary = 2, tank = true }, [269] = { primary = 2 }, [270] = { primary = 4 },
    -- 恶魔猎手（浩劫·复仇敏捷 / 噬灭智力）
    [577] = { primary = 2 }, [581] = { primary = 2, tank = true }, [1480] = { primary = 4 },
    -- 唤魔师（智力）
    [1467] = { primary = 4 }, [1468] = { primary = 4 }, [1473] = { primary = 4 },
}

-- 主属性 UnitStat 索引 → 本地化标签键
local PRIMARY_LABEL_KEY = {
    [1] = "CS_Strength",
    [2] = "CS_Agility",
    [4] = "CS_Intellect",
}

-- ------------------------------------------------------------
-- 属性配色表（名称与数值同色）
-- ------------------------------------------------------------
-- 融合 ExwindTools（高饱和）与 Stats+（全属性独立色/分层）方案：
--   副属性红/绿/黄/蓝四基色高饱和；第三属性中饱和；坦克属性低饱和 pastel；
--   主属性为当前角色职业色（角色固定，OnEnable 时缓存一次；
--   文件加载期 player 可能未就绪，故不在此处取值）
local STAT_COLORS = {
    crit      = "FF4D5B", -- 红
    haste     = "66E066", -- 绿
    mastery   = "F2D33C", -- 黄
    vers      = "55A9FF", -- 蓝
    leech     = "D17BFF", -- 紫
    avoidance = "FF9F40", -- 橙
    speed     = "FF8FD3", -- 粉（第三属性·加速）
    dodge     = "D9D9A6", -- 米黄
    parry     = "A6D9D9", -- 淡青
    block     = "BFBFBF", -- 银灰
    movespeed = "5FE8D4", -- 亮青
    primary   = "FFD100", -- 占位金，OnEnable 时替换为职业色
}

-- GenerateHexColor 返回 AARRGGBB，sub(3) 取 RRGGBB；异常时保留占位金
local function CacheClassColor()
    local _, classFile = UnitClass("player")
    local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if color then
        STAT_COLORS.primary = color:GenerateHexColor():sub(3)
    end
end

-- ------------------------------------------------------------
-- IsSecret: 判断 12.0 secret value（旧版本无此 API，返回 false）
-- ------------------------------------------------------------
-- 注意 API 名为全小写 issecretvalue，与其他模块保持一致
local function IsSecret(v)
    return type(issecretvalue) == "function" and issecretvalue(v)
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
-- FormatInt / FormatPercentInt: 安全格式化（兼容 secret 值）
-- ------------------------------------------------------------
-- secret 值可传入 string.format，此时结果为 secret 字符串；
-- secret 字符串无法参与 table.concat，但可作为 SetFormattedText 的
-- 参数正常显示，因此不拦截直接返回，仅格式化抛错时回退显示 "?"
local function FormatInt(v)
    local ok, text = pcall(string.format, "%d", v)
    if not ok or not text then return "?" end
    return text
end

-- 整数百分比（副属性/第三属性/坦克属性统一使用）
-- %.0f 自带舍入，避免 math.floor(v+0.5) 算术触犯 secret 禁忌
local function FormatPercentInt(v)
    local ok, text = pcall(string.format, "%.0f%%", v)
    if not ok or not text then return "?" end
    return text
end

-- ------------------------------------------------------------
-- GetCurrentSpecID: 当前专精 ID（未加载/异常时返回 0）
-- ------------------------------------------------------------
local function GetCurrentSpecID()
    if not (GetSpecialization and GetSpecializationInfo) then return 0 end
    local specIndex = GetSpecialization()
    if not specIndex or specIndex <= 0 then return 0 end
    local specID = GetSpecializationInfo(specIndex)
    return (type(specID) == "number") and specID or 0
end

-- ------------------------------------------------------------
-- GetPrimaryStat: 识别当前主属性（参考插件查表法）
-- ------------------------------------------------------------
-- 数值取 UnitStat 第二返回值（effective，含装备/Buff 的面板总值）；
-- 专精表未收录时回退比较大小（pcall 防 secret 比较异常）
local function GetPrimaryStat()
    local _, str = UnitStat("player", 1)
    local _, agi = UnitStat("player", 2)
    local _, int = UnitStat("player", 4)

    local info = SPEC_INFO[GetCurrentSpecID()]
    if info then
        local idx = info.primary
        local value = (idx == 1) and str or (idx == 2) and agi or int
        return L[PRIMARY_LABEL_KEY[idx]], value
    end

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
-- 全能校准体系（移植自参考插件，应对 12.0 secret value 场景）
-- ------------------------------------------------------------
-- 原理：1271074 的技能描述数值随全能缩放。平时（非 secret）记录
--   zeroValue = 描述值 / (1 + 全能%/100)，按专精绑定存入 DB；
--   secret 时描述值仍可读，反推 全能% = (描述值/zeroValue - 1) * 100
local VERSA_ESTIMATE_SPELL_ID = 1271074

-- 从文本中提取最大正数（去除颜色/图标转义，兼容千分位逗号）
local function ExtractLargestNumberFromText(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end

    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")
    text = text:gsub("|T.-|t", "")

    local largestValue
    for numStr in text:gmatch("([%d,，%.]+)") do
        local value = tonumber((numStr:gsub("[,，]", "")))
        if value and value > 0 and (not largestValue or value > largestValue) then
            largestValue = value
        end
    end

    return largestValue
end

local function GetVersaDescriptionValue()
    if not C_Spell or type(C_Spell.GetSpellDescription) ~= "function" then
        return nil
    end
    return ExtractLargestNumberFromText(C_Spell.GetSpellDescription(VERSA_ESTIMATE_SPELL_ID))
end

-- 校准数据存于 JustinForgeDB.profile.characterStats.versaCalibration（运行时懒创建）
local function GetVersaCalibration()
    local db = ns.db and ns.db.profile and ns.db.profile.characterStats
    if not db then return nil end
    if type(db.versaCalibration) ~= "table" then
        db.versaCalibration = {}
    end
    return db.versaCalibration
end

local function LearnVersaZeroValue(currentVersa)
    if type(currentVersa) ~= "number" or currentVersa <= -99.9 then
        return
    end

    local descriptionValue = GetVersaDescriptionValue()
    if type(descriptionValue) ~= "number" or descriptionValue <= 0 then
        return
    end

    local zeroValue = descriptionValue / (1 + currentVersa / 100)
    if zeroValue <= 0 then
        return
    end

    local calibration = GetVersaCalibration()
    if not calibration then return end
    calibration.spellID = VERSA_ESTIMATE_SPELL_ID
    calibration.specID = GetCurrentSpecID()
    calibration.zeroValue = zeroValue
    calibration.lastDescriptionValue = descriptionValue
end

local function EstimateVersaFromDescription()
    local calibration = GetVersaCalibration()
    if type(calibration) ~= "table" then
        return nil
    end

    -- 校准值与专精绑定，换专精后需重新学习
    local zeroValue = tonumber(calibration.zeroValue) or 0
    if zeroValue <= 0 or (tonumber(calibration.specID) or 0) ~= GetCurrentSpecID() then
        return nil
    end

    local descriptionValue = GetVersaDescriptionValue()
    if type(descriptionValue) ~= "number" or descriptionValue <= 0 then
        return nil
    end

    calibration.lastDescriptionValue = descriptionValue

    local estimatedVersa = ((descriptionValue / zeroValue) - 1) * 100
    if estimatedVersa < 0 then
        estimatedVersa = 0
    end

    return estimatedVersa
end

-- ------------------------------------------------------------
-- GetVersatilityText: 全能百分比文本 = 评分加成 + 其他来源加成
-- ------------------------------------------------------------
-- 非 secret：相加显示并校准 zeroValue；
-- 任一 secret：优先校准估算值，估算不可用退回 "x% + y%" 双段显示
-- （string.format 可携带 secret 值，由客户端渲染）
local function GetVersatilityText()
    local ratingBonus = GetCombatRatingBonus(CR_VERSATILITY_DAMAGE_DONE)
    local auraBonus = GetVersatilityBonus(CR_VERSATILITY_DAMAGE_DONE)

    if IsSecret(ratingBonus) or IsSecret(auraBonus) then
        local estimatedVersa = EstimateVersaFromDescription()
        if type(estimatedVersa) == "number" then
            return string.format("%.0f%%", estimatedVersa)
        end
        local ok, text = pcall(string.format, "%.0f%% + %.0f%%", ratingBonus, auraBonus)
        if ok and text then return text end
        return "?"
    end

    if type(ratingBonus) == "number" and type(auraBonus) == "number" then
        local totalVersa = ratingBonus + auraBonus
        LearnVersaZeroValue(totalVersa)
        return string.format("%.0f%%", totalVersa)
    end

    return FormatPercentInt(ratingBonus)
end

-- ------------------------------------------------------------
-- IsTankSpec: 当前专精是否为坦克职责（专精表查坦克标志）
-- ------------------------------------------------------------
-- 表外专精（新专精未收录）回退 GetSpecializationRole API
local function IsTankSpec()
    local info = SPEC_INFO[GetCurrentSpecID()]
    if info then
        return info.tank == true
    end
    local spec = GetSpecialization and GetSpecialization()
    if not spec or not GetSpecializationRole then return false end
    local ok, role = pcall(GetSpecializationRole, spec)
    return ok and role == "TANK"
end

-- ------------------------------------------------------------
-- GetMoveSpeedText: 实时移动速度百分比文本（100% = 基础跑步速度 7 码/秒）
-- ------------------------------------------------------------
-- 参考插件口径：取 GetUnitSpeed 第二返回值（当前移动速度），站立时为 0%；
-- %.0f 自带舍入，规避 (speed/7)*100 的浮点截断（99.999 → 100）；
-- secret 值无法算术，退回原样 %.1f 显示
local function GetMoveSpeedText()
    local _, runSpeed = GetUnitSpeed("player")
    if runSpeed == nil then return "?" end
    if IsSecret(runSpeed) then
        local ok, text = pcall(string.format, "%.1f", runSpeed)
        return (ok and text) or "?"
    end
    local ok, text = pcall(string.format, "%.0f%%", (runSpeed / 7) * 100)
    return (ok and text) or "?"
end

-- ------------------------------------------------------------
-- Refresh: 重建全部属性文本
-- ------------------------------------------------------------
-- 行结构：{ label, valueText, colorKey }；条件行值为 0 时直接跳过
local function Refresh()
    if not statsFrame then return end

    local lines = {}

    -- 1. 主属性（按专精自动识别，职业色）
    local primaryName, primaryValue = GetPrimaryStat()
    table.insert(lines, { primaryName, FormatInt(primaryValue), "primary" })

    -- 2. 副属性（固定四项，始终显示，整数百分比）
    table.insert(lines, { L["CS_Crit"],    FormatPercentInt(GetSpellCritChance()), "crit" })
    table.insert(lines, { L["CS_Haste"],   FormatPercentInt(GetHaste()),           "haste" })
    table.insert(lines, { L["CS_Mastery"], FormatPercentInt(GetMasteryEffect()),   "mastery" })
    table.insert(lines, { L["CS_Versa"],   GetVersatilityText(),                "vers" })

    -- 3. 第三属性（可在设置中关闭；仅当非 0 时显示，整数百分比）
    -- 注意此处不能调用下方才声明的 GetOption（Lua 局部变量前置可见性），
    -- 直接读取 DB：键缺失或为 false 以外的值时视为开启（默认 true）
    local db = ns.db and ns.db.profile and ns.db.profile.characterStats
    if not db or db.showTertiary ~= false then
        local leech = GetLifesteal()
        if IsPositive(leech) then
            table.insert(lines, { L["CS_Leech"], FormatPercentInt(leech), "leech" })
        end
        local avoidance = GetAvoidance()
        if IsPositive(avoidance) then
            table.insert(lines, { L["CS_Avoidance"], FormatPercentInt(avoidance), "avoidance" })
        end
        local speed = GetSpeed()
        if IsPositive(speed) then
            table.insert(lines, { L["CS_Speed"], FormatPercentInt(speed), "speed" })
        end
    end

    -- 4. 坦克属性（仅坦克专精且非 0 时显示，整数百分比）
    if IsTankSpec() then
        local dodge = GetDodgeChance()
        if IsPositive(dodge) then
            table.insert(lines, { L["CS_Dodge"], FormatPercentInt(dodge), "dodge" })
        end
        local parry = GetParryChance()
        if IsPositive(parry) then
            table.insert(lines, { L["CS_Parry"], FormatPercentInt(parry), "parry" })
        end
        local block = GetBlockChance()
        if IsPositive(block) then
            table.insert(lines, { L["CS_Block"], FormatPercentInt(block), "block" })
        end
    end

    -- 5. 移速（实时移动速度百分比，由 Ticker 驱动每秒刷新）
    table.insert(lines, { L["CS_MoveSpeed"], GetMoveSpeedText(), "movespeed" })

    -- 单列拼接：每行「|cff色名称  数值|r」，名称与数值同色、间隔两个空格；
    -- secret 字符串无法参与 table.concat，改用 SetFormattedText：
    -- 格式串只含普通字符串（颜色码同理），可能为 secret 的文本作为参数传入，由客户端渲染
    local fmt, values = {}, {}
    for _, line in ipairs(lines) do
        local color = STAT_COLORS[line[3]] or "FFD100"
        table.insert(fmt, "|cff" .. color .. "%s  %s|r")
        table.insert(values, line[1])
        table.insert(values, line[2])
    end
    statsFrame.statText:SetFormattedText(table.concat(fmt, "\n"), unpack(values))

    -- 面板尺寸自适应文本（宽 = 最长行宽）；文本含 secret 时宽高可能也是
    -- secret（不可算术），pcall 保护，失败保持原尺寸
    pcall(function()
        statsFrame:SetSize(statsFrame.statText:GetStringWidth(), statsFrame.statText:GetStringHeight())
    end)
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
-- GetOption: 读取模块设置项（DB 缺失时回退默认值）
-- ------------------------------------------------------------
local function GetOption(key, default)
    local db = ns.db and ns.db.profile and ns.db.profile.characterStats
    local value = db and db[key]
    if value == nil then return default end
    return value
end

-- ------------------------------------------------------------
-- ApplyFontAndSpacing: 按设置项应用字号/行间距
-- ------------------------------------------------------------
local function ApplyFontAndSpacing()
    if not statsFrame or not statsFrame.fontPath then return end
    local fontSize = GetOption("fontSize", 12)
    local spacing = GetOption("lineSpacing", 2)
    -- 文字固定细描边（OUTLINE）
    statsFrame.statText:SetFont(statsFrame.fontPath, fontSize, "OUTLINE")
    statsFrame.statText:SetSpacing(spacing)
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

    -- 单列文本：锚定面板左上角，左对齐（面板左上角即锚点，向右下扩展）
    f.statText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.statText:SetPoint("TOPLEFT", 0, 0)
    f.statText:SetJustifyH("LEFT")

    -- 缓存模板默认字体路径（字号/描边由设置项控制，经 SetFont 应用）
    f.fontPath = f.statText:GetFont()

    return f
end

-- ------------------------------------------------------------
-- ApplyPosition: 按 DB 中的坐标定位（屏幕中心为原点）
-- ------------------------------------------------------------
-- 面板左上角锚定定位点，文本向右下扩展：
-- posX/posY 为相对屏幕中心的偏移（左/下为负，右/上为正）
local function ApplyPosition()
    statsFrame:ClearAllPoints()
    statsFrame:SetPoint("TOPLEFT", UIParent, "CENTER",
        GetOption("posX", 20 - halfWidth),
        GetOption("posY", 0))
end

-- ------------------------------------------------------------
-- OnOptionChanged: 设置项变化时即时生效（坐标重定位 / 字体与间距重设）
-- ------------------------------------------------------------
function module:OnOptionChanged(key, value)
    if not statsFrame then return end
    if key == "posX" or key == "posY" then
        ApplyPosition()
    elseif key == "fontSize" or key == "lineSpacing" then
        ApplyFontAndSpacing()
        Refresh()
    elseif key == "showTertiary" then
        Refresh()
    end
end

-- ------------------------------------------------------------
-- OnEvent: 属性变化事件统一走防抖刷新
-- ------------------------------------------------------------
local function OnEvent(_, event, arg1)
    -- UNIT_* 事件只关心玩家自己（其他事件的第二参数可能是 slot 等非 unit 值）
    if (event == "UNIT_STATS" or event == "UNIT_AURA") and arg1 ~= "player" then return end
    ScheduleRefresh()
end

-- ------------------------------------------------------------
-- OnEnable: 创建并显示面板，注册属性事件，启动移速计时器
-- ------------------------------------------------------------
function module:OnEnable()
    if not statsFrame then
        statsFrame = CreateStatsFrame()
        statsFrame:SetScript("OnEvent", OnEvent)
    end
    ApplyFontAndSpacing()
    ApplyPosition()
    CacheClassColor()
    -- 事件集合对齐参考插件：
    --   UNIT_AURA(player) 覆盖属性类 Buff 变化（触发频繁，靠防抖合并）
    --   SPELL_TEXT_UPDATE 技能描述异步加载完成（配合全能校准的描述解析）
    statsFrame:RegisterEvent("UNIT_STATS")
    statsFrame:RegisterEvent("UNIT_AURA")
    statsFrame:RegisterEvent("COMBAT_RATING_UPDATE")
    statsFrame:RegisterEvent("MASTERY_UPDATE")
    statsFrame:RegisterEvent("LIFESTEAL_UPDATE")
    statsFrame:RegisterEvent("AVOIDANCE_UPDATE")
    statsFrame:RegisterEvent("SPEED_UPDATE")
    statsFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    statsFrame:RegisterEvent("PLAYER_AVG_ITEM_LEVEL_UPDATE")
    statsFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    statsFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
    statsFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    statsFrame:RegisterEvent("SPELL_TEXT_UPDATE")
    statsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- 移速每秒刷新（脱离事件以降低开销，参考插件同款方案）
    if moveSpeedTicker then
        moveSpeedTicker:Cancel()
    end
    moveSpeedTicker = C_Timer.NewTicker(1, ScheduleRefresh)
    statsFrame:Show()
    Refresh()
end

-- ------------------------------------------------------------
-- OnDisable: 解绑事件、停止计时器并隐藏面板（零开销）
-- ------------------------------------------------------------
function module:OnDisable()
    if moveSpeedTicker then
        moveSpeedTicker:Cancel()
        moveSpeedTicker = nil
    end
    if statsFrame then
        statsFrame:UnregisterAllEvents()
        statsFrame:Hide()
    end
end
