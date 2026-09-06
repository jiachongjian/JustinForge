-- ============================================================
-- JustinForge 模块: 拾取窗口向下堆叠 (LootStackDirection.lua)
-- ============================================================
-- 功能描述：
--   将两个原生 UI 的「多实例垂直堆叠方向」由向上增长改为向下增长：
--     1. 团队装备 Roll 窗口（GroupLootContainer / GroupLootFrame，
--        即 Need / Greed / Transmog / Disenchant 掷骰窗口）
--     2. 拾取 Loot Toast（物品/货币走 LootAlertSystem、金钱走
--        MoneyWonAlertSystem、装备升级走 LootUpgradeAlertSystem，
--        即「你获得了 XXX」类提示）
--   第一个窗口/Toast 保持原本基准位置不变，后续实例依次向屏幕下方增长。
--   除此之外不修改任何其他行为（尺寸/内部布局/按钮/字体/动画/显隐/
--   倒计时/Roll 功能/水平位置等一律保持原样）。
--
-- 实现机制（已对照至暗之夜客户端 wow-ui-source live 源码核实）：
--
--   【Roll 窗口】原生 GroupLootContainer_Update(self)：
--       第 i 个框 SetPoint("CENTER", self, "BOTTOM", 0, reservedSize*(i-0.5))
--       向上堆叠（reservedSize=100）。本模块用 hooksecurefunc 后置重锚，
--       y 偏移改为 reservedSize*(1.5-i)：i=1 保持原位(+50)，i=2/3/4
--       依次为 -50/-150/-250，相邻间距仍为 100，互不覆盖。
--       不改 SetHeight 与 layoutParent:Layout()，容器高度与布局占位
--       和原生完全一致（容器本身不可见，其他底部管理 UI 位置不变）。
--       GroupLootContainer_AddFrame/RemoveFrame 都会触发 Update，
--       因此新框出现/旧框消失/中间消失重排/全部消失再出现均被覆盖。
--
--   【Loot Toast】AlertFrame（锚定 UIParent BOTTOM, y=128）下所有
--       toast 子系统共享一条锚定链：AlertContainerMixin:UpdateAnchors
--       按 anchorPriority 逐个调用 subSystem:AdjustAnchors(relativeFrame)
--       链式锚定，以上一子系统返回值作为下一子系统的锚点；
--       AlertFrameQueueMixin:AdjustAnchors 内部为
--       SetPoint("BOTTOM", prev, "TOP", 0, 10)，向上增长。
--       开宝箱时物品/货币（LootAlertSystem）、金钱（MoneyWonAlertSystem）、
--       装备升级（LootUpgradeAlertSystem）三个子系统会同时出框——
--       只改其中一个，其余子系统仍按原生向上链接，会跳到整摞最上方
--       （实测：金钱 toast 永远压在最顶，看起来像向上增长）。
--       本模块对三个子系统统一做实例级 AdjustAnchors 替换（实例表
--       覆盖赋值，不动共享 mixin，成就/荣誉/配方等子系统零影响）：
--         - 链首（relativeAlert 为容器基准框）时第一框保持原生锚点
--           （BOTTOM 锚 relativeAlert.TOP +10，基准位置不变）
--         - 否则第一框接在上一子系统最下面一框之下（子系统间也向下）
--         - 后续框 SetPoint("TOP", prev, "BOTTOM", 0, -10) 向下堆叠
--         - 返回最下面的框作为链出口，下一子系统继续向下链接
--       UpdateAnchors 在新 toast 出现与 toast 隐藏回收时均会触发，
--       覆盖增删/重排所有场景。
--
--   【冲突兼容】只改子框体之间的相对锚点，不改 GroupLootContainer /
--       AlertFrame 容器自身锚点，与「只移动窗口位置」的其他 UI 插件
--       天然兼容；hooksecurefunc 后置重锚也不替换原函数，可与其他
--       插件的 hook 链式共存。
--
--   注意：hooksecurefunc 与实例方法替换均无法卸载，回调内部首行
--   检查 module.enabled，禁用后走原生逻辑，等效于零开销禁用。
-- ============================================================

local addonName, ns = ...

local L = ns.L

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "lootStackDirection",
    name           = L["LootStackDirection_Name"],
    description    = L["LootStackDirection_Desc"],
    defaultEnabled = true,
})

-- ============================================================
-- 运行时状态
-- ============================================================
local rollHooked = false       -- GroupLootContainer_Update 后置 hook 是否已安装
local toastReplaced = false    -- Toast 子系统 AdjustAnchors 是否已替换
local origAdjustAnchors = {}   -- [子系统] = 原 AdjustAnchors（mixin 方法）

-- 需要向下堆叠的拾取相关 Toast 子系统（AlertFrameSystems.lua 登录时创建）
local TOAST_SYSTEMS = { "LootAlertSystem", "MoneyWonAlertSystem", "LootUpgradeAlertSystem" }

-- ============================================================
-- RestackRollFrames: GroupLootContainer_Update 后置回调
-- ============================================================
-- 原生 Update 已按向上方向设好锚点，此处覆盖为向下：
-- 第一个框（i=1）y=+0.5*reservedSize 与原生完全一致（基准位置不变），
-- 后续框依次向下一个 reservedSize，间距不变、互不覆盖
local function RestackRollFrames(container)
    -- hooksecurefunc 无法卸载：禁用后回调直接返回，实现逻辑上的禁用
    if not module.enabled then return end

    local reservedSize = container.reservedSize
    local maxIndex = container.maxIndex
    local rollFrames = container.rollFrames
    -- 判空保护：暴雪若改动容器结构则静默跳过，不影响原生堆叠
    if not reservedSize or not maxIndex or not rollFrames then return end

    for i = 1, maxIndex do
        local frame = rollFrames[i]
        if frame then
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", container, "BOTTOM", 0, reservedSize * (1.5 - i))
        end
    end
