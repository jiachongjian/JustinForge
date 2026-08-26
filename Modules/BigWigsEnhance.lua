-- ============================================================
-- JustinForge 模块15: BigWigs 计时条扩展 (BigWigsEnhance.lua)
-- ============================================================
-- 功能：在不修改、不 hook BigWigs / LittleWigs 任何函数的前提下，
--   通过设置面板微调 BigWigs 计时条（含醒目计时条）的样式：
--     1. 醒目条四元素独立样式：图标、特殊图标（灭团技/坦克/治疗
--        等 spell indicators）、法术名称、施法时间，各自支持
--        字号 / X·Y 偏移 / 尺寸 / 间距微调
--     2. 隐藏醒目条法术名末尾括号中的施法次数（如 "技能名 (2)"）
--     3. 倒计时整数化：剩余时间 10 秒以内不再显示小数点后 1 位
--   设置改动即时作用于当前活跃的醒目条；提供「预览/停止预览」
--   按钮在屏幕中央展示模拟醒目条以实时查看效果。
--
-- 实现方式（对照 BigWigs-v423 源码核实，零侵入）：
--   1. 消息接入：BigWigsLoader.RegisterMessage(module, event, func)
--      监听 BigWigs_BarCreated / BigWigs_BarEmphasized /
--      BigWigs_ProfileUpdate。注意必须用小数点调用（非冒号）。
--      LittleWigs 的计时条同样由 BigWigs Bars 插件渲染，自动覆盖。
--   2. 覆盖时机：BigWigs_BarEmphasized 在 EmphasizeBar 内部
--      SetFont(fontSizeEmph) 与 rearrangeBars 重设 indicator 之后
--      发出，是唯一安全的样式覆盖点；BigWigs_ProfileUpdate 时对
--      活跃强调条重应用，防 BigWigs 配置变更重置。
--   3. 倒计时取整：LibCandyBar 的 barUpdate 在设置时间文本之后
--      执行 bar.funcs 回调，故 BigWigs_BarCreated 时对每条 bar
--      AddUpdateFunction，仅 remaining<10 时覆盖为整数文本；
--      bar 回收时 funcs 自动清空，新条需重挂。
--   4. 隐藏计数：BarEmphasized 时 bar:GetLabel() → issecretvalue
--      防护（12.0 下 label 可能是 secret string）→ gsub 去掉
--      末尾 "(n)" / "（n）" → bar:SetLabel()。
--   5. 样式微调：只改 bar 对象的 FontString/Texture/Frame 属性
--      （candyBarLabel / candyBarDuration / candyBarIconFrame /
--      bigwigs:indicatorFrame），首次覆盖前把原值快照到
--      bar.data.jfSaved（bar 回收时 data 自动清空，快照随之失效），
--      禁用模块时遍历活跃条还原。
--   6. 预览：自建 LibCandyBar 预览条（结构与真实条一致），锚在
--      屏幕中央循环计时，复用同一套样式覆盖函数；停止预览时
--      正常 Stop 回收。预览条不属于 BigWigs 锚点，Bars 插件仅
--      注册了 LibCandyBar_Stop（触发自身重排，无害）。
--   7. 未检测到 BigWigs 时 OnEnable 聊天提示并跳过，不影响
--      其他模块；所有 BigWigs 交互均以 pcall 包裹。
--
-- 注意：本模块全部设置项显示在设置面板的独立子分类页中
--   （模块表 subcategory = true，由 Core/Config.lua 识别处理）。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local pcall = pcall
local wipe = wipe
local pairs = pairs
local issecretvalue = _G.issecretvalue

