-- ============================================================
-- JustinForge 模块10: 虫洞抽屉宏 (DrawerMacro.lua)
-- ============================================================
-- 功能描述：
--   玩家手动创建一个宏，内容填入固定命令 /click JFDrawerBtn1
--   （仅一行，不占宏数量配额之外的任何动态内容，也不受 255 字符
--   限制影响）。点击宏会在鼠标位置展开一个贴近暴雪原生 UI 风格
--   的抽屉窗口，窗口内以网格排列所有虫洞传送玩具（诺森德 →
--   奎尔萨拉斯），点击任意按钮立即使用对应玩具并自动收起抽屉。
--
-- 与 Plumber 抽屉宏的区别：
--   Plumber 需要用户在宏里手写 #plumber:drawer 和若干 #/use 行，
--   插件解析宏文本后动态改写宏体注入 /click 行，且每次展开都要
--   在安全代码片段里重新配置按钮属性（macrotext 等）。
--   本模块的玩具列表写死在插件中（DRAWERS 表，最多支持 30 个位置），
--   安全按钮的属性在脱战时一次性配置完毕，战斗中仅做
--   显示/隐藏/移动 操作，宏体永远只有一行固定命令。
--
-- 实现原理（安全机制借鉴自 Plumber 的 SpellFlyout_Secure）：
--   1. 安全根容器 JFDrawerRoot：全屏不可见 Button（Frame 无 OnClick
--      脚本，_onclick 无法包装），负责「点击任意位置关闭抽屉」
--      与 ESC 关闭（覆盖按键绑定）
--   2. 每个抽屉对应一个隐藏的安全处理器按钮 JFDrawerBtn<N>，
--      宏内容为 /click JFDrawerBtn<N>，触发其 _onclick 安全
--      代码片段：在受限环境中把抽屉面板移动到鼠标处并显示
--      （受限片段由硬件事件触发，战斗中也可正常展开）
--   3. 抽屉面板内的按钮是 SecureActionButtonTemplate，
--      type=macro，macrotext = /use "item:ID" + /click JFDrawerClose，
--      点击即使用玩具并收起抽屉（战斗中同样可用）
--   4. 新增抽屉只需在 DRAWERS 表追加一项（宏名 + 物品ID列表），
--      面板/按钮/处理器/宏都会自动生成
--
-- 样式说明（贴近暴雪原始 UI）：
--   - 抽屉背景使用原生提示框样式：ChatFrameBackground 底 +
--     UI-Tooltip-Border 边框（与 GameTooltip 一致的黑底细边）
--   - 按钮为原生动作条按钮外观：UI-Quickslot2 常态边框、
--     UI-Quickslot-Depress 按下态、ButtonHilight-Square 高亮、
--     CooldownFrameTemplate 冷却转圈、悬停显示原生玩具提示
-- ============================================================

local addonName, ns = ...

local L = ns.L

-- 固定样式常量（均取自暴雪原生动作条按钮规格）
local BUTTON_SIZE         = 36   -- 原生动作条按钮尺寸
local NORMAL_TEXTURE_SIZE = 66   -- 原生 NormalTexture (UI-Quickslot2) 尺寸
local BUTTONS_PER_ROW     = 6    -- 抽屉每行按钮数
local MAX_ITEMS           = 30   -- 每个抽屉最多 30 个位置（6 列 × 5 行）
local BUTTON_GAP          = 4    -- 按钮间距
local PANEL_PADDING       = 8    -- 抽屉面板内边距
local FALLBACK_ICON       = 134400 -- INV_MISC_QUESTIONMARK（物品图标未缓存时兜底）

-- 安全对象命名（宏体与按钮 macrotext 中引用，必须全局唯一）
local HANDLER_NAME_PREFIX = "JFDrawerBtn"   -- 抽屉开关处理器：JFDrawerBtn1, 2, ...
local CLOSE_BUTTON_NAME   = "JFDrawerClose" -- 关闭抽屉处理器

