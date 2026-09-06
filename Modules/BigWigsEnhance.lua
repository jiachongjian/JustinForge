-- ============================================================
-- JustinForge 模块15: BigWigs 中央技能提醒 (BigWigsEnhance.lua)
-- ============================================================
-- 功能：当 BigWigs / LittleWigs 计时条中的技能进入最后 5 秒
--   倒数时，在屏幕中央显示该技能的提醒：
--     左侧：技能图标（无边框、无缩放，正方形圆角；
--           以法术名称为锚点，尺寸增大时向左延伸）
--     中间：法术名称（跟随 BigWigs 条上显示的文本，含重命名；
--           自动去除末尾括号中的施法次数；颜色跟随该技能的
--           计时条颜色；整体居中展示）
--     右侧：整数倒计时（剩余 5 秒出现、0 秒消失，保留整数；
--           以法术名称为锚点向右延伸）
--   多条计时条同时进入倒数时，提醒以设定位置为底部锚点向上堆叠。
--
-- 实现方式（对照 BigWigs-v423 / LibCandyBar-3.0 源码核实，零侵入）：
--   1. 仅通过 BigWigsLoader.RegisterMessage 监听
--      BigWigs_BarCreated 消息（参数：plugin, bar, module, key,
--      text, time, icon, isApprox）。不修改、不 hook BigWigs 的
--      任何函数与计时条对象，不影响 BigWigs 全部功能与显示。
--   2. 倒计时驱动：自建隐藏框架 OnUpdate 轮询被监视条的公开字段
--      bar.running / bar.remaining（LibCandyBar 条对象自带），
--      全程无需获取 LibCandyBar 库本体，彻底规避其按需加载问题。
--   3. 条结束（running 置 nil）或被延长（remaining 回升超过窗口）
--      时自动回收对应提醒框架；条对象被 LibCandyBar 回收复用时
--      会先收到新的 BarCreated，此时清掉旧提醒避免残留旧内容。
--   4. 至暗之夜安全值防护：remaining / label / icon 均可能是 secret
--      value，比较/gsub/SetTexture 前一律 issecretvalue 防护。
--   5. 图标圆角：MaskTexture（Media/RoundedRect.tga）。
--   6. 未检测到 BigWigs 时 OnEnable 聊天提示并静默，不影响其他模块。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local pcall = pcall
local wipe = wipe
local pairs = pairs
local math_ceil = math.ceil
local math_max = math.max
local table_remove = table.remove
local issecretvalue = _G.issecretvalue

-- 屏幕尺寸在文件加载时即可获取，作为坐标滑条上限
local screenWidth = math.floor(UIParent:GetWidth() or 1920)
local screenHeight = math.floor(UIParent:GetHeight() or 1080)
local halfWidth = math.floor(screenWidth / 2)
local halfHeight = math.floor(screenHeight / 2)

-- ------------------------------------------------------------
-- 常量
-- ------------------------------------------------------------
local ALERT_WINDOW = 5          -- 倒数进入该秒数时开始显示提醒
local MAX_ALERTS = 5            -- 同时显示的提醒数量上限
local DEFAULT_SPACING = 8       -- 多条提醒之间的默认纵向间距（px）
local UPDATE_THROTTLE = 0.05    -- 倒计时轮询节流（秒）
local DEFAULT_NAME_SIZE = 22
local DEFAULT_COUNT_SIZE = 26
local DEFAULT_ICON_SIZE = 30
-- 图标圆角蒙版（白色圆角矩形 + alpha，AddMaskTexture 裁剪图标）
local ICON_MASK = "Interface\\AddOns\\JustinForge\\Media\\RoundedRect.tga"
-- 施法次数后缀：BigWigs 模块以 CL.count:format 拼入 label
-- （英文客户端 "%s (%d)" 半角括号；中文客户端 "%s（%d）" 全角括号）
-- 注意：Lua 模式匹配按字节处理，全角括号是 3 字节 UTF-8 序列，
-- 放进字符类 [...] 会被拆成单字节导致 %d+ 永远匹配不上，
-- 必须写成字面序列单独匹配（UTF-8 字节的每个字节都不是魔法字符）
local CAST_COUNT_PATTERNS = { "%s*%(%d+%)$", "%s*（%d+）$" }
-- 倒计时小数位格式串（下标 = 小数位数 + 1）
local COUNT_FORMATS = { "%.0f", "%.1f", "%.2f" }

