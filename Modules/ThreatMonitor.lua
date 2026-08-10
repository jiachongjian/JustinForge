-- ============================================================
-- JustinForge 模块15: 仇恨预警 (ThreatMonitor.lua)
-- ============================================================
-- 功能描述：
--   战斗中在屏幕上显示当前敌对目标对自己的仇恨百分比预警：
--     - 坦克专精：仇恨百分比低于 100%（仇恨不稳/已丢失）时显示
--     - 治疗/输出专精：仇恨百分比高于 80%（即将 OT）时显示
--   其余情况（脱战、无有效敌对目标、仇恨安全）自动隐藏。
--   文本颜色随仇恨状态（status 0-3）变化：白 -> 黄 -> 橙 -> 红，
--   越红越危险。面板可用鼠标左键拖动，位置自动保存。
--
-- 实现说明：
--   - 数据源：UnitDetailedThreatSituation("player", "target")
--     返回 isTanking / status / threatPct（相对当前主坦的百分比，
--     坦职扛住目标时恒为 100，被 OT 后按新坦的仇恨折算而低于 100）
--   - 刷新事件：UNIT_THREAT_LIST_UPDATE（百分比变化，高频）、
--     UNIT_THREAT_SITUATION_UPDATE（状态变化）、PLAYER_TARGET_CHANGED、
--     PLAYER_REGEN_DISABLED/ENABLED（进出战斗）
--   - 专精角色：GetSpecializationRole(GetSpecialization())，
--     切专精后由 PLAYER_SPECIALIZATION_CHANGED 等事件重新判定
--   - 12.0 secret value 兼容：百分比可能是 secret（不可比较/算术，
--     但可 string.format），所有比较运算均经 pcall 保护，
--     失败时保守隐藏
-- ============================================================

local addonName, ns = ...

local L = ns.L

-- 坦克专精显示阈值：仇恨百分比低于该值时显示（扛住目标时为 100）
local TANK_SHOW_BELOW = 100
-- 治疗/输出专精显示阈值：仇恨百分比高于该值时显示（即将 OT）
local OTHER_SHOW_ABOVE = 80

-- 仇恨状态颜色（status 0-3，与游戏内仇恨指示一致：白/黄/橙/红）
local STATUS_COLORS = {
    [0] = "ffffffff",  -- 无威胁
    [1] = "ffffff00",  -- 仇恨不稳
    [2] = "ffff7f00",  -- 即将换目标
    [3] = "ffff0000",  -- 正在挨打
}

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "threatMonitor",
    name           = L["ThreatMonitor_Name"],
    description    = L["ThreatMonitor_Desc"],
    defaultEnabled = true,
})

-- 预警面板与字体串（懒创建）
local alertFrame, alertText
-- 战斗状态缓存（PLAYER_REGEN_DISABLED/ENABLED 维护）
local inCombat = false

-- ------------------------------------------------------------
-- GetPlayerRole: 获取当前专精角色（TANK / HEALER / DAMAGER）
-- ------------------------------------------------------------
-- 无专精（低等级/未选择）时按输出处理，使用 80% 阈值
local function GetPlayerRole()
    if GetSpecialization then
        local spec = GetSpecialization()
        if spec then
            return GetSpecializationRole(spec) or "DAMAGER"
        end
    end
    return "DAMAGER"
end

-- ------------------------------------------------------------
-- SafeLess / SafeGreater: 安全比较（兼容 12.0 secret value）
-- ------------------------------------------------------------
-- secret 值参与比较会抛错，pcall 保护后保守返回 false（不显示）
local function SafeLess(a, b)
    local ok, result = pcall(function() return a < b end)
    return ok and result == true
end

local function SafeGreater(a, b)
    local ok, result = pcall(function() return a > b end)
    return ok and result == true
end