-- ============================================================
-- 抽屉定义表（写死的抽屉内容）
-- ============================================================
-- 每个抽屉 = 一个固定 /click 命令 + 一组物品按钮（最多 MAX_ITEMS 个）
-- 新增抽屉时追加一项即可，无需改动其他代码：
--   { items = { 54452, 64488, ... } },
-- 第 N 个抽屉的宏内容为 /click JFDrawerBtn<N>（由玩家手动创建）
local DRAWERS = {
    {
        items = {
            48933,   -- 虫洞发生器：诺森德
            87215,   -- 虫洞发生器：潘达利亚
            112059,  -- 虫洞离心机（德拉诺）
            151652,  -- 虫洞发生器：阿古斯
            168807,  -- 虫洞发生器：库尔提拉斯
            168808,  -- 虫洞发生器：赞达拉
            172924,  -- 虫洞发生器：暗影界
            198156,  -- 龙洞发生器（巨龙群岛）
            221966,  -- 虫洞发生器：卡兹阿加
            248485,  -- 虫洞发生器：奎尔萨拉斯
        },
    },
}

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "drawerMacro",
    name           = L["DrawerMacro_Name"],
    description    = L["DrawerMacro_Desc"],
    defaultEnabled = true,
})

-- 运行时状态
local eventFrame              -- 模块事件 Frame（脱战补建/玩具学会刷新）
local root                    -- 安全根容器 JFDrawerRoot
local handlers = {}           -- 抽屉开关处理器按钮（/click 目标）
local panels = {}             -- 抽屉面板（root 的子框架）
local toggleSnippet           -- 处理器 _onclick 安全代码片段（抽屉数量格式化后缓存）
local built = false           -- 安全 UI 是否已构建（仅脱战时构建一次）
local pendingBuild = false    -- 启用时处于战斗锁定，等待脱战后补建
local pendingState = nil      -- 启用/禁用切换时处于战斗锁定，等待脱战后应用

-- ============================================================
-- 安全代码片段（受限环境 Lua，语法/函数受 Blizzard 限制）
-- ============================================================
-- 抽屉开关处理器的 _onclick：
--   - 抽屉已展开且来自同一个宏 → 收起（再点一次关闭）
--   - 否则隐藏其他抽屉面板，把本面板移动到鼠标位置并显示根容器
--   %d 处填入抽屉总数（受限环境不支持外部 upvalue，数量直接烘焙进代码）
local TOGGLE_SNIPPET_FORMAT = [=[
local root = self:GetFrameRef("Root")
local id = self:GetID()
if root:IsShown() and root:GetID() == id then
    root:Hide()
else
    root:SetID(id)
    for i = 1, %d do
        local panel = self:GetFrameRef("Panel" .. i)
        if panel then panel:Hide() end
    end
    local panel = self:GetFrameRef("Panel" .. id)
    local ui = self:GetFrameRef("UIParent")
    local rx, ry = self:GetMousePosition()
    if rx and ry then
        panel:ClearAllPoints()
        panel:SetPoint("BOTTOMLEFT", ui, "BOTTOMLEFT", ui:GetWidth() * rx - 16, ui:GetHeight() * ry + 20)
    end
    panel:Show()
    root:Show()
end
]=]

-- ------------------------------------------------------------
-- 按钮视觉刷新：图标 + 未学会玩具置灰
-- ------------------------------------------------------------
-- 设置图标/着色不属于受限操作，战斗中允许执行；
-- TOYS_UPDATED（学会新玩具）与面板每次展开时都会调用
local function RefreshButtonStates()
    if not built then return end
    for _, drawer in ipairs(DRAWERS) do
        for _, btn in ipairs(drawer.buttons) do
            local icon = C_Item.GetItemIconByID(btn.itemID)
            if icon then
                btn.Icon:SetTexture(icon)
            end
            if PlayerHasToy(btn.itemID) then
                btn.Icon:SetDesaturated(false)
                btn.Icon:SetVertexColor(1, 1, 1)
            else
                -- 未学会的玩具显示为灰色，点击使用会由游戏本身报错
                btn.Icon:SetDesaturated(true)
                btn.Icon:SetVertexColor(0.6, 0.6, 0.6)
            end
        end
    end
end