-- ============================================================
-- 模块注册
-- ============================================================
-- subcategory = true：本模块的启用开关与全部设置项归入设置面板
-- 的独立子分类页（Core/Config.lua 中处理，失败时回退主分类）
local module = ns.Module:Register({
    key            = "bigWigsEnhance",
    name           = L["BWE_Name"],
    description    = L["BWE_Desc"],
    defaultEnabled = true,
    subcategory    = true,

    options = {
        -- ---- 通用 ----
        { type = "header",   name = L["BWE_HeaderGeneral"] },
        { type = "checkbox", key = "integerTimer",  name = L["BWE_IntegerTimer"],    tooltip = L["BWE_IntegerTimerTip"],    default = true },
        { type = "checkbox", key = "hideCastCount", name = L["BWE_HideCastCount"],   tooltip = L["BWE_HideCastCountTip"],   default = true },
        -- ---- 醒目条：法术名称 ----
        { type = "header",   name = L["BWE_HeaderLabel"] },
        { type = "slider", key = "labelFontSize",   name = L["BWE_LabelFontSize"],   tooltip = L["BWE_FontSizeTip"],        min = 0,   max = 24, step = 1, default = 0 },
        { type = "slider", key = "labelOffsetX",    name = L["BWE_LabelOffsetX"],    tooltip = L["BWE_OffsetTip"],          min = -50, max = 50, step = 1, default = 0 },
        { type = "slider", key = "labelOffsetY",    name = L["BWE_LabelOffsetY"],    tooltip = L["BWE_OffsetTip"],          min = -50, max = 50, step = 1, default = 0 },
        -- ---- 醒目条：施法时间 ----
        { type = "header",   name = L["BWE_HeaderTime"] },
        { type = "slider", key = "timeFontSize",    name = L["BWE_TimeFontSize"],    tooltip = L["BWE_FontSizeTip"],        min = 0,   max = 24, step = 1, default = 0 },
        { type = "slider", key = "timeOffsetX",     name = L["BWE_TimeOffsetX"],     tooltip = L["BWE_OffsetTip"],          min = -50, max = 50, step = 1, default = 0 },
        { type = "slider", key = "timeOffsetY",     name = L["BWE_TimeOffsetY"],     tooltip = L["BWE_OffsetTip"],          min = -50, max = 50, step = 1, default = 0 },
        -- ---- 醒目条：图标 ----
        { type = "header",   name = L["BWE_HeaderIcon"] },
        { type = "slider", key = "iconSize",        name = L["BWE_IconSize"],        tooltip = L["BWE_IconSizeTip"],        min = 0,   max = 64, step = 1, default = 0 },
        { type = "slider", key = "textIconGap",     name = L["BWE_TextIconGap"],     tooltip = L["BWE_TextIconGapTip"],     min = 0,   max = 20, step = 1, default = 0 },
        -- ---- 醒目条：特殊图标（灭团技/坦克/治疗） ----
        { type = "header",   name = L["BWE_HeaderIndicator"] },
        { type = "slider", key = "indicatorSize",   name = L["BWE_IndicatorSize"],   tooltip = L["BWE_IndicatorSizeTip"],   min = 0,   max = 64, step = 1, default = 0 },
        { type = "slider", key = "indicatorOffsetX",name = L["BWE_IndicatorOffsetX"],tooltip = L["BWE_OffsetTip"],          min = -50, max = 50, step = 1, default = 0 },
        { type = "slider", key = "indicatorOffsetY",name = L["BWE_IndicatorOffsetY"],tooltip = L["BWE_OffsetTip"],          min = -50, max = 50, step = 1, default = 0 },
        -- ---- 预览 ----
        { type = "header",   name = L["BWE_HeaderPreview"] },
        { type = "button", key = "preview",         name = L["BWE_Preview"],         buttonText = L["BWE_PreviewBtn"],      tooltip = L["BWE_PreviewTip"] },
        { type = "button", key = "stopPreview",     name = L["BWE_StopPreview"],     buttonText = L["BWE_StopPreviewBtn"],  tooltip = L["BWE_StopPreviewTip"] },
    },
})

-- ============================================================
-- 常量与状态
-- ============================================================
local activeBars = {}    -- 活跃 BigWigs 计时条集合：bar → true
                         -- （供设置变更即时刷新、禁用模块时还原样式）
local candyLib           -- LibCandyBar-3.0 库引用（懒获取）
local hooked = false     -- 是否已挂载 BigWigs 消息监听
local previewBar         -- 屏幕中央的预览条（preview-buttons 小节创建）

-- 样式快照在 bar.data 下的键名：LibCandyBar 停止条时 data 整体清空
-- （回收复用），快照随之自然失效，新一条 bar 重新保存，无需手动清理
local SAVED_KEY = "jfSaved"