-- ============================================================
-- 模块注册
-- ============================================================
-- 不声明 subcategory：模块显示在主设置页最底部（未列入
-- CATEGORY_LAYOUT 的模块由 Config.lua 自动追加到面板末尾，
-- 并以模块名作为分类标题）
local module = ns.Module:Register({
    key            = "bigWigsEnhance",
    name           = L["BWE_Name"],
    description    = L["BWE_Desc"],
    defaultEnabled = true,

    options = {
        { type = "slider", key = "countDecimals",name = L["BWE_CountDecimals"],tooltip = L["BWE_CountDecimalsTip"],min = 0,   max = 2,  step = 1, default = 0 },
        { type = "slider", key = "posX",         name = L["BWE_PosX"],         tooltip = L["BWE_PosTip"],          min = -halfWidth,  max = halfWidth,  step = 1, default = 0 },
        { type = "slider", key = "posY",         name = L["BWE_PosY"],         tooltip = L["BWE_PosTip"],          min = -halfHeight, max = halfHeight, step = 1, default = 0 },
        { type = "slider", key = "spacing",      name = L["BWE_Spacing"],      tooltip = L["BWE_SpacingTip"],      min = 0,   max = 40, step = 1, default = DEFAULT_SPACING },
        { type = "slider", key = "nameFontSize", name = L["BWE_NameFontSize"], tooltip = L["BWE_NameFontSizeTip"], min = 10,  max = 48, step = 1, default = DEFAULT_NAME_SIZE },
        { type = "slider", key = "countFontSize",name = L["BWE_CountFontSize"],tooltip = L["BWE_CountFontSizeTip"],min = 10,  max = 48, step = 1, default = DEFAULT_COUNT_SIZE },
        { type = "slider", key = "iconSize",     name = L["BWE_IconSize"],     tooltip = L["BWE_IconSizeTip"],     min = 12,  max = 64, step = 1, default = DEFAULT_ICON_SIZE },
        { type = "slider", key = "iconOffsetX",  name = L["BWE_IconOffsetX"],  tooltip = L["BWE_IconOffsetXTip"],  min = -20, max = 20, step = 1, default = 0 },
        { type = "slider", key = "iconOffsetY",  name = L["BWE_IconOffsetY"],  tooltip = L["BWE_IconOffsetYTip"],  min = -20, max = 20, step = 1, default = 0 },
        { type = "slider", key = "countOffsetX", name = L["BWE_CountOffsetX"], tooltip = L["BWE_CountOffsetXTip"], min = -20, max = 20, step = 1, default = 0 },
        { type = "button", key = "preview",      name = L["BWE_Preview"],      buttonText = L["BWE_PreviewBtn"],   tooltip = L["BWE_PreviewTip"] },
        { type = "button", key = "stopPreview",  name = L["BWE_StopPreview"],  buttonText = L["BWE_StopPreviewBtn"], tooltip = L["BWE_StopPreviewTip"] },
    },
})

-- ============================================================
-- 状态
-- ============================================================
local watchedBars = {}    -- 被监视的计时条：bar → icon（创建消息携带的图标）
local activeAlerts = {}   -- 正在显示的提醒：bar → frame
local alertOrder = {}     -- 提醒获取顺序（bar 数组），用于纵向堆叠定位
local alertPool = {}      -- 提醒框架池（复用，上限 MAX_ALERTS）
local updater             -- 倒计时轮询框架（懒创建，无监视目标时停表）
local hooked = false      -- 是否已挂载 BigWigs 消息监听

-- ------------------------------------------------------------
-- GetOption: 读取本模块某设置项的当前值
-- ------------------------------------------------------------
local function GetOption(key)
    local db = ns.db and ns.db.profile and ns.db.profile[module.key]
    return db and db[key]
end

-- FormatCountdown: 按「倒计时小数点」设置格式化剩余秒数
-- 0 位小数时用 ceil（5.0→5、0.2→1，符合倒数习惯）；1/2 位直接截断格式化
local function FormatCountdown(remaining)
    local decimals = GetOption("countDecimals") or 0
    if decimals > 0 then
        return COUNT_FORMATS[decimals + 1]:format(remaining)
    end
    return math_ceil(remaining)
end

-- ============================================================
-- 前置声明
-- ============================================================
local ReleaseAlert   -- 回收单个提醒框架
local UpdateAlert    -- 创建/刷新单个提醒框架

