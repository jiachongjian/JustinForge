-- ============================================================
-- JustinForge 模块19: 装备错误提醒 (EquipmentAlert.lua)
-- ============================================================
-- 功能：当检测到明显的装备错误时，在屏幕上显示白色文字提醒
--   （多条提醒以设定位置为顶部锚点向下堆叠；战斗中自动隐藏，
--   脱战后恢复）。检测内容：
--     1. 工程学腰带：已学习工程学，但未装备腰带，
--        或腰带未附魔「氮气推进器」（附魔ID 4223）
--     2. 武器缺失：未装备主手武器；主手为单手武器（含魔杖）
--        时副手为空；双持专精主手为单手武器时副手未装备武器
--     3. 专精匹配：
--        - 武器主属性与当前专精主属性不符
--          （如狂徒切敏锐后仍用敏捷外的错误属性武器/
--          惩戒切防护后仍用双手力量武器场景的主手检测）
--        - 刺杀/敏锐贼：需要双持匕首
--        - 奶骑/防护骑/防护战：需要单手武器 + 盾牌
--        - 生存猎：需要双手近战武器（拿弓枪弩/单手武器时
--          猛禽一击、猫鼬撕咬等核心技能无法施放）
--
-- 实现要点：
--   - 工程学判定：GetProfessions → GetProfessionInfo 的
--     skillLine == 202（工程学基础技能线，跨资料片不变）
--   - 氮气推进器：物品链接字段解析，item:itemID:enchantID:...
--     第 3 段为附魔ID，氮气推进器固定为 4223
--   - 专精判定：GetSpecialization + GetSpecializationInfo
--     第 6 返回值为专精主属性（1=力量 2=敏捷 4=智力）
--   - 武器类别判定：C_Item.GetItemInfoInstant 的
--     classID/subclassID（武器=2，匕首=15；护甲=4，盾牌=6），
--     不受客户端语言影响
--   - 武器主属性：GetItemStats 取
--     ITEM_MOD_STRENGTH_SHORT / AGILITY / INTELLECT 中最高项，
--     武器无主属性（旧世界武器等）时跳过该项检测避免误报
--   - 刷新触发：装备变更 / 专精切换 / 技能线变化（学专业）/
--     背包变化（补附魔），0.2 秒合并节流
--   - 提醒颜色固定白色（用户要求），仅位置与字号可配置
--   - 12.0 安全值防护：比较/算术前一律 issecretvalue 防护
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local ipairs = ipairs
local wipe = wipe
local tonumber = tonumber
local type = type
local strsplit = strsplit
local issecretvalue = _G.issecretvalue

-- 屏幕尺寸在文件加载时即可获取，作为坐标滑条上限
local screenWidth = math.floor(UIParent:GetWidth() or 1920)
local screenHeight = math.floor(UIParent:GetHeight() or 1080)
local halfWidth = math.floor(screenWidth / 2)
local halfHeight = math.floor(screenHeight / 2)

-- ------------------------------------------------------------
-- 常量
-- ------------------------------------------------------------
local DEFAULT_FONT_SIZE = 18
local LINE_SPACING = 4          -- 相邻提醒行间距（px）
local SCAN_THROTTLE = 0.2       -- 扫描合并节流（秒）
local ENGINEERING_SKILL_LINE = 202  -- 工程学基础技能线ID
local NITRO_BOOST_ENCHANT = 4223    -- 氮气推进器附魔ID
local SLOT_WAIST = 6
local SLOT_MAINHAND = 16
local SLOT_OFFHAND = 17

-- 物品类别（GetItemInfoInstant 返回的 classID/subclassID）
local CLASS_WEAPON = 2
local SUBCLASS_DAGGER = 15
local CLASS_ARMOR = 4
local SUBCLASS_SHIELD = 6

-- 专精规则表（key = specID）
-- 需要单手武器+盾牌的专精：奶骑(65)、防护骑(66)、防护战(73)
local SHIELD_SPECS = { [65] = true, [66] = true, [73] = true }
-- 需要双持匕首的专精：刺杀(259)、敏锐(261)
local DAGGER_SPECS = { [259] = true, [261] = true }
-- 需要双手近战武器的专精：生存猎(255)
-- （猛禽一击/猫鼬撕咬等核心技能强制要求双手近战武器，
--   拿弓枪弩或单手武器时技能无法施放）
local MELEE_2H_SPECS = { [255] = true }
-- 双持专精：主手为单手武器时副手必须有武器
-- 狂暴战(72) 冰DK(251) 三系贼(259/260/261) 增强萨(263)
-- 酒仙(268) 踏风(269) 浩劫(577) 复仇(581)
local DUAL_WIELD_SPECS = {
    [72] = true, [251] = true,
    [259] = true, [260] = true, [261] = true,
    [263] = true, [268] = true, [269] = true,
    [577] = true, [581] = true,
}