-- ------------------------------------------------------------
-- GetCandy: 获取 LibCandyBar-3.0 库（BigWigs 内嵌提供）
-- ------------------------------------------------------------
-- LibStub 为全局共享注册表，BigWigs 加载后该库即可被本插件获取；
-- 第二参数 true = 静默模式，库不存在时返回 nil 而非报错
local function GetCandy()
    if candyLib then return candyLib end
    if LibStub then
        candyLib = LibStub("LibCandyBar-3.0", true)
    end
    return candyLib
end

-- ------------------------------------------------------------
-- GetOption: 读取本模块某设置项的当前值
-- ------------------------------------------------------------
local function GetOption(key)
    local db = ns.db and ns.db.profile and ns.db.profile[module.key]
    return db and db[key]
end

-- ============================================================
-- 前置声明（具体实现见下方对应小节）
-- ============================================================
local AttachIntegerTimer    -- timer-label：为单条 bar 挂倒计时取整
local HideCastCountSuffix   -- timer-label：隐藏醒目条法术名计数后缀
local ApplyEmphStyle        -- emph-style：应用醒目条独立样式覆盖
local RestoreBar            -- emph-style：还原单条 bar 的原始样式
local StartPreview          -- preview-buttons：创建屏幕中央预览条
local StopPreview           -- preview-buttons：停止并回收预览条

-- ============================================================
-- BigWigs 消息回调
-- ============================================================
-- 回调签名（CallbackHandler 惯例）：func(event, ...)，
-- 例如 BigWigs_BarEmphasized → func("BigWigs_BarEmphasized", plugin, bar)

-- 每条计时条创建时触发（参数：plugin, bar, module, key, text, time, icon, isApprox）
local function OnBarCreated(event, plugin, bar)
    if not bar then return end
    activeBars[bar] = true
    if GetOption("integerTimer") then
        pcall(AttachIntegerTimer, bar)
    end
end

-- 计时条转为醒目条后触发（此时 BigWigs 已完成字体/图标/indicator 重置，
-- 是覆盖醒目条样式的唯一安全时机）
local function OnBarEmphasized(event, plugin, bar)
    if not bar then return end
    activeBars[bar] = true
    if GetOption("hideCastCount") then
        pcall(HideCastCountSuffix, bar)
    end
    pcall(ApplyEmphStyle, bar)
end

-- RefreshActiveEmphBars: 对所有活跃强调条重新应用样式覆盖
-- ------------------------------------------------------------
-- 供 BigWigs_ProfileUpdate 与 OnOptionChanged 共用。
-- 直接读 bar.data 而非 bar:Get()：已回收的条 data 为 nil，
-- 此时 Get 会索引 nil 抛错；回收条跳过即可（复用时会重新处理）。
local function RefreshActiveEmphBars()
    local hideCount = GetOption("hideCastCount")
    for bar in pairs(activeBars) do
        local data = bar.data
        if data and data["bigwigs:emphasized"] then
            -- 开启时对活跃条即时隐藏计数（幂等：无匹配后缀则不改动）
            if hideCount then
                pcall(HideCastCountSuffix, bar)
            end
            pcall(ApplyEmphStyle, bar)
        end
    end
end

-- BigWigs 配置/样式变更时触发：其内部会重置醒目条字体等，
-- 对所有活跃强调条重新应用本模块的样式覆盖
local function OnProfileUpdate()
    RefreshActiveEmphBars()
end

-- 计时条结束回收时从活跃集合移除（LibCandyBar_Stop 回调，签名 func(event, bar)）
-- 注意：该回调对任意插件的 LibCandyBar 条都会触发，只清理集合内已记录的条
local function OnCandyBarStop(event, bar)
    if bar then
        activeBars[bar] = nil
    end
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
    BigWigsLoader.RegisterMessage(module, "BigWigs_BarEmphasized", OnBarEmphasized)
    BigWigsLoader.RegisterMessage(module, "BigWigs_ProfileUpdate", OnProfileUpdate)
    local candy = GetCandy()
    if candy then
        candy.RegisterCallback(module, "LibCandyBar_Stop", OnCandyBarStop)
    end
    hooked = true
    return true
end

