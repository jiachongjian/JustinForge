-- ============================================================
-- JustinForge 模块: 筛选个人隐藏成就 (AchievementHiddenFilter.lua)
-- ============================================================
-- 功能描述：
--   在成就界面「成就」（个人）标签页的筛选下拉菜单（全部/已完成/未完成）
--   中追加勾选项「隐藏成就」（默认不勾选），仅用于控制未完成的
--   隐藏成就是否显示：
--     不勾选（默认）：从列表中隐藏未完成的隐藏成就；
--     勾选：显示它们，且以略不同的样式呈现（透明度降低+名称变色）。
--   已完成的成就（含已完成的隐藏成就）不受任何影响。
--
-- 实现机制（已对照至暗之夜客户端 Blizzard_AchievementUI 源码核实）：
--   1. 隐藏成就判定：GetAchievementInfo(id) 第 9 个返回值 flags，
--      位 0x00000002 为隐藏标记；完成状态取第 4 个返回值 completed
--      与第 13 个返回值 wasEarnedByMe（与暴雪按钮显示口径一致）。
--   2. 列表过滤：成就列表统一由全局函数
--      AchievementFrameAchievements_UpdateDataProvider() 重建数据
--      （elementData = {category, index, id}）。hooksecurefunc 后置拦截，
--      把 ScrollBox 的 DataProvider 换成剔除「未完成隐藏成就」的副本。
--      SetDataProvider 不会回触发 UpdateDataProvider，无递归。
--   3. 样式区分：hooksecurefunc 全局表 AchievementTemplateMixin 的
--      Init 方法，按钮初始化后对未完成隐藏成就施加样式；非目标按钮
--      显式恢复透明度（名称颜色由暴雪 Init 内的 Saturate/Desaturate
--      每次重置，无需手动恢复）。
--   4. 菜单注入：筛选下拉框带 rootDescription:SetTag("MENU_ACHIEVEMENT_FILTER")
--      标签，Menu.ModifyMenu 在菜单末尾追加勾选项，样式与原生一致。
--   5. 个人视图判定：AchievementFrame.selectedTab == 1（成就标签页）。
--      公会(2)/统计(3)/对比(nil) 下本模块完全不影响。
--
--   注意：Menu.ModifyMenu / hooksecurefunc 均无法卸载，
--   回调内部先检查 module.enabled，禁用后立即返回并刷新列表还原。
-- ============================================================

local addonName, ns = ...

local L = ns.L

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "achievementHiddenFilter",
    name           = L["AchievementHiddenFilter_Name"],
    description    = L["AchievementHiddenFilter_Desc"],
    defaultEnabled = true,
})

-- ============================================================
-- 常量表
-- ============================================================
local HIDDEN_FLAG = 0x00000002  -- GetAchievementInfo flags 中的隐藏成就位

-- 未完成隐藏成就的样式（与正常成就稍微区别）
local HIDDEN_ALPHA = 0.85                 -- 整钮透明度略降
local HIDDEN_LABEL_R, HIDDEN_LABEL_G, HIDDEN_LABEL_B = 0.62, 0.55, 0.95  -- 名称淡紫

-- ============================================================
-- 运行时状态
-- ============================================================
local eventFrame
local hooked = false
local showHidden = false     -- 筛选项状态：false = 隐藏未完成的隐藏成就（默认）
local hiddenFlagCache = {}   -- 成就ID → 是否隐藏（静态数据，可安全缓存）

-- ============================================================
-- IsPersonalView: 是否处于个人成就标签页
-- ============================================================
local function IsPersonalView()
    local frame = _G.AchievementFrame
    return frame and frame.selectedTab == 1
end

-- ============================================================
-- IsHidden: 成就是否带隐藏标记（静态数据，结果缓存）
-- ============================================================
local function IsHidden(id)
    local cached = hiddenFlagCache[id]
    if cached ~= nil then
        return cached
    end
    local flags = select(9, GetAchievementInfo(id))
    cached = (flags ~= nil) and (bit.band(flags, HIDDEN_FLAG) ~= 0)
    hiddenFlagCache[id] = cached
    return cached
end

