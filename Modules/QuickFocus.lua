-- ============================================================
-- JustinForge 模块14: 快速设置焦点目标 (QuickFocus.lua)
-- ============================================================
-- 功能描述：
--   按住 Shift 并用右键点击单位，将其设为焦点。适用于：
--     1. 场景中的单位（通过覆盖按键绑定触发 /focus mouseover）
--     2. 暴雪默认头像/小队/团队等单位框体（通过设置框体的
--        shift-type2 = "focus" 安全属性实现）
--     3. EllesmereUI 单位框体（oUF 安全按钮，同样支持 shift-type2）
--   （实现逻辑移植自 ElvUI_WindTools 的 UnitFrames/QuickFocus，
--     原实现针对 ElvUI 框体，本模块支持暴雪默认框体与 EllesmereUI 框体）
--
-- 实现原理：
--   1. 创建隐藏安全按钮（SecureActionButtonTemplate），宏内容为
--      /focus mouseover，再用 SetOverrideBindingClick 将
--      SHIFT-BUTTON2 映射到该按钮 —— 覆盖绑定优先于框体点击分发，
--      鼠标悬停单位框体时 mouseover 即为该框体单位，此为主路径
--      （注意：按钮必须同时注册 AnyDown+AnyUp，见 EnsureButton 注释）
--   2. 为单位框体设置 shift-type2="focus" 安全属性作为后备路径
--      （暴雪安全模板原生支持 focus 动作类型；当覆盖绑定被其他
--      插件抢占时，框体自身点击仍会触发焦点设置）
--   3. 战斗中无法修改绑定/属性，延迟到 PLAYER_REGEN_ENABLED 处理
--   4. 禁用时清除覆盖绑定并还原框体原属性值
--
-- 注意：姓名板（NamePlate）属于受保护安全框体，不支持此功能
-- （Shift+右键点姓名板只会选中目标，与 WindTools 行为一致）
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local ipairs = ipairs
local pairs = pairs
local wipe = wipe

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
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

local focusButton               -- 隐藏安全按钮（懒创建）
local bindingApplied = false    -- 覆盖绑定是否已应用
local setupPending = false      -- 战斗中无法初始化，等待脱战后补设
local hookedFrames = {}         -- 已设置属性的框体 → 原属性值（false 表示原本无值）
local pendingFrames = {}        -- 战斗中未能设置的框体

-- 暴雪默认具名单位框体
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
    -- EllesmereUI 单位框体（oUF 具名安全按钮）
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
}

-- EllesmereUI 团队/小队安全组标头（子按钮按需动态创建，遍历其子框架）
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
    if InCombatLockdown() then
        pendingFrames[frame] = true
        return
    end
    -- 记录原属性值以便禁用时还原（false 标记原本无值）
    local ok, old = pcall(frame.GetAttribute, frame, "shift-type2")
    if not ok then return end
    hookedFrames[frame] = old or false
    pcall(frame.SetAttribute, frame, "shift-type2", "focus")
end

-- ------------------------------------------------------------
-- ScanUnitFrames: 扫描具名框体与紧凑团队/小队框体
-- ------------------------------------------------------------
-- 紧凑框体按钮按需动态创建，名字规律固定，逐个按名查找
local function ScanUnitFrames()
    for _, name in ipairs(NAMED_FRAMES) do
        local frame = _G[name]
        if frame then
            SetupFrame(frame)
        end
    end

    -- 紧凑团队框体（单容器模式）与紧凑小队框体
    for i = 1, 40 do
        local frame = _G["CompactRaidFrame" .. i]
        if frame then
            SetupFrame(frame)
        end
    end
    for i = 1, 5 do
        local member = _G["CompactPartyFrameMember" .. i]
        if member then
            SetupFrame(member)
        end
        local pet = _G["CompactPartyFramePet" .. i]
        if pet then
            SetupFrame(pet)
        end
    end
    -- 分组团队框体模式（CompactRaidGroupNMemberM）
    for group = 1, 8 do
        for member = 1, 5 do
            local frame = _G["CompactRaidGroup" .. group .. "Member" .. member]
            if frame then
                SetupFrame(frame)
            end
        end
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
-- RestoreFrames: 还原所有框体的原属性值
-- ------------------------------------------------------------
local function RestoreFrames()
    if InCombatLockdown() then
        return false
    end
    for frame, old in pairs(hookedFrames) do
        pcall(frame.SetAttribute, frame, "shift-type2", old ~= false and old or nil)
    end
    wipe(hookedFrames)
    wipe(pendingFrames)
    return true