-- ------------------------------------------------------------
-- Refresh: 按当前状态刷新预警显示
-- ------------------------------------------------------------
-- 显示条件全部满足才显示面板，任一不满足即隐藏：
--   1. 处于战斗中
--   2. 当前目标是可攻击的存活敌对单位
--   3. 目标已建立仇恨列表（UnitDetailedThreatSituation 有返回）
--   4. 仇恨百分比越过当前专精角色的阈值
local function Refresh()
    if not alertFrame then return end

    -- 脱战 / 无目标 / 目标不可攻击 / 目标已死亡：隐藏
    if not inCombat
        or not UnitExists("target")
        or not UnitCanAttack("player", "target")
        or UnitIsDeadOrGhost("target") then
        alertFrame:Hide()
        return
    end

    -- 目标未与任何人建立仇恨关系（未进战）时返回 nil
    local _, status, threatPct = UnitDetailedThreatSituation("player", "target")
    if not status then
        alertFrame:Hide()
        return
    end

    -- 按专精角色判定是否越过阈值
    local show
    if GetPlayerRole() == "TANK" then
        show = SafeLess(threatPct, TANK_SHOW_BELOW)
    else
        show = SafeGreater(threatPct, OTHER_SHOW_ABOVE)
    end
    if not show then
        alertFrame:Hide()
        return
    end

    -- secret 值可 string.format 但不可算术，失败时显示 "?"
    local ok, pctText = pcall(string.format, "%d%%", threatPct)
    if not ok then pctText = "?" end

    -- secret 值不能作表键，pcall 保护；失败退回 status 0 的白色
    local okColor, color = pcall(function() return STATUS_COLORS[status] end)
    if not okColor or not color then
        color = STATUS_COLORS[0]
    end
    alertText:SetFormattedText("|c%s%s|r", color, pctText)
    alertFrame:Show()
end

-- ------------------------------------------------------------
-- CreateAlertFrame: 创建预警面板（懒创建，仅一次）
-- ------------------------------------------------------------
-- 结构：小标签「仇恨」+ 大号百分比数字；左键拖动并保存位置
local function CreateAlertFrame()
    local f = CreateFrame("Frame", "JustinForgeThreatAlertFrame", UIParent, "BackdropTemplate")
    f:SetSize(90, 44)
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
        local db = ns.db and ns.db.profile and ns.db.profile.threatMonitor
        if db then
            db.point, db.posX, db.posY = point, x, y
        end
    end)

    -- 顶部小标签
    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.label:SetPoint("TOP", 0, -6)
    f.label:SetText("|cffaaaaaa" .. L["ThreatMonitor_Label"] .. "|r")

    -- 大号百分比数字
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.text:SetPoint("BOTTOM", 0, 6)

    f:Hide()
    return f
end

-- ------------------------------------------------------------
-- RestorePosition: 从 DB 恢复面板位置（默认屏幕中上方）
-- ------------------------------------------------------------
local function RestorePosition()
    local db = ns.db and ns.db.profile and ns.db.profile.threatMonitor
    alertFrame:ClearAllPoints()
    if db and db.point then
        alertFrame:SetPoint(db.point, UIParent, db.point, db.posX or 0, db.posY or 0)
    else
        alertFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 220)
    end
end

-- ------------------------------------------------------------
-- OnEvent: 事件分发
-- ------------------------------------------------------------
local function OnEvent(_, event, arg1)
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        Refresh()
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        Refresh()
    elseif event == "UNIT_THREAT_LIST_UPDATE" or event == "UNIT_THREAT_SITUATION_UPDATE" then
        -- 只关心当前目标的仇恨列表与自身的仇恨状态
        if arg1 ~= "target" and arg1 ~= "player" then return end
        Refresh()
    else
        -- PLAYER_TARGET_CHANGED / PLAYER_SPECIALIZATION_CHANGED /
        -- ACTIVE_TALENT_GROUP_CHANGED / PLAYER_ENTERING_WORLD
        inCombat = InCombatLockdown()
        Refresh()
    end
end

-- ------------------------------------------------------------
-- OnEnable: 创建面板，注册仇恨与战斗事件
-- ------------------------------------------------------------
function module:OnEnable()
    if not alertFrame then
        alertFrame = CreateAlertFrame()
        alertText = alertFrame.text
        alertFrame:SetScript("OnEvent", OnEvent)
    end
    RestorePosition()
    alertFrame:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
    alertFrame:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE")
    alertFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    alertFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    alertFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    alertFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    alertFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
    alertFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

    -- 启用时可能已在战斗中（如战斗中 /reload），取实时状态
    inCombat = InCombatLockdown()
    Refresh()
end

-- ------------------------------------------------------------
-- OnDisable: 解绑事件并隐藏面板（零开销）
-- ------------------------------------------------------------
function module:OnDisable()
    if alertFrame then
        alertFrame:UnregisterAllEvents()
        alertFrame:Hide()
    end
    inCombat = false
end