-- ============================================================
-- IsHiddenIncomplete: 是否为「未完成的隐藏成就」
-- 完成状态实时读取（不缓存），保证获得成就的当次会话即视为已完成
-- ============================================================
local function IsHiddenIncomplete(id)
    if not IsHidden(id) then
        return false
    end
    local _, _, _, completed, _, _, _, _, _, _, _, _, wasEarnedByMe = GetAchievementInfo(id)
    return not completed and not wasEarnedByMe
end

-- ============================================================
-- ApplyHiddenFilter: 后置过滤成就列表 DataProvider
-- 原生列表构建完毕后，剔除未完成的隐藏成就（默认筛除状态）
-- ============================================================
local function ApplyHiddenFilter()
    if not module.enabled or showHidden then return end
    if not IsPersonalView() then return end

    local achievements = _G.AchievementFrameAchievements
    local scrollBox = achievements and achievements.ScrollBox
    local dataProvider = scrollBox and scrollBox:GetDataProvider()
    if not dataProvider then return end

    local filtered = CreateDataProvider()
    local changed = false
    for _, elementData in dataProvider:Enumerate() do
        local id = elementData.id
        if id and IsHiddenIncomplete(id) then
            changed = true
        else
            filtered:Insert(elementData)
        end
    end
    if changed then
        scrollBox:SetDataProvider(filtered)
    end
end

-- ============================================================
-- StyleButton: 成就按钮样式后置处理（AchievementTemplateMixin:Init 的 hook）
-- 对未完成的隐藏成就施加区别样式；其余按钮显式恢复透明度
-- ============================================================
local function StyleButton(self, elementData)
    if module.enabled
        and IsPersonalView()
        and elementData
        and elementData.id
        and IsHiddenIncomplete(elementData.id) then
        self:SetAlpha(HIDDEN_ALPHA)
        if self.Label then
            self.Label:SetVertexColor(HIDDEN_LABEL_R, HIDDEN_LABEL_G, HIDDEN_LABEL_B)
        end
    else
        -- SetAlpha 不在暴雪 Init 重置范围内，复用按钮前需显式还原
        self:SetAlpha(1)
    end
end

-- ============================================================
-- RefreshList: 成就标签页显示时强制刷新数据
-- ============================================================
local function RefreshList()
    local achievements = _G.AchievementFrameAchievements
    if achievements and achievements:IsShown()
        and type(_G.AchievementFrameAchievements_ForceUpdate) == "function" then
        _G.AchievementFrameAchievements_ForceUpdate()
    end
end

-- ============================================================
-- InjectMenu: 向筛选下拉菜单追加「隐藏成就」勾选项
-- ============================================================
local function InjectMenu(_, rootDescription)
    if not module.enabled then return end
    if not IsPersonalView() then return end

    rootDescription:CreateCheckbox(
        L["AHF_Hidden"] or "隐藏成就",
        function() return showHidden end,
        function()
            showHidden = not showHidden
            RefreshList()
        end)
end

-- ============================================================
-- InstallHook: Blizzard_AchievementUI 加载后安装 hook 与菜单注入
-- ============================================================
local function InstallHook()
    if hooked then return end
    if type(_G.AchievementFrameAchievements_UpdateDataProvider) ~= "function" then return end
    if not _G.AchievementFrame then return end

    hooksecurefunc("AchievementFrameAchievements_UpdateDataProvider", ApplyHiddenFilter)
    local mixin = _G.AchievementTemplateMixin
    if type(mixin) == "table" and type(mixin.Init) == "function" then
        hooksecurefunc(mixin, "Init", StyleButton)
    end
    Menu.ModifyMenu("MENU_ACHIEVEMENT_FILTER", InjectMenu)
    hooked = true
end

-- ============================================================
-- OnEnable: 模块启用（Blizzard_AchievementUI 懒加载，两种时序都处理）
-- ============================================================
function module:OnEnable()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", function(_, event, arg1)
            if event == "ADDON_LOADED" and arg1 == "Blizzard_AchievementUI" then
                InstallHook()
            end
        end)
    end
    eventFrame:RegisterEvent("ADDON_LOADED")

    if C_AddOns.IsAddOnLoaded("Blizzard_AchievementUI") then
        InstallHook()
    end
end

-- ============================================================
-- OnDisable: 模块禁用（复位筛选项并刷新还原；hook 回调查 enabled 失效）
-- ============================================================
function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
    showHidden = false
    RefreshList()
end