-- ------------------------------------------------------------
-- 冷却刷新：玩具冷却属于物品冷却（C_Item.GetItemCooldown）
-- ------------------------------------------------------------
local function UpdateCooldowns()
    if not built then return end
    for _, drawer in ipairs(DRAWERS) do
        for _, btn in ipairs(drawer.buttons) do
            local start, duration = C_Item.GetItemCooldown(btn.itemID)
            if start and duration and duration > 1.5 then
                btn.Cooldown:SetCooldown(start, duration)
            else
                btn.Cooldown:Clear()
            end
        end
    end
end

-- ------------------------------------------------------------
-- 按键按下/抬起触发同步（跟随游戏 CVar ActionButtonUseKeyDown）
-- ------------------------------------------------------------
-- RegisterForClicks 属于受限操作，战斗中禁止调用，需先判断
local function SyncClickRegistration()
    if not built or InCombatLockdown() then return end
    local keyDown = C_CVar.GetCVarBool("ActionButtonUseKeyDown")
    local btn1 = keyDown and "LeftButtonDown" or "LeftButtonUp"
    local btn2 = keyDown and "RightButtonDown" or "RightButtonUp"
    for _, drawer in ipairs(DRAWERS) do
        for _, btn in ipairs(drawer.buttons) do
            btn:RegisterForClicks(btn1, btn2)
        end
    end
end

-- ------------------------------------------------------------
-- 按钮悬停提示：已学会显示玩具提示，未学会显示物品提示
-- ------------------------------------------------------------
local function FlyoutButton_OnEnter(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
    if PlayerHasToy(btn.itemID) then
        GameTooltip:SetToyByItemID(btn.itemID)
    else
        GameTooltip:SetItemByID(btn.itemID)
    end
    GameTooltip:Show()
end

local function FlyoutButton_OnLeave()
    GameTooltip:Hide()
end

-- ------------------------------------------------------------
-- CreateFlyoutButton: 创建抽屉内的安全动作按钮（原生外观）
-- ------------------------------------------------------------
-- 视觉三件套均使用暴雪原生贴图，与动作条按钮观感一致
local function CreateFlyoutButton(panel, itemID)
    local btn = CreateFrame("Button", nil, panel, "SecureActionButtonTemplate")
    btn.itemID = itemID
    btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)

    -- 图标
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetAllPoints()
    icon:SetTexture(FALLBACK_ICON)
    btn.Icon = icon

    -- 常态边框（原生 UI-Quickslot2，66px 贴图居中于 36px 按钮）
    btn:SetNormalTexture("Interface\\Buttons\\UI-Quickslot2")
    btn:GetNormalTexture():SetSize(NORMAL_TEXTURE_SIZE, NORMAL_TEXTURE_SIZE)
    btn:GetNormalTexture():SetPoint("CENTER")

    -- 按下态
    btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    btn:GetPushedTexture():SetSize(NORMAL_TEXTURE_SIZE, NORMAL_TEXTURE_SIZE)
    btn:GetPushedTexture():SetPoint("CENTER")

    -- 高亮态
    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    btn:GetHighlightTexture():SetAllPoints()

    -- 冷却转圈
    local cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    btn.Cooldown = cooldown

    -- 安全行为：使用玩具 + 点击后收起抽屉（全硬件事件链，战斗中可用）
    btn:SetAttribute("type", "macro")
    btn:SetAttribute("macrotext", ('/use "item:%d"\n/click %s'):format(itemID, CLOSE_BUTTON_NAME))

    -- 点击穿透给根容器：使根容器的「点击任意处关闭」同时生效
    btn:SetPropagateMouseClicks(true)
    btn:SetPropagateMouseMotion(true)

    btn:SetScript("OnEnter", FlyoutButton_OnEnter)
    btn:SetScript("OnLeave", FlyoutButton_OnLeave)

    return btn
end

