-- ============================================================
-- JustinForge 模块: 成就界面默认未完成 (AchievementIncomplete.lua)
-- ============================================================
-- 功能描述：
--   每次打开成就界面时，自动把顶部的筛选器重置为「未完成」。
--
-- 实现机制（已对照至暗之夜客户端 Blizzard_AchievementUI 源码核实）：
--   暴雪的筛选状态采用「函数指针」模式，全局变量
--   ACHIEVEMENTUI_SELECTEDFILTER 保存三个筛选函数之一的引用：
--     AchievementFrame_GetCategoryNumAchievements_All        全部（默认值）
--     AchievementFrame_GetCategoryNumAchievements_Complete   已完成
--     AchievementFrame_GetCategoryNumAchievements_Incomplete 未完成
--   数据提供者刷新列表时调用 ACHIEVEMENTUI_SELECTEDFILTER(category)
--   取得 (数量, 完成数, 偏移)；下拉框选中回调也只是改写该变量并
--   调用 AchievementFrameAchievements_ForceUpdate()。
--
--   因此本模块 hook 成就主框体的 OnShow 脚本，在窗口显示后：
--     1. 将 ACHIEVEMENTUI_SELECTEDFILTER 指向 Incomplete 函数
--     2. 若成就标签页正在显示，调用 ForceUpdate 立即刷新列表
--   与玩家手动在筛选下拉框选择「未完成」的效果完全一致，
--   且玩家打开窗口后仍可随时手动切换其他筛选（仅每次打开时重置一次）。
--
--   注意1：AchievementFrame 的 OnShow 在 XML 中以
--   <OnShow function="AchievementFrame_OnShow"/> 方式绑定，
--   hooksecurefunc 全局函数对该绑定方式不保证生效（实测未触发），
--   因此改用 AchievementFrame:HookScript("OnShow", ...)，
--   无论原始脚本如何绑定都必定在原处理程序之后触发。
--
--   注意2：HookScript 注册的 hook 无法单独卸载，因此回调内部
--   先检查模块启用状态，禁用后直接返回，等效于零开销禁用。
-- ============================================================

local addonName, ns = ...

local L = ns.L

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "achievementIncomplete",
    name           = L["AchievementIncomplete_Name"],
    description    = L["AchievementIncomplete_Desc"],
    defaultEnabled = true,
})

-- ============================================================
-- 运行时状态
-- ============================================================
local eventFrame  -- 监听 Blizzard_AchievementUI 懒加载事件的 Frame
local hooked = false -- 是否已安装 OnShow hook

-- ============================================================
-- ApplyIncompleteFilter: 将筛选器设为「未完成」（OnShow hook 回调）
-- ============================================================
-- 与暴雪 AchievementFrame_SetFilter(ACHIEVEMENT_FILTER_INCOMPLETE) 等效，
-- 但直接操作底层变量，避免依赖下拉框菜单函数（其内部还会 GenerateMenu，
-- 在此处调用意义不大且可能因布局未就绪产生副作用）。
local function ApplyIncompleteFilter()
    -- HookScript 无法卸载：禁用后回调直接返回，实现逻辑上的禁用
    if not module.enabled then return end

    -- 目标筛选函数（暴雪源码常量 AchievementFrameFilters[3].func）
    local incompleteFunc = _G.AchievementFrame_GetCategoryNumAchievements_Incomplete
    if type(incompleteFunc) ~= "function" then
        return
    end

    -- 已是「未完成」则跳过，避免无谓刷新
    if _G.ACHIEVEMENTUI_SELECTEDFILTER == incompleteFunc then
        return
    end

    _G.ACHIEVEMENTUI_SELECTEDFILTER = incompleteFunc

    -- 成就标签页正在显示时立即刷新数据，使其应用新筛选；
    -- 否则无需处理（标签页切换时暴雪会自行读取新的筛选状态）
    local achievements = _G.AchievementFrameAchievements
    if achievements and achievements:IsShown()
        and type(_G.AchievementFrameAchievements_ForceUpdate) == "function" then
        _G.AchievementFrameAchievements_ForceUpdate()
    end
end

-- ============================================================
-- InstallHook: 安装 OnShow hook（Blizzard_AchievementUI 加载后调用）
-- ============================================================
local function InstallHook()
    if hooked then return end
    local frame = _G.AchievementFrame
    if not frame then return end

    -- HookScript 为后置 hook：先让暴雪完成自己的 OnShow
    -- （点数刷新、限制模式、默认分类选择等），再重置筛选器，
    -- 保证我们的设置是最终生效值
    frame:HookScript("OnShow", ApplyIncompleteFilter)
    hooked = true
end

-- ============================================================
-- OnEnable: 模块启用
-- ============================================================
-- Blizzard_AchievementUI 是懒加载插件，首次打开成就界面时才加载，
-- 因此必须同时：
--   1. 立即尝试安装 hook（可能已加载）
--   2. 监听 ADDON_LOADED，在它后续加载完成时补装
function module:OnEnable()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", function(_, _, loadedAddon)
            if loadedAddon == "Blizzard_AchievementUI" then
                InstallHook()
            end
        end)
    end
    eventFrame:RegisterEvent("ADDON_LOADED")

    -- 已加载的情形直接安装 hook
    -- 注意：不存在 Blizzard_AchievementUI 全局变量，必须用 IsAddOnLoaded 判断
    if C_AddOns.IsAddOnLoaded("Blizzard_AchievementUI") then
        InstallHook()
    end
end

-- ============================================================
-- OnDisable: 模块禁用
-- ============================================================
-- 停止监听。hook 回调内部检查 module.enabled，禁用后不再生效
function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
end
