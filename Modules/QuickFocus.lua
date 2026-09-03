-- ============================================================
-- JustinForge 模块14: 快速设置焦点目标 (QuickFocus.lua)
-- ============================================================
-- 功能：按住 Shift 并用右键点击单位，将其设为焦点；再点一次其他
--   单位切换焦点。支持：
--     1. 场景中的 3D 单位（隐藏安全按钮 + 覆盖绑定实现）
--     2. 暴雪默认框体：玩家/宠物/目标/焦点/小队/首领/竞技场/
--        紧凑团队与紧凑小队框体
--     3. EllesmereUI 单位框体与团队/小队框体
--
-- 实现方式（参照 ElvUI_WindTools Modules/UnitFrames/QuickFocus.lua，
-- 该实现已在本版本游戏内验证可用）：
--   1. 框体路径：为单位框体设置安全属性 shift-type2="focus"。
--      鼠标悬停在可点击框体上时点击被框体消耗，不会进入按键绑定
--      系统，只能靠框体自身的修饰键点击属性响应。
--   2. 场景路径：创建隐藏 SecureActionButtonTemplate 按钮
--      （宏文本 /focus mouseover），再用 SetOverrideBindingClick
--      把 SHIFT-BUTTON2 映射到该按钮。鼠标悬停在 3D 世界单位上
--      时点击进入绑定系统触发按钮；宏的 mouseover 条件在指向空白
--      处时不成立，不会误清当前焦点。
--   3. 战斗中无法改安全属性/绑定：记入 pending 表，脱战
--      （PLAYER_REGEN_ENABLED）后补设；阵容变化
--      （GROUP_ROSTER_UPDATE）重扫，覆盖动态新建的框体。
--      注意：EllesmereUI 系列按加载序先于本插件，无法靠
--      ADDON_LOADED 事件补扫，用定时重扫兜底覆盖晚创建的框体。
--   4. 禁用时清除覆盖绑定，并把各框体的原属性值还原。
--
-- 注意：姓名板（NamePlate）是受保护框体，不支持此功能。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local ipairs = ipairs
local pairs = pairs
local wipe = wipe
local strfind = strfind

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GetCVar = GetCVar
local SetOverrideBindingClick = SetOverrideBindingClick
local ClearOverrideBindings = ClearOverrideBindings

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "quickFocus",
    name           = L["QuickFocus_Name"],
    description    = L["QuickFocus_Desc"],
    defaultEnabled = true,
})

local BUTTON_NAME = "JustinForgeQuickFocusButton"
local BINDING_KEY = "SHIFT-BUTTON2"
local ATTRIBUTE   = "shift-type2"   -- 修饰键+按键对应的框体安全属性名

local focusButton             -- 隐藏安全按钮（懒创建）
local bindingApplied = false  -- 覆盖绑定是否已应用
local setupPending = false    -- 战斗中无法初始化，待脱战补做
local hookedFrames = {}       -- 已设置属性的框体 → 原属性值（false 表示原本无值）
local pending = {}            -- 战斗中未能设置的框体