-- 双手武器装备位置（这些位置装备的武器不要求副手）
-- 注意：魔杖（INVTYPE_RANGEDRIGHT）不在此列——魔杖是装在
-- 主手槽位的单手武器，需要搭配副手物品
local TWO_HAND_LOCS = {
    ["INVTYPE_2HWEAPON"] = true,
    ["INVTYPE_RANGED"] = true,
}

-- 武器主属性检测键（GetItemStats 表键，顺序对应 STAT_INDEX）
local STAT_KEYS = {
    "ITEM_MOD_STRENGTH_SHORT",
    "ITEM_MOD_AGILITY_SHORT",
    "ITEM_MOD_INTELLECT_SHORT",
}
-- 专精主属性（1=力量 2=敏捷 4=智力）→ 通用下标（1/2/3）
local SPEC_STAT_INDEX = { [1] = 1, [2] = 2, [4] = 3 }

-- GetItemStats 兼容封装（12.0 命名空间 API 优先）
local GetItemStatsFunc = (C_Item and C_Item.GetItemStats) or GetItemStats

-- ============================================================
-- 模块注册
-- ============================================================
-- 不声明 subcategory：模块显示在主设置页，以模块名为分类标题
-- （已列入 Config.lua 的 CATEGORY_LAYOUT 单模块分组）
local module = ns.Module:Register({
    key            = "equipmentAlert",
    name           = L["EA_Name"],
    description    = L["EA_Desc"],
    defaultEnabled = true,

    options = {
        { type = "slider", key = "posX",     name = L["EA_PosX"],     tooltip = L["EA_PosTip"],     min = -halfWidth,  max = halfWidth,  step = 1, default = 0 },
        { type = "slider", key = "posY",     name = L["EA_PosY"],     tooltip = L["EA_PosTip"],     min = -halfHeight, max = halfHeight, step = 1, default = 260 },
        { type = "slider", key = "fontSize", name = L["EA_FontSize"], tooltip = L["EA_FontSizeTip"], min = 8, max = 40, step = 1, default = DEFAULT_FONT_SIZE },
    },
})

-- ============================================================
-- 状态
-- ============================================================
local alertFrame          -- 提醒容器框架（懒创建）
local linePool = {}       -- FontString 池（按下标复用）
local messages = {}       -- 当前扫描出的提醒文本列表
local eventFrame          -- 事件框架
local scanPending = false -- 是否已有待执行的合并扫描

-- ------------------------------------------------------------
-- GetOption: 读取本模块某设置项的当前值
-- ------------------------------------------------------------
local function GetOption(key)
    local db = ns.db and ns.db.profile and ns.db.profile[module.key]
    return db and db[key]
end

-- ============================================================
-- 提醒框架：创建与布局
-- ============================================================
-- 容器为无背景 1×1 框架，锚定在设定坐标；所有提醒行从容器
-- 顶部依次向下锚定，实现「多条提醒向下增长」
local function EnsureFrame()
    if alertFrame then return alertFrame end
    alertFrame = CreateFrame("Frame", "JustinForgeEquipmentAlert", UIParent)
    alertFrame:SetFrameStrata("HIGH")
    alertFrame:SetSize(1, 1)
    alertFrame:Hide()
    return alertFrame
end

local function GetLine(index)
    local fs = linePool[index]
    if not fs then
        fs = alertFrame:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, DEFAULT_FONT_SIZE, "OUTLINE")
        fs:SetTextColor(1, 1, 1, 1)   -- 颜色固定白色
        linePool[index] = fs
    end
    return fs
end

-- ApplyLayout: 应用位置与字号设置，并重排所有行（向下堆叠）
local function ApplyLayout()
    if not alertFrame then return end
    alertFrame:ClearAllPoints()
    alertFrame:SetPoint("CENTER", UIParent, "CENTER", GetOption("posX") or 0, GetOption("posY") or 0)
    local fontSize = GetOption("fontSize") or DEFAULT_FONT_SIZE
    local prev
    for i = 1, #linePool do
        local fs = linePool[i]
        if fs:IsShown() then
            fs:SetFont(STANDARD_TEXT_FONT, fontSize, "OUTLINE")
            fs:ClearAllPoints()
            if prev then
                fs:SetPoint("TOP", prev, "BOTTOM", 0, -LINE_SPACING)
            else
                fs:SetPoint("TOP", alertFrame, "TOP", 0, 0)
            end
            prev = fs
        end
    end