end

-- ============================================================
-- AdjustAnchorsDown: 拾取相关 Toast 子系统的 AdjustAnchors 替换实现
-- ============================================================
-- 签名与 AlertFrameQueueMixin:AdjustAnchors 一致，由
-- AlertContainerMixin:UpdateAnchors 在锚定链中调用。
-- 子系统内部向下堆叠，子系统之间同样向下链接：
-- 链首（relativeAlert 为容器基准框）时第一框保持原生基准位置，
-- 否则接在上一子系统最下面一框之下；返回最下面的框作为链出口
local function AdjustAnchorsDown(self, relativeAlert)
    -- 禁用时走原生逻辑（origAdjustAnchors[self] 为保存的原方法）
    if not module.enabled then
        return origAdjustAnchors[self](self, relativeAlert)
    end

    local pool = self.alertFramePool
    if not pool then
        return origAdjustAnchors[self](self, relativeAlert)
    end

    -- 判断链首：relativeAlert 是否就是容器基准框（AlertFrame.baseAnchorFrame）
    local container = self.GetAlertContainer and self:GetAlertContainer()
    local baseFrame = container and (container.baseAnchorFrame or container)

    local prevFrame
    for alertFrame in pool:EnumerateActive() do
        alertFrame:ClearAllPoints()
        if not prevFrame then
            if baseFrame and relativeAlert == baseFrame then
                -- 整摞第一框：保持原生锚点（基准位置不变）
                alertFrame:SetPoint("BOTTOM", relativeAlert, "TOP", 0, 10)
            else
                -- 接在上一子系统最下面一框之下，子系统之间也向下
                alertFrame:SetPoint("TOP", relativeAlert, "BOTTOM", 0, -10)
            end
        else
            -- 后续框：锚到前一个框下方，向下增长
            alertFrame:SetPoint("TOP", prevFrame, "BOTTOM", 0, -10)
        end
        prevFrame = alertFrame
    end

    -- 无活跃框时透传 relativeAlert（与原生空池行为一致）；
    -- 有活跃框时返回最下面的框，下一子系统继续向下链接
    return prevFrame or relativeAlert
end

-- ============================================================
-- InstallRollHook: 安装 GroupLootContainer_Update 后置 hook
-- ============================================================
-- GroupLootFrame 位于 Blizzard_UIPanels_Game（随客户端加载），
-- 登录时函数已存在；仍判空保护防止暴雪未来改动
local function InstallRollHook()
    if rollHooked then return end
    if type(_G.GroupLootContainer_Update) ~= "function" then return end

    -- 后置 hook：先让暴雪完成自己的锚定/高度/布局，再覆盖子框锚点，
    -- 保证我们的方向是最终生效值，且不破坏 SetHeight/Layout 逻辑
    hooksecurefunc("GroupLootContainer_Update", RestackRollFrames)
    rollHooked = true
end

-- ============================================================
-- InstallToastReplace: 替换拾取相关 Toast 子系统的 AdjustAnchors
-- ============================================================
-- AlertFrame 系统位于 Blizzard_FrameXML（随客户端加载），登录时
-- 各子系统已创建；实例表覆盖赋值，不影响共享 mixin 及
-- 其他 toast 子系统（成就/荣誉/配方等）
local function InstallToastReplace()
    if toastReplaced then return end
    for _, name in ipairs(TOAST_SYSTEMS) do
        local sys = _G[name]
        if sys and type(sys.AdjustAnchors) == "function" then
            origAdjustAnchors[sys] = sys.AdjustAnchors
            sys.AdjustAnchors = AdjustAnchorsDown
        end
    end
    toastReplaced = true
end

-- ============================================================
-- RefreshAll: 触发一次原生重排（立即应用或立即恢复）
-- ============================================================
-- 启用时：hook/替换已生效，重排后呈现向下堆叠；
-- 禁用时：Module:Disable 先置 enabled=false 再调 OnDisable，
--         重排走原生逻辑，立即恢复向上堆叠
local function RefreshAll()
    if type(_G.GroupLootContainer_Update) == "function" and _G.GroupLootContainer then
        pcall(_G.GroupLootContainer_Update, _G.GroupLootContainer)
    end
    local alertFrame = _G.AlertFrame
    if alertFrame and type(alertFrame.UpdateAnchors) == "function" then
        pcall(alertFrame.UpdateAnchors, alertFrame)
    end
end

-- ============================================================
-- OnEnable: 模块启用
-- ============================================================
function module:OnEnable()
    InstallRollHook()
    InstallToastReplace()
    -- 若当前正有 Roll 窗口/Toast 显示，立即应用向下堆叠
    RefreshAll()
end

-- ============================================================
-- OnDisable: 模块禁用
-- ============================================================
-- hook 与替换无法卸载，但回调内检查 module.enabled 后走原生逻辑；
-- 主动触发一次重排，立即恢复原生堆叠方向
function module:OnDisable()
    RefreshAll()
end