-- ------------------------------------------------------------
-- 暴雪自带具名单位框体 + EllesmereUI 单位框体（存在即设置）
-- ------------------------------------------------------------
local NAMED_FRAMES = {
    "PlayerFrame",
    "PetFrame",
    "TargetFrame",
    "TargetFrameToT",
    "FocusFrame",
    "FocusFrameToT",
    "PartyMemberFrame1",
    "PartyMemberFrame2",
    "PartyMemberFrame3",
    "PartyMemberFrame4",
    "Boss1TargetFrame",
    "Boss2TargetFrame",
    "Boss3TargetFrame",
    "Boss4TargetFrame",
    "Boss5TargetFrame",
    -- 竞技场框体（10.x 新名 + 旧名，存在哪个用哪个）
    "ArenaEnemyMatchFrame1",
    "ArenaEnemyMatchFrame2",
    "ArenaEnemyMatchFrame3",
    "ArenaEnemyMatchFrame4",
    "ArenaEnemyMatchFrame5",
    "ArenaEnemyFrame1",
    "ArenaEnemyFrame2",
    "ArenaEnemyFrame3",
    "ArenaEnemyFrame4",
    "ArenaEnemyFrame5",
    -- EllesmereUI 单位框体（按其框体来源设置按需创建）
    "EllesmereUIUnitFrames_Player",
    "EllesmereUIUnitFrames_Target",
    "EllesmereUIUnitFrames_Focus",
    "EllesmereUIUnitFrames_Pet",
    "EllesmereUIUnitFrames_TargetTarget",
    "EllesmereUIUnitFrames_FocusTarget",
    "EllesmereUIUnitFrames_Boss1",
    "EllesmereUIUnitFrames_Boss2",
    "EllesmereUIUnitFrames_Boss3",
    "EllesmereUIUnitFrames_Boss4",
    "EllesmereUIUnitFrames_Boss5",
    -- EllesmereUI 团队框体附属安全按钮
    "ERFPartySelfButton",
    "ERFFriendlyBoss1",
    "ERFFriendlyBoss2",
    "ERFFriendlyBoss3",
    "ERFFriendlyBoss4",
    "ERFFriendlyBoss5",
}

-- EllesmereUI 团队/小队安全组标头（子按钮按阵容动态创建/回收）
local ELLESMERE_HEADERS = {
    "ERFPartyHeader",
    "ERFFlatHeader",
    "ERFGroupHeader1",
    "ERFGroupHeader2",
    "ERFGroupHeader3",
    "ERFGroupHeader4",
    "ERFGroupHeader5",
    "ERFGroupHeader6",
    "ERFGroupHeader7",
    "ERFGroupHeader8",
}

-- ------------------------------------------------------------
-- SetupFrame: 为单个单位框体设置 shift+右键 = 焦点
-- ------------------------------------------------------------
local function SetupFrame(frame)
    if not frame or hookedFrames[frame] ~= nil then
        return
    end
    -- 姓名板等受保护框体跳过（SetAttribute 会报错）
    local name = frame.GetName and frame:GetName()
    if name and strfind(name, "NamePlate") then
        return
    end
    if InCombatLockdown() then
        pending[frame] = true
        return
    end
    -- 记录原属性值供禁用时还原
    local ok, old = pcall(frame.GetAttribute, frame, ATTRIBUTE)
    if not ok then return end
    hookedFrames[frame] = old or false
    pcall(frame.SetAttribute, frame, ATTRIBUTE, "focus")
    pending[frame] = nil
end

-- ------------------------------------------------------------
-- ScanFrames: 扫描全部目标框体（幂等，可随时重扫）
-- ------------------------------------------------------------
local function ScanFrames()
    -- 具名框体按名查找
    for _, name in ipairs(NAMED_FRAMES) do
        SetupFrame(_G[name])
    end

    -- 暴雪紧凑团队框体（单容器模式）
    for i = 1, 40 do
        SetupFrame(_G["CompactRaidFrame" .. i])
    end
    -- 暴雪紧凑小队框体
    for i = 1, 5 do
        SetupFrame(_G["CompactPartyFrameMember" .. i])
        SetupFrame(_G["CompactPartyFramePet" .. i])
    end
    -- 暴雪分组团队框体模式（CompactRaidGroupNMemberM）
    for group = 1, 8 do
        for member = 1, 5 do
            SetupFrame(_G["CompactRaidGroup" .. group .. "Member" .. member])
        end
    end

    -- EllesmereUI 成员复制框（槽位按需增长，无固定上限）
    for i = 1, 10 do
        local frame = _G["ERFExtraFrame" .. i]
        if not frame then break end
        SetupFrame(frame)
    end

    -- EllesmereUI 团队/小队框体：遍历安全组标头的动态子按钮
    for _, headerName in ipairs(ELLESMERE_HEADERS) do
        local header = _G[headerName]
        if header and header.GetChildren then
            for _, child in ipairs({ header:GetChildren() }) do
                -- 仅处理带 unit 属性的安全按钮（排除标头附带的其他子框架）
                local ok, unit = pcall(child.GetAttribute, child, "unit")
                if ok and unit then
                    SetupFrame(child)
                end
            end
        end
    end