-- ------------------------------------------------------------
-- BuildSecureUI: 一次性构建全部安全 UI（仅限脱战状态调用）
-- ------------------------------------------------------------
-- 返回 true 表示构建完成；战斗锁定中返回 false（由调用方推迟）
local function BuildSecureUI()
    if built then return true end
    if InCombatLockdown() then return false end

    -- ---- 1. 安全根容器（全屏，负责点击关闭与 ESC 关闭）----
    -- 必须用 Button 而非 Frame：SecureHandlerClickTemplate 的 _onclick
    -- 通过包装组件的 OnClick 脚本实现，Frame 没有 OnClick 脚本，
    -- 设置 _onclick 会报 "Unknown script element OnClick" 且点击关闭失效
    root = CreateFrame("Button", "JFDrawerRoot", UIParent, "SecureHandlerShowHideTemplate,SecureHandlerClickTemplate")
    root:RegisterForClicks("AnyUp")            -- Button 默认只响应左键抬起，注册后左右键均可关闭
    root:SetAllPoints()
    root:SetFrameStrata("BACKGROUND")          -- 置于最底层，不遮挡正常 UI 的点击
    root:EnableMouse(true)                     -- 接收「点击世界/空白处」以关闭抽屉
    root:SetPropagateMouseClicks(true)         -- 点击同时穿透给下层（世界/其他UI），不打断操作
    root:SetPropagateMouseMotion(true)
    root:SetAttribute("_onclick", [=[ self:Hide() ]=])
    -- 展开期间把 ESC 绑定为「点击根容器」（即关闭抽屉），收起时清除绑定
    root:SetAttribute("_onshow", [=[ self:SetBindingClick(true, "ESCAPE", self) ]=])
    root:SetAttribute("_onhide", [=[ self:ClearBindings() ]=])
    root:Hide()

    -- ---- 2. 关闭处理器（按钮 macrotext 中的 /click 目标）----
    local closeBtn = CreateFrame("Button", CLOSE_BUTTON_NAME, UIParent, "SecureHandlerClickTemplate")
    closeBtn:RegisterForClicks("AnyUp")
    closeBtn:SetFrameRef("Root", root)
    closeBtn:SetAttribute("_onclick", [=[ self:GetFrameRef("Root"):Hide() ]=])
    closeBtn:Hide()

    -- ---- 3. 逐抽屉创建面板与按钮 ----
    for index, drawer in ipairs(DRAWERS) do
        -- 面板：原生提示框样式（黑底 + 细边框）
        -- BackdropTemplateMixin 是 Lua mixin 表而非 XML 虚拟模板，
        -- 不能作为 CreateFrame 的模板参数，需创建后用 Mixin 混入
        local panel = CreateFrame("Frame", nil, root)
        Mixin(panel, BackdropTemplateMixin)
        panel:SetBackdrop({
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        panel:SetBackdropColor(0.09, 0.09, 0.19, 0.92)   -- 与 GameTooltip 底色一致
        panel:SetBackdropBorderColor(1, 1, 1, 1)
        panel:SetFrameStrata("FULLSCREEN_DIALOG")        -- 浮于常规 UI 之上（提示框为 TOOLTIP 层，仍高于它）
        panel:EnableMouse(true)                          -- 拦截落在面板背景上的点击，避免误关抽屉
        panel:SetClampedToScreen(true)                   -- 鼠标贴近屏幕边缘时面板不出屏
        panel:SetClampRectInsets(-8, 8, 8, -8)

        -- 网格排列按钮（数量超出 MAX_ITEMS 的部分截断忽略）
        drawer.buttons = {}
        local numItems = math.min(#drawer.items, MAX_ITEMS)
        for i = 1, numItems do
            local itemID = drawer.items[i]
            local btn = CreateFlyoutButton(panel, itemID)
            local col = (i - 1) % BUTTONS_PER_ROW
            local row = math.floor((i - 1) / BUTTONS_PER_ROW)
            btn:SetPoint("TOPLEFT", panel, "TOPLEFT",
                PANEL_PADDING + col * (BUTTON_SIZE + BUTTON_GAP),
                -(PANEL_PADDING + row * (BUTTON_SIZE + BUTTON_GAP)))
            drawer.buttons[i] = btn
        end

        -- 面板尺寸由按钮数量决定（内容固定，脱战时算好，展开时无需再改）
        local cols = math.min(numItems, BUTTONS_PER_ROW)
        local rows = math.ceil(numItems / BUTTONS_PER_ROW)
        panel:SetSize(
            PANEL_PADDING * 2 + cols * BUTTON_SIZE + (cols - 1) * BUTTON_GAP,
            PANEL_PADDING * 2 + rows * BUTTON_SIZE + (rows - 1) * BUTTON_GAP)

        -- 面板脚本：展开时刷新图标/置灰/冷却并监听冷却事件，收起后解绑（零开销）
        panel:SetScript("OnShow", function(self)
            RefreshButtonStates()
            UpdateCooldowns()
            SyncClickRegistration()
            self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
            self:RegisterEvent("BAG_UPDATE_COOLDOWN")
        end)
        panel:SetScript("OnHide", function(self)
            self:UnregisterEvent("SPELL_UPDATE_COOLDOWN")
            self:UnregisterEvent("BAG_UPDATE_COOLDOWN")
        end)
        panel:SetScript("OnEvent", UpdateCooldowns)
        panel:Hide()

        panels[index] = panel
    end

    -- ---- 4. 逐抽屉创建开关处理器（宏 /click 的目标）----
    toggleSnippet = TOGGLE_SNIPPET_FORMAT:format(#DRAWERS)
    for index in ipairs(DRAWERS) do
        local handler = CreateFrame("Button", HANDLER_NAME_PREFIX .. index, UIParent, "SecureHandlerClickTemplate")
        handler:RegisterForClicks("AnyUp")
        handler:SetID(index)   -- 片段内用 ID 标识自己对应的抽屉
        handler:SetFrameRef("Root", root)
        handler:SetFrameRef("UIParent", UIParent)
        -- 引用所有面板，展开前先隐藏其他抽屉
        for j, panel in ipairs(panels) do
            handler:SetFrameRef("Panel" .. j, panel)
        end
        handler:SetAttribute("_onclick", toggleSnippet)
        handler:Hide()
        handlers[index] = handler
    end

    SyncClickRegistration()
    built = true
    return true
end

-- ------------------------------------------------------------
-- ApplyEnabledState: 应用启用/禁用状态（仅限脱战状态调用）
-- ------------------------------------------------------------
-- 禁用 = 清空处理器的 _onclick 片段（宏点击不再有任何反应）
--        并收起抽屉；保留宏本身，玩家可自行在宏界面删除
local function ApplyEnabledState(enabled)
    if not built then return end
    if InCombatLockdown() then
        pendingState = enabled
        return
    end
    for _, handler in ipairs(handlers) do
        handler:SetAttribute("_onclick", enabled and toggleSnippet or nil)
    end
    if not enabled then
        root:Hide()
    end
end

-- ------------------------------------------------------------
-- OnEvent: 事件分发
-- ------------------------------------------------------------
-- PLAYER_REGEN_ENABLED：补执行战斗锁定期间被推迟的构建/建宏/状态切换
-- TOYS_UPDATED：学会新玩具后刷新按钮置灰状态
local function OnEvent(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if pendingBuild then
            pendingBuild = false
            if module.enabled and BuildSecureUI() then
                RefreshButtonStates()
            end
        end
        if pendingState ~= nil then
            local state = pendingState
            pendingState = nil
            ApplyEnabledState(state)
        end
        -- 禁用期间的延迟清理完成后，脱战事件也不再需要
        if not module.enabled and not pendingBuild and pendingState == nil then
            eventFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
        end
    elseif event == "TOYS_UPDATED" then
        RefreshButtonStates()
    end
end

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
-- 1. 注册脱战/玩具更新事件
-- 2. 首次启用时构建安全 UI（战斗中则推迟到脱战）
-- 3. 再次启用时恢复处理器的点击片段
function module:OnEnable()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEvent)
    end
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("TOYS_UPDATED")

    if not built then
        if BuildSecureUI() then
            RefreshButtonStates()
        else
            pendingBuild = true
        end
    else
        ApplyEnabledState(true)
    end
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
-- 1. 解绑事件（战斗中保留脱战事件以完成延迟清理），实现零开销
-- 2. 清空处理器点击片段并收起抽屉（战斗中推迟到脱战）
-- 注意：宏由玩家手动创建，本模块从不触碰；禁用后宏点击无反应
function module:OnDisable()
    if not eventFrame then return end
    eventFrame:UnregisterEvent("TOYS_UPDATED")
    if InCombatLockdown() then
        pendingState = false   -- 保留 PLAYER_REGEN_ENABLED，脱战后清理
    else
        eventFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
        ApplyEnabledState(false)
    end
end