-- ============================================================
-- 提醒框架：创建与布局
-- ============================================================
-- 框架为无背景容器：名称 FontString 居中，图标/倒计时分别锚在
-- 名称左右两侧（名称文本变宽时两侧自动外扩，即「以名称为锚点」）
local function CreateAlertFrame()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("HIGH")
    f:SetSize(1, 1)   -- 无背景容器，尺寸无视觉意义
    f:Hide()

    -- 中间：法术名称（居中锚点）
    -- 注意：FontString 必须先 SetFont 才能 SetText（否则报 Font not set），
    -- 此处先给默认字体， configured 字号由 LayoutAlertFrame 覆盖
    f.name = f:CreateFontString(nil, "OVERLAY")
    f.name:SetFont(STANDARD_TEXT_FONT, DEFAULT_NAME_SIZE, "OUTLINE")
    f.name:SetPoint("CENTER", f, "CENTER", 0, 0)

    -- 左侧：图标（RIGHT 锚名称 LEFT：尺寸增大时向左延伸）
    f.icon = f:CreateTexture(nil, "ARTWORK")
    -- 正方形圆角：蒙版裁剪（无边框、无 SetTexCoord 缩放）
    f.iconMask = f:CreateMaskTexture()
    f.iconMask:SetTexture(ICON_MASK)
    f.iconMask:SetAllPoints(f.icon)
    f.icon:AddMaskTexture(f.iconMask)

    -- 右侧：倒计时（LEFT 锚名称 RIGHT：数字变化时向右延伸）
    f.count = f:CreateFontString(nil, "OVERLAY")
    f.count:SetFont(STANDARD_TEXT_FONT, DEFAULT_COUNT_SIZE, "OUTLINE")
    f.count:SetTextColor(1, 1, 1, 1)

    return f
end

-- LayoutAlertFrame: 应用字号/尺寸/偏移等样式设置到单个提醒框架
local function LayoutAlertFrame(f)
    local iconSize = GetOption("iconSize") or DEFAULT_ICON_SIZE
    f.icon:SetSize(iconSize, iconSize)
    f.icon:ClearAllPoints()
    f.icon:SetPoint("RIGHT", f.name, "LEFT", GetOption("iconOffsetX") or 0, GetOption("iconOffsetY") or 0)
    f.name:SetFont(STANDARD_TEXT_FONT, GetOption("nameFontSize") or DEFAULT_NAME_SIZE, "OUTLINE")
    f.count:SetFont(STANDARD_TEXT_FONT, GetOption("countFontSize") or DEFAULT_COUNT_SIZE, "OUTLINE")
    f.count:ClearAllPoints()
    f.count:SetPoint("LEFT", f.name, "RIGHT", GetOption("countOffsetX") or 0, 0)
end

-- LayoutAlerts: 按获取顺序纵向堆叠所有活跃提醒
-- 以设定坐标为底部锚点向上增长：最先出现的提醒在底部，
-- 后出现的依次向上堆叠，间距由「技能间距」设置控制
local function LayoutAlerts()
    local posX = GetOption("posX") or 0
    local posY = GetOption("posY") or 0
    local lineHeight = math_max(
        GetOption("iconSize") or DEFAULT_ICON_SIZE,
        GetOption("nameFontSize") or DEFAULT_NAME_SIZE,
        GetOption("countFontSize") or DEFAULT_COUNT_SIZE) + (GetOption("spacing") or DEFAULT_SPACING)
    for i = 1, #alertOrder do
        local f = activeAlerts[alertOrder[i]]
        if f then
            f:ClearAllPoints()
            f:SetPoint("CENTER", UIParent, "CENTER", posX, posY + (i - 1) * lineHeight)
        end
    end
end