local function UnhookBigWigs()
    if not hooked then return end
    hooked = false
    if _G.BigWigsLoader then
        BigWigsLoader.UnregisterMessage(module, "BigWigs_BarCreated")
        BigWigsLoader.UnregisterMessage(module, "BigWigs_BarEmphasized")
        BigWigsLoader.UnregisterMessage(module, "BigWigs_ProfileUpdate")
    end
    if candyLib then
        candyLib.UnregisterCallback(module, "LibCandyBar_Stop")
    end
end

-- ============================================================
-- 功能实现
-- ============================================================

-- AttachIntegerTimer: 为 bar 挂倒计时取整的更新回调
-- ------------------------------------------------------------
-- LibCandyBar 内部时间格式（barUpdate / barUpdateApprox）：
--   remaining < 10 秒显示 1 位小数（普通条 "%.1f"、近似条 "~%.1f"），
--   其余区间本就是整数或 m:ss。update 回调在时间文本设置之后执行，
--   故仅 <10 时覆盖一次文本即可；其余区间零介入，不产生额外开销。
-- bar 停止回收时 funcs 自动清空（LibCandyBar 内部维护），无需卸载。
AttachIntegerTimer = function(bar)
    if not bar.AddUpdateFunction then return end
    -- 注意：LibCandyBar 的 barUpdate 对 update 回调是裸调用（无 pcall），
    -- 回调抛错会中断整个 OnUpdate 循环、冻结所有计时条，
    -- 因此回调内所有引用必须判空、所有值必须过 secret 防护
    bar:AddUpdateFunction(function(b)
        local duration = b.candyBarDuration
        if not duration then return end
        local remaining = b.remaining
        -- 12.0 下 remaining 可能是 secret number：
        -- 直接比较/算术会抛错，跳过即可（该帧维持 BigWigs 原格式）
        if not remaining or issecretvalue(remaining) then return end
        if remaining < 10 then
            -- 近似条（SetDuration 第二参 isApprox → bar.isApproximate，
            -- 时间显示带 "~" 前缀）保留前缀，与普通条区分
            if b.isApproximate == true then
                duration:SetFormattedText("~%.0f", remaining)
            else
                duration:SetFormattedText("%.0f", remaining)
            end
        end
    end)
end

-- HideCastCountSuffix: 隐藏醒目条法术名末尾的施法次数后缀
-- ------------------------------------------------------------
-- 计数后缀由 BigWigs 模块以 CL.count:format 拼入 label（如 "技能名 (2)"，
-- 中文客户端可能是全角括号 "（2）"）。此处 gsub 去掉末尾括号数字。
-- 12.0 下 label 可能是 secret string：比较/gsub 均会抛错，跳过不处理。
local CAST_COUNT_PATTERN = "%s*[%(（]%d+[%)）]$"
HideCastCountSuffix = function(bar)
    local text = bar:GetLabel()
    if not text or issecretvalue(text) then return end
    if not text:find(CAST_COUNT_PATTERN) then return end
    bar:SetLabel((text:gsub(CAST_COUNT_PATTERN, "")))
end

-- ApplyEmphStyle: 对醒目条应用四元素独立样式覆盖
-- ------------------------------------------------------------
-- 元素结构（LibCandyBar）：label/duration 是锚在 candyBarBar 上的
--   FontString（TOPLEFT+BOTTOMRIGHT 充满，默认 2px 内边距），图标
--   candyBarIconFrame 是锚在 bar 左侧的 Texture（宽=条高）。
-- 覆盖时机在 BigWigs_BarEmphasized 之后（BigWigs 已完成 SetFont 与
--   rearrangeBars 重置），因此此处直接改属性即可，无需 hook。
-- 首次覆盖前把原值快照到 bar.data[SAVED_KEY]，供禁用模块时还原。
-- 调用方已 pcall 包裹本函数；内部按元素分段保护，单项异常不影响其余。
-- SavePoints / RestorePoints: FontString/Frame 全部锚点的快照与还原
-- ------------------------------------------------------------
-- LibCandyBar 的 label/duration 原始为双锚点充满布局
-- （TOPLEFT(2,0) + BOTTOMRIGHT(-2,0)，已核实 LibCandyBar 源码），
-- 必须存全部锚点，否则还原时丢失第二点会导致宽度塌缩
local function SavePoints(region)
    local pts = {}
    for i = 1, region:GetNumPoints() do
        pts[i] = { region:GetPoint(i) }
    end
    return pts
end