end

-- ------------------------------------------------------------
-- RestoreFrames: 还原所有框体的原属性值（返回是否完成）
-- ------------------------------------------------------------
local function RestoreFrames()
    if InCombatLockdown() then
        return false
    end
    for frame, old in pairs(hookedFrames) do
        pcall(frame.SetAttribute, frame, ATTRIBUTE, old ~= false and old or nil)
    end
    wipe(hookedFrames)
    wipe(pending)
    return true
end

-- ------------------------------------------------------------
-- SetupButton: 场景单位路径（隐藏安全按钮 + 覆盖绑定）
-- ------------------------------------------------------------
local function SetupButton()
    if bindingApplied then return end
    if InCombatLockdown() then
        setupPending = true
        return
    end
    if not focusButton then
        focusButton = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
        focusButton:SetAttribute("type*", "macro")
        -- mouseover 条件：指向空白处时不成立，整行不执行，避免误清当前焦点
        focusButton:SetAttribute("macrotext", "/focus mouseover")
        -- 对齐已验证方案（WindTools）：按「按键按下施法」CVar 只注册
        -- Down/Up 其一，保证一次点击动作恰好执行一次
        focusButton:RegisterForClicks(GetCVar("ActionButtonUseKeyDown") == "1" and "AnyDown" or "AnyUp")
    end
    SetOverrideBindingClick(focusButton, true, BINDING_KEY, BUTTON_NAME)
    bindingApplied = true
end

-- ------------------------------------------------------------
-- SetupAll: 完整初始化（安全按钮 + 绑定 + 框体属性）
-- ------------------------------------------------------------
local function SetupAll()
    if InCombatLockdown() then
        setupPending = true
        return
    end
    setupPending = false
    SetupButton()
    ScanFrames()
end

-- ------------------------------------------------------------
-- 事件处理
-- ------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        -- 登录锁定已解除且各 UI 框体已创建，是首个可靠初始化时机；
        -- 之后每次进副本/切地图重扫（幂等），覆盖动态新建的框体
        SetupAll()
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- 阵容变化时安全标头会动态创建/回收子按钮，重扫补设
        ScanFrames()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if module.enabled then
            if setupPending then
                SetupAll()
            end
            for frame in pairs(pending) do
                SetupFrame(frame)
            end
        else
            -- 战斗中禁用时延迟的清理
            if RestoreFrames() then
                if focusButton and bindingApplied then
                    ClearOverrideBindings(focusButton)
                    bindingApplied = false
                end
                eventFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
            end
        end
    end
end)

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
function module:OnEnable()
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    SetupAll()
    -- EllesmereUI 系列按加载序先于本插件完成加载（收不到其
    -- ADDON_LOADED 事件），且框体可能延迟到 PEW 之后才 spawn；
    -- 定时重扫兜底（幂等），覆盖所有晚创建的框体
    C_Timer.After(2, function()
        if module.enabled then ScanFrames() end
    end)
    C_Timer.After(6, function()
        if module.enabled then ScanFrames() end
    end)
    Util:Debug("QuickFocus: 已启用 Shift+右键快速焦点")
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
function module:OnDisable()
    setupPending = false
    eventFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:UnregisterEvent("GROUP_ROSTER_UPDATE")
    if not InCombatLockdown() then
        if focusButton and bindingApplied then
            ClearOverrideBindings(focusButton)
            bindingApplied = false
        end
        RestoreFrames()
        eventFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
    end
    -- 战斗中禁用：保留 PLAYER_REGEN_ENABLED 监听，待脱战后清理
    Util:Debug("QuickFocus: 已禁用")
end