-- AcquireAlertFrame: 从池中取一个空闲提醒框架（池满返回 nil）
local function AcquireAlertFrame()
    for i = 1, #alertPool do
        local f = alertPool[i]
        if not f:IsShown() then
            return f
        end
    end
    if #alertPool >= MAX_ALERTS then
        return nil
    end
    local f = CreateAlertFrame()
    alertPool[#alertPool + 1] = f
    return f
end

-- ReleaseAlert: 回收单个提醒框架（隐藏并归还池中，重排剩余提醒）
ReleaseAlert = function(bar)
    local f = activeAlerts[bar]
    if not f then return end
    activeAlerts[bar] = nil
    for i = 1, #alertOrder do
        if alertOrder[i] == bar then
            table_remove(alertOrder, i)
            break
        end
    end
    f:Hide()
    LayoutAlerts()
end

-- ============================================================
-- 提醒内容
-- ============================================================
-- SetupAlertContent: 设置提醒的静态内容（名称/颜色/图标）
-- ------------------------------------------------------------
-- 名称取 bar:GetLabel()（即 BigWigs 条上显示的文本，含重命名），
-- 去除末尾施法次数后缀；颜色跟随该技能计时条颜色
-- （BigWigs 按技能类型经 Colors 插件 SetColor 到 candyBarBar）。
-- 调用方已 pcall 包裹；label/icon 可能是 secret value，先防护。
local function SetupAlertContent(f, bar, icon)
    local text = bar:GetLabel()
    if text and not issecretvalue(text) then
        -- 依次尝试半角/全角括号两种次数后缀（见 CAST_COUNT_PATTERNS 注释）
        for i = 1, #CAST_COUNT_PATTERNS do
            text = text:gsub(CAST_COUNT_PATTERNS[i], "")
        end
    end
    -- secret string 无法 gsub，但可直接 SetText 显示（仅 Lua 侧不可读）
    f.name:SetText(text or "")

    local statusBar = bar.candyBarBar
    if statusBar then
        local r, g, b = statusBar:GetStatusBarColor()
        if r then
            f.name:SetTextColor(r, g, b, 1)
        end
    end

    if (type(icon) == "number" or type(icon) == "string") and not issecretvalue(icon) then
        f.icon:SetTexture(icon)
        f.icon:Show()
    else
        f.icon:Hide()
    end
end

-- UpdateAlert: 倒数进入窗口时创建提醒，并刷新倒计时数字
-- ------------------------------------------------------------
-- 倒计时文本由 FormatCountdown 按「倒计时小数点」设置格式化；
-- 条到 0 秒由 running 置 nil 触发回收（即「0 秒消失」）。
-- 颜色随文本刷新一次，覆盖条状态变化（如转为醒目）导致的颜色切换。
UpdateAlert = function(bar, icon, remaining)
    local f = activeAlerts[bar]
    if not f then
        f = AcquireAlertFrame()
        if not f then return end   -- 超出同时显示上限，跳过
        activeAlerts[bar] = f
        alertOrder[#alertOrder + 1] = bar
        f.lastText = nil
        pcall(SetupAlertContent, f, bar, icon)
        LayoutAlertFrame(f)
        f:Show()
        LayoutAlerts()
    end
    local text = FormatCountdown(remaining)
    if text ~= f.lastText then
        f.lastText = text
        f.count:SetText(text)
        local statusBar = bar.candyBarBar
        if statusBar then
            local r, g, b = statusBar:GetStatusBarColor()
            if r then
                f.name:SetTextColor(r, g, b, 1)
            end
        end
    end
end

-- ============================================================
-- 倒计时轮询
-- ============================================================
-- 节流 OnUpdate 轮询所有被监视条：
--   running 为 nil        → 条已结束/被移除：取消监视并回收提醒
--   remaining ≤ 5 且 > 0  → 进入倒数窗口：创建/刷新提醒
--   remaining > 5         → 条被延长（SetDuration 重新计时）：回收提醒
--   remaining 为 secret   → 无法比较，跳过（该帧维持现状）
local function OnUpdateTick(self, elapsed)
    self.elapsed = (self.elapsed or 0) + elapsed
    if self.elapsed < UPDATE_THROTTLE then return end
    self.elapsed = 0

    for bar, icon in pairs(watchedBars) do
        if not bar.running then
            watchedBars[bar] = nil
            ReleaseAlert(bar)
        else
            local remaining = bar.remaining
            if type(remaining) == "number" and not issecretvalue(remaining) then
                if remaining > 0 and remaining <= ALERT_WINDOW then
                    UpdateAlert(bar, icon, remaining)
                elseif remaining > ALERT_WINDOW then
                    ReleaseAlert(bar)
                end
            end
        end
    end

    -- 无监视条且无活跃提醒时停表（零开销），下一条 BarCreated 再启动
    if not next(watchedBars) and not next(activeAlerts) then
        self:Hide()
    end
end

local function EnsureUpdater()
    if not updater then
        updater = CreateFrame("Frame")
        updater:Hide()
        updater:SetScript("OnUpdate", OnUpdateTick)
    end
    return updater
end

-- ============================================================
-- 预览
-- ============================================================
-- 预览使用与真实提醒完全相同的框架结构与布局函数（所见即所得），
-- 内容为模拟数据：通用法术图标 + 示例名称 + 5→1 循环倒计时。
-- 预览是纯自建框架，不依赖 BigWigs 是否加载；状态不持久化，
-- 每次登录/重载界面后默认不预览。
local previewFrame           -- 预览框架（懒创建一次，反复复用）
local previewTicker          -- 倒计时循环计时器

local function StopPreview()
    if previewTicker then
        previewTicker:Cancel()
        previewTicker = nil
    end
    if previewFrame then
        previewFrame:Hide()
    end
end

local function StartPreview()
    StopPreview()
    if not previewFrame then
        previewFrame = CreateAlertFrame()
    end
    local f = previewFrame
    f.name:SetText(L["BWE_PreviewLabel"])
    f.name:SetTextColor(1, 0.25, 0.25, 1)   -- 示例颜色（模拟技能条着色）
    f.icon:SetTexture(136235)               -- 通用法术图标（仅示意）
    f.icon:Show()
    LayoutAlertFrame(f)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", GetOption("posX") or 0, GetOption("posY") or 0)
    local remaining = ALERT_WINDOW
    f.count:SetText(FormatCountdown(remaining))
    f:Show()
    -- 5→0 循环倒数，按「倒计时小数点」设置演示效果
    previewTicker = C_Timer.NewTicker(UPDATE_THROTTLE, function()
        remaining = remaining - UPDATE_THROTTLE
        if remaining <= 0 then
            remaining = ALERT_WINDOW
        end
        f.count:SetText(FormatCountdown(remaining))
    end)
end

-- ============================================================
-- BigWigs 消息回调
-- ============================================================
-- 每条计时条创建时触发（CallbackHandler 签名：func(event, ...)，
-- 参数：plugin, bar, module, key, text, time, icon, isApprox）
local function OnBarCreated(event, plugin, bar, bwModule, key, text, time, icon, isApprox)
    if not bar then return end
    -- 条对象可能被 LibCandyBar 回收复用：若旧提醒还挂着，先清掉
    -- （内容属于上一条逻辑条），再以新内容重新进入监视
    if activeAlerts[bar] then
        ReleaseAlert(bar)
    end
    watchedBars[bar] = icon
    EnsureUpdater():Show()
end

-- ============================================================
-- HookBigWigs / UnhookBigWigs：挂载与卸载 BigWigs 消息监听
-- ============================================================
-- 幂等；返回是否成功挂载（未检测到 BigWigs 时返回 false）
local function HookBigWigs()
    if hooked then return true end
    if not _G.BigWigsLoader then return false end
    -- 注意：RegisterMessage 必须用小数点调用（冒号调用会被其
    -- 内部 __index 包装直接报错），module 表作为消息接收者标识
    BigWigsLoader.RegisterMessage(module, "BigWigs_BarCreated", OnBarCreated)
    hooked = true
    return true
end

local function UnhookBigWigs()
    if not hooked then return end
    hooked = false
    if _G.BigWigsLoader then
        BigWigsLoader.UnregisterMessage(module, "BigWigs_BarCreated")
    end
end

-- ============================================================
-- OnEnable: 模块启用
-- ============================================================
function module:OnEnable()
    if not HookBigWigs() then
        -- 未安装/未启用 BigWigs：仅提示，模块保持静默，不影响其他模块
        Util:Print(L["BWE_NoBigWigs"])
        return
    end
    Util:Debug("BigWigsEnhance: 已挂载 BigWigs 中央技能提醒")
end

-- ============================================================
-- OnDisable: 模块禁用
-- ============================================================
function module:OnDisable()
    UnhookBigWigs()
    StopPreview()
    if updater then
        updater:Hide()
    end
    wipe(watchedBars)
    for bar, f in pairs(activeAlerts) do
        f:Hide()
    end
    wipe(activeAlerts)
    wipe(alertOrder)
    Util:Debug("BigWigsEnhance: 已禁用")
end

-- ============================================================
-- OnOptionChanged: 设置项变更（Config.lua 自动调用）
-- ============================================================
-- Config 侧在值写入 dbEntry 之后才触发本回调，GetOption 读到的即新值。
-- 即时生效：对所有活跃提醒重应用样式并重排堆叠位置。
function module:OnOptionChanged(key, value)
    if not module.enabled then return end
    for bar, f in pairs(activeAlerts) do
        LayoutAlertFrame(f)
    end
    LayoutAlerts()
    -- 预览正在展示时同步刷新样式与位置
    if previewFrame and previewFrame:IsShown() then
        LayoutAlertFrame(previewFrame)
        previewFrame:ClearAllPoints()
        previewFrame:SetPoint("CENTER", UIParent, "CENTER", GetOption("posX") or 0, GetOption("posY") or 0)
    end
end

-- ============================================================
-- OnButtonClicked: 设置面板按钮（Config.lua 自动调用）
-- ============================================================
function module:OnButtonClicked(optKey)
    if optKey == "preview" then
        StartPreview()
    elseif optKey == "stopPreview" then
        StopPreview()
    end
end