local function RestorePoints(region, pts)
    if not pts or not pts[1] then return end
    region:ClearAllPoints()
    for i = 1, #pts do
        local p = pts[i]
        region:SetPoint(p[1], p[2], p[3], p[4] or 0, p[5] or 0)
    end
end

ApplyEmphStyle = function(bar)
    if not bar.candyBarLabel or not bar.candyBarBar then return end
    local data = bar.data
    if not data then return end

    -- ---- 首次覆盖前保存原状 ----
    if not data[SAVED_KEY] then
        local saved = {}
        local label = bar.candyBarLabel
        local duration = bar.candyBarDuration
        saved.labelFont   = { label:GetFont() }
        saved.labelPoints = SavePoints(label)
        saved.timeFont    = { duration:GetFont() }
        saved.timePoints  = SavePoints(duration)
        saved.iconWidth   = bar.candyBarIconFrame:GetWidth()
        local indicator = bar:Get("bigwigs:indicatorFrame")
        if indicator then
            saved.indicatorFrame = indicator
            saved.indicatorSize  = { indicator:GetSize() }
            saved.indicatorPoints = SavePoints(indicator)
        end
        data[SAVED_KEY] = saved
    end

    -- ---- 法术名称：字号 + 偏移 + 图标间距 ----
    local labelSize = GetOption("labelFontSize") or 0
    local labelOX   = GetOption("labelOffsetX") or 0
    local labelOY   = GetOption("labelOffsetY") or 0
    local gap       = GetOption("textIconGap") or 0
    if labelSize > 0 then
        local saved = data[SAVED_KEY]
        bar.candyBarLabel:SetFont(saved.labelFont[1], labelSize, saved.labelFont[3])
    end
    bar.candyBarLabel:ClearAllPoints()
    bar.candyBarLabel:SetPoint("TOPLEFT", bar.candyBarBar, "TOPLEFT", 2 + gap + labelOX, -labelOY)
    bar.candyBarLabel:SetPoint("BOTTOMRIGHT", bar.candyBarBar, "BOTTOMRIGHT", gap + labelOX, -labelOY)

    -- ---- 施法时间：字号 + 偏移 ----
    local timeSize = GetOption("timeFontSize") or 0
    local timeOX   = GetOption("timeOffsetX") or 0
    local timeOY   = GetOption("timeOffsetY") or 0
    if timeSize > 0 then
        local saved = data[SAVED_KEY]
        bar.candyBarDuration:SetFont(saved.timeFont[1], timeSize, saved.timeFont[3])
    end
    bar.candyBarDuration:ClearAllPoints()
    bar.candyBarDuration:SetPoint("TOPLEFT", bar.candyBarBar, "TOPLEFT", timeOX, -timeOY)
    bar.candyBarDuration:SetPoint("BOTTOMRIGHT", bar.candyBarBar, "BOTTOMRIGHT", -2 + timeOX, -timeOY)

    -- ---- 图标：尺寸（宽；图标锚在条左侧，向右增大不压条体） ----
    local iconSize = GetOption("iconSize") or 0
    if iconSize > 0 then
        bar.candyBarIconFrame:SetWidth(iconSize)
    end

    -- ---- 特殊图标（灭团技/坦克/治疗）：尺寸 + 偏移 ----
    -- 仅在 BigWigs 启用 spell indicators 且该条带图标时存在
    local indicator = bar:Get("bigwigs:indicatorFrame")
    if indicator then
        local indSize = GetOption("indicatorSize") or 0
        if indSize > 0 then
            -- 优先调用 BigWigs 原生 SetIndicatorSize（幂等：内部统一
            -- 缩放框体与纹理组，重复调用不累积）；自建预览条无此方法，
            -- 回退 SetSize（预览纹理 SetAllPoints 锚定，自动跟随框体）
            if indicator.SetIndicatorSize then
                indicator:SetIndicatorSize(indSize)
            else
                indicator:SetSize(indSize, indSize)
            end
        end
        local indOX = GetOption("indicatorOffsetX") or 0
        local indOY = GetOption("indicatorOffsetY") or 0
        if indOX ~= 0 or indOY ~= 0 then
            local saved = data[SAVED_KEY]
            local pt = saved.indicatorPoints and saved.indicatorPoints[1]
            if pt then
                indicator:ClearAllPoints()
                indicator:SetPoint(pt[1], pt[2], pt[3],
                    (pt[4] or 0) + indOX, (pt[5] or 0) + indOY)
            end
        end
    end