end

-- ============================================================
-- 检测逻辑
-- ============================================================
-- HasEngineering: 是否已学习工程学（任一专业槽位匹配）
local function HasEngineering()
    local prof1, prof2 = GetProfessions()
    for _, prof in ipairs({ prof1, prof2 }) do
        if prof then
            local _, _, _, _, _, _, skillLine = GetProfessionInfo(prof)
            if skillLine and not issecretvalue(skillLine) and skillLine == ENGINEERING_SKILL_LINE then
                return true
            end
        end
    end
    return false
end

-- CheckBelt: 工程学腰带检测（未装备腰带 / 未附魔氮气推进器）
local function CheckBelt()
    if not HasEngineering() then return end
    local beltLink = GetInventoryItemLink("player", SLOT_WAIST)
    if not beltLink then
        messages[#messages + 1] = L["EA_NoBelt"]
        return
    end
    -- 物品链接字段：item:itemID:enchantID:gemID1:...
    local _, _, enchantID = strsplit(":", beltLink)
    enchantID = tonumber(enchantID)
    if enchantID ~= NITRO_BOOST_ENCHANT then
        messages[#messages + 1] = L["EA_NoNitro"]
    end
end

-- GetItemClassInfo: 取物品的 classID/subclassID/equipLoc（语言无关）
local function GetItemClassInfo(link)
    local _, _, _, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(link)
    return classID, subclassID, equipLoc
end

-- GetWeaponPrimaryStat: 取武器的主属性下标（1力/2敏/3智）
-- 返回 nil 表示武器无主属性（旧世界武器等），跳过该项检测
local function GetWeaponPrimaryStat(link)
    if not GetItemStatsFunc then return nil end
    local stats = GetItemStatsFunc(link)
    if type(stats) ~= "table" then return nil end
    local bestIndex, bestValue = nil, 0
    for i = 1, 3 do
        local v = stats[STAT_KEYS[i]]
        if type(v) == "number" and not issecretvalue(v) and v > bestValue then
            bestValue = v
            bestIndex = i
        end
    end
    return bestIndex
end

-- CheckWeaponStat: 单件武器主属性与专精主属性比对
local function CheckWeaponStat(link, expectedIndex, message)
    local weaponStat = GetWeaponPrimaryStat(link)
    if weaponStat and weaponStat ~= expectedIndex then
        messages[#messages + 1] = message
    end
end

-- CheckWeapons: 武器缺失 / 双持 / 匕首 / 盾牌 / 主属性检测
local function CheckWeapons()
    -- 当前专精（无专精时仅做最基本的「主手是否装备」检测）
    local specID, specStatIndex
    local specIndex = GetSpecialization()
    if specIndex then
        local primaryStat
        specID, _, _, _, _, primaryStat = GetSpecializationInfo(specIndex)
        if primaryStat and not issecretvalue(primaryStat) then
            specStatIndex = SPEC_STAT_INDEX[primaryStat]
        end
    end

    local mhLink = GetInventoryItemLink("player", SLOT_MAINHAND)
    local ohLink = GetInventoryItemLink("player", SLOT_OFFHAND)

    if not mhLink then
        messages[#messages + 1] = L["EA_NoMainHand"]
        -- 主手都没有时仍提示副手为空没有意义，直接结束
        return
    end

    local mhClass, mhSub, mhLoc = GetItemClassInfo(mhLink)
    local is2H = mhLoc and TWO_HAND_LOCS[mhLoc] or false
    local ohClass, ohSub
    if ohLink then
        ohClass, ohSub = GetItemClassInfo(ohLink)
    end

    if specID then
        -- 防护专精：单手武器 + 盾牌
        if SHIELD_SPECS[specID] then
            if is2H then
                messages[#messages + 1] = L["EA_NeedOneHand"]
            end
            if not ohLink or not (ohClass == CLASS_ARMOR and ohSub == SUBCLASS_SHIELD) then
                messages[#messages + 1] = L["EA_NeedShield"]
            end
        -- 双持专精：主手为单手武器时副手必须是武器
        elseif DUAL_WIELD_SPECS[specID] and not is2H then
            if not ohLink or ohClass ~= CLASS_WEAPON then
                messages[#messages + 1] = L["EA_NoOffHand"]
            end
        -- 其余专精：主手为单手武器（含魔杖）时副手不能空置
        -- （法系主手魔杖/单手武器忘带副手物品的场景；
        --   双持专精主手为双手武器时也走这里，但 is2H 为真不触发）
        elseif not is2H and not ohLink then
            messages[#messages + 1] = L["EA_NoOffHandItem"]
        end
        -- 匕首专精：刺杀/敏锐需要双持匕首
        if DAGGER_SPECS[specID] then
            local mhDagger = (mhClass == CLASS_WEAPON and mhSub == SUBCLASS_DAGGER)
            local ohDagger = false
            if ohLink and ohClass == CLASS_WEAPON then
                ohDagger = (ohSub == SUBCLASS_DAGGER)
            end
            if not mhDagger or not ohDagger then
                messages[#messages + 1] = L["EA_NeedDaggers"]
            end
        end
        -- 生存猎：主手必须是双手近战武器（远程武器/单手武器均不可用）
        if MELEE_2H_SPECS[specID] and mhLoc ~= "INVTYPE_2HWEAPON" then
            messages[#messages + 1] = L["EA_NeedMelee2H"]
        end
    end

    -- 武器主属性与专精主属性比对（仅武器；盾牌/副手饰物不参与）
    if specStatIndex then
        if mhClass == CLASS_WEAPON then
            CheckWeaponStat(mhLink, specStatIndex, L["EA_WrongStatMain"])
        end
        if ohLink and ohClass == CLASS_WEAPON then
            CheckWeaponStat(ohLink, specStatIndex, L["EA_WrongStatOff"])
        end
    end
end

-- ============================================================
-- 显示刷新
-- ============================================================
-- UpdateDisplay: 把扫描结果写入提醒行；战斗中或无提醒时隐藏
local function UpdateDisplay()
    if not alertFrame then return end
    if InCombatLockdown() or #messages == 0 then
        alertFrame:Hide()
        return
    end
    for i = 1, #messages do
        local fs = GetLine(i)
        fs:SetText(messages[i])
        fs:Show()
    end
    for i = #messages + 1, #linePool do
        linePool[i]:Hide()
    end
    ApplyLayout()
    alertFrame:Show()
end

-- Scan: 重新扫描全部检测项并刷新显示
local function Scan()
    wipe(messages)
    CheckBelt()
    CheckWeapons()
    UpdateDisplay()
end

-- ScheduleScan: 事件密集时合并为 0.2 秒后的一次扫描
local function ScheduleScan()
    if scanPending then return end
    scanPending = true
    C_Timer.After(SCAN_THROTTLE, function()
        scanPending = false
        if module.enabled then
            Scan()
        end
    end)
end

-- ============================================================
-- 事件处理
-- ============================================================
-- 装备变更 / 背包变化（补附魔）/ 专精切换 / 技能线变化（学专业）
--   → 合并扫描
-- 进战斗 → 立即隐藏；脱战 → 立即恢复（若有提醒）
local function OnEvent(self, event, arg1)
    if event == "PLAYER_REGEN_DISABLED" then
        if alertFrame then
            alertFrame:Hide()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        UpdateDisplay()
    elseif event == "UNIT_INVENTORY_CHANGED" then
        if arg1 == "player" then
            ScheduleScan()
        end
    else
        ScheduleScan()
    end
end

-- ============================================================
-- OnEnable: 模块启用
-- ============================================================
function module:OnEnable()
    EnsureFrame()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEvent)
    end
    eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    eventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("SKILL_LINES_CHANGED")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    -- 启用时立即扫描一次（专精/物品数据在 ADDON_LOADED 后可能
    -- 尚未完全就绪，再补一次延迟扫描兜底）
    Scan()
    C_Timer.After(2, function()
        if module.enabled then
            Scan()
        end
    end)
    Util:Debug("EquipmentAlert: 已启用")
end

-- ============================================================
-- OnDisable: 模块禁用
-- ============================================================
function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
    if alertFrame then
        alertFrame:Hide()
    end
    wipe(messages)
    Util:Debug("EquipmentAlert: 已禁用")
end

-- ============================================================
-- OnOptionChanged: 设置项变更（Config.lua 自动调用）
-- ============================================================
-- Config 侧在值写入 dbEntry 之后才触发本回调，GetOption 读到的即新值。
-- 即时生效：重应用位置与字号布局。
function module:OnOptionChanged(key, value)
    if not module.enabled then return end
    ApplyLayout()
end