end

-- ------------------------------------------------------------
-- EnsureButton / ApplyBinding: 安全按钮与覆盖绑定
-- ------------------------------------------------------------
local function EnsureButton()
    if focusButton then return end
    focusButton = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
    focusButton:SetAttribute("type*", "macro")
    focusButton:SetAttribute("macrotext", "/focus mouseover")
    -- 关键：必须同时注册 Down 和 Up。12.0 的 SecureActionButton_OnClick
    -- 依据 CVar ActionButtonUseKeyDown 决定动作时机：CVar 关（默认）时只有
    -- 抬起(down=false)才执行，CVar 开时只有按下(down=true)才执行。
    -- 只注册 AnyDown 时，默认 CVar 下按下事件不执行、抬起事件收不到，
    -- 按钮永远不触发。同时注册两者则任意 CVar 下都恰好触发一次
    -- （模板内部按 useOnKeyDown 互斥，不会重复执行）。
    focusButton:RegisterForClicks("AnyDown", "AnyUp")
end

local function ApplyBinding()
    if bindingApplied then return end
    if InCombatLockdown() then
        setupPending = true
        return
    end
    SetOverrideBindingClick(focusButton, true, BINDING_KEY, BUTTON_NAME)
    bindingApplied = true
end

-- ------------------------------------------------------------
-- SetupAll: 完整初始化（安全按钮 + 绑定 + 框体属性）
-- ------------------------------------------------------------
-- 安全按钮属性与绑定在战斗中无法修改，整个初始化需脱战执行
local function SetupAll()
    if InCombatLockdown() then
        setupPending = true
        return
    end
    setupPending = false
    EnsureButton()
    ApplyBinding()
    ScanUnitFrames()
end

-- ------------------------------------------------------------
-- 事件处理：脱战后补设置/补清理，队伍变化时重扫紧凑框体
-- ------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_REGEN_ENABLED" then
        if module.enabled then
            -- 战斗中启用时延迟的初始化
            if setupPending then
                SetupAll()
            end
            if next(pendingFrames) then
                for frame in pairs(pendingFrames) do
                    pendingFrames[frame] = nil
                    SetupFrame(frame)
                end
            end
        else
            -- 战斗中禁用时延迟的清理：清除覆盖绑定并还原框体属性
            if focusButton and bindingApplied then
                ClearOverrideBindings(focusButton)
                bindingApplied = false
            end
            if next(hookedFrames) then
                RestoreFrames()
            end
            eventFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        if module.enabled then
            ScanUnitFrames()
        end
    elseif event == "PLAYER_LOGIN" then
        -- 部分框体（如 EllesmereUI）在插件加载完毕后才创建，登录时再补扫一次
        if module.enabled then
            ScanUnitFrames()
        end
    elseif event == "ADDON_LOADED" then
        -- EllesmereUI 可能在本插件之后加载，其框体创建后再补扫一次
        if module.enabled and arg1 == "EllesmereUI" then
            ScanUnitFrames()
        end
    end
end)

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
function module:OnEnable()
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_LOGIN")
    eventFrame:RegisterEvent("ADDON_LOADED")
    SetupAll()
    Util:Debug("QuickFocus: 已启用 Shift+右键快速焦点")
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
function module:OnDisable()
    setupPending = false
    eventFrame:UnregisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:UnregisterEvent("PLAYER_LOGIN")
    eventFrame:UnregisterEvent("ADDON_LOADED")
    if InCombatLockdown() then
        -- 战斗中无法清除绑定与框体属性，保留监听待脱战后处理
        eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    else
        if focusButton and bindingApplied then
            ClearOverrideBindings(focusButton)
        end
        bindingApplied = false
        RestoreFrames()
        eventFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
    end
    Util:Debug("QuickFocus: 已禁用")
end