end

-- RestoreBar: 还原单条 bar 被覆盖前的原始样式
-- ------------------------------------------------------------
-- 供 OnDisable 调用：读取 bar.data[SAVED_KEY] 快照逐项还原；
-- 法术名计数后缀不在此还原（bar 回收后 label 随复用自然重置）。
-- 调用方已 pcall 包裹；快照缺失时静默跳过。
RestoreBar = function(bar)
    local data = bar.data
    local saved = data and data[SAVED_KEY]
    if not saved then return end

    if bar.candyBarLabel then
        if saved.labelFont and saved.labelFont[1] then
            bar.candyBarLabel:SetFont(saved.labelFont[1], saved.labelFont[2], saved.labelFont[3])
        end
        RestorePoints(bar.candyBarLabel, saved.labelPoints)
    end
    if bar.candyBarDuration then
        if saved.timeFont and saved.timeFont[1] then
            bar.candyBarDuration:SetFont(saved.timeFont[1], saved.timeFont[2], saved.timeFont[3])
        end
        RestorePoints(bar.candyBarDuration, saved.timePoints)
    end
    if saved.iconWidth and bar.candyBarIconFrame then
        bar.candyBarIconFrame:SetWidth(saved.iconWidth)
    end
    if saved.indicatorFrame then
        if saved.indicatorSize and saved.indicatorSize[1] then
            -- 与覆盖侧对称：优先原生 SetIndicatorSize 统一还原框体+纹理
            if saved.indicatorFrame.SetIndicatorSize then
                saved.indicatorFrame:SetIndicatorSize(saved.indicatorSize[1])
            else
                saved.indicatorFrame:SetSize(saved.indicatorSize[1], saved.indicatorSize[2])
            end
        end
        RestorePoints(saved.indicatorFrame, saved.indicatorPoints)
    end
    data[SAVED_KEY] = nil
end

-- ============================================================
-- 预览（preview-buttons）
-- ============================================================
-- 零售版 BigWigs 的测试条走 C_EncounterTimeline 内部局部函数，
-- 外部无法调用；故预览采用自建 LibCandyBar 条：结构与真实醒目条
-- 完全一致，直接复用 ApplyEmphStyle / AttachIntegerTimer /
-- HideCastCountSuffix，所见即所得。
-- 已核实：Bars 插件仅注册 LibCandyBar_Stop 回调（仅重排自身锚点），
-- 自建条不进入 BigWigs 锚点系统，Stop 时对 BigWigs 零影响。
local PREVIEW_WIDTH, PREVIEW_HEIGHT = 260, 20
local PREVIEW_DURATION = 30          -- 预览条计时秒数（到期自动循环重启）
local previewTicker                  -- 循环重启计时器
local previewIndicator               -- 模拟特殊图标框体（懒创建一次，反复复用）

-- GetPreviewTexture: 预览条材质（BigWigs 默认 BantoBar，取不到用通用材质）
local function GetPreviewTexture()
    if LibStub then
        local lsm = LibStub("LibSharedMedia-3.0", true)
        if lsm then
            local path = lsm:Fetch("statusbar", "BantoBar", true)
            if path then return path end
        end
    end
    return "Interface\\TargetingFrame\\UI-StatusBar"
end

-- StartPreview: 创建屏幕中央的模拟醒目预览条
-- ------------------------------------------------------------
-- 预览要素：法术名（带 "(2)" 计数后缀，演示隐藏效果）、图标、
-- 30 秒倒计时（末段演示整数化）、骷髅标记模拟特殊图标。
-- 重复点击「预览」会先回收旧条再重建（重置计时并刷新样式）。
StartPreview = function()
    local candy = GetCandy()
    if not candy then
        Util:Print(L["BWE_NoBigWigs"])
        return
    end
    StopPreview()

    local bar = candy:New(GetPreviewTexture(), PREVIEW_WIDTH, PREVIEW_HEIGHT)
    previewBar = bar
    bar:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
    bar:SetLabel(L["BWE_PreviewLabel"])
    bar:SetIcon(136235)   -- 通用法术图标（仅示意）
    bar:SetDuration(PREVIEW_DURATION)

    -- 醒目条标记 + 模拟特殊图标（纹理 SetAllPoints 锚定充满框体，
    -- ApplyEmphStyle 回退路径 SetSize 时自动跟随缩放；框体挂 UIParent
    -- 而非 bar，避免 bar 被回收复用给真实条时残留子框体污染）
    bar:Set("bigwigs:emphasized", true)
    if not previewIndicator then
        previewIndicator = CreateFrame("Frame", nil, UIParent)
        previewIndicator:SetSize(PREVIEW_HEIGHT, PREVIEW_HEIGHT)
        local tex = previewIndicator:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints(previewIndicator)
        tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
    end
    previewIndicator:ClearAllPoints()
    previewIndicator:SetPoint("BOTTOMLEFT", bar, "BOTTOMRIGHT", 4, 0)
    previewIndicator:Show()
    bar:Set("bigwigs:indicatorFrame", previewIndicator)

    -- 应用本模块三大效果：计数隐藏 / 整数倒计时 / 醒目条样式覆盖
    if GetOption("hideCastCount") then
        pcall(HideCastCountSuffix, bar)
    end
    if GetOption("integerTimer") then
        pcall(AttachIntegerTimer, bar)
    end
    pcall(ApplyEmphStyle, bar)

    bar:Start(PREVIEW_DURATION)
    -- 计时结束后循环重启预览（ticker 触发时旧条先经 StopPreview
    -- 正常回收，新条从 LibCandyBar 对象池重建，状态干净）
    previewTicker = C_Timer.NewTicker(PREVIEW_DURATION, function()
        if module.enabled then
            StartPreview()
        end
    end)
end

-- StopPreview: 停止并回收预览条
-- ------------------------------------------------------------
-- LibCandyBar 的 Stop 没有运行状态判断（重复调用会重复触发
-- LibCandyBar_Stop 回调），调用前先确认 bar.running。
StopPreview = function()
    if previewTicker then
        previewTicker:Cancel()
        previewTicker = nil
    end
    if previewIndicator then
        previewIndicator:Hide()
        previewIndicator:ClearAllPoints()
    end
    if previewBar then
        if previewBar.running then
            previewBar:Stop()
        end
        previewBar = nil
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
    Util:Debug("BigWigsEnhance: 已挂载 BigWigs 计时条扩展")
end

-- ============================================================
-- OnDisable: 模块禁用
-- ============================================================
function module:OnDisable()
    StopPreview()
    UnhookBigWigs()
    -- 还原所有仍活跃的醒目条样式（快照在 bar.data 中，
    -- 已回收的条 data 为 nil，RestoreBar 内部静默跳过），随后清空集合
    for bar in pairs(activeBars) do
        pcall(RestoreBar, bar)
    end
    wipe(activeBars)
    Util:Debug("BigWigsEnhance: 已禁用")
end

-- ============================================================
-- OnOptionChanged: 设置项变更（Config.lua 自动调用）
-- ============================================================
-- Config 侧在值写入 dbEntry 之后才触发本回调，GetOption 读到的即新值。
-- 即时生效：对所有活跃强调条重应用样式覆盖（幂等，见 ApplyEmphStyle）。
-- 两个特例：
--   integerTimer  仅对变更后新建的条生效（update 回调随条创建挂载、
--                 随条回收清空），当前运行中的条维持原样；
--   hideCastCount 开启时对活跃条即时生效（RefreshActiveEmphBars 内补调）；
--                 关闭后无法即时还原（原计数已随 gsub 丢弃），
--                 下一条醒目条自然恢复。
-- 预览条：滑条类变更直接重应用样式；开关类效果对已建条无法摘除/还原
-- （update 回调无移除 API、计数已丢弃），重建预览条即时演示开关效果。
function module:OnOptionChanged(key, value)
    if not module.enabled then return end
    RefreshActiveEmphBars()
    -- 预览条正在展示时同步刷新（预览条不属于 BigWigs 锚点，不在活跃集合中）
    if previewBar and previewBar.data then
        if key == "integerTimer" or key == "hideCastCount" then
            StartPreview()
        else
            pcall(ApplyEmphStyle, previewBar)
        end
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
