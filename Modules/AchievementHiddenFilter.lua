-- =========================================================
-- 模块：筛选个人隐藏成就（AchievementHiddenFilter）
-- 功能：在成就界面「成就」（个人）标签页的筛选下拉菜单中追加「隐藏成就」勾选项：
--   - 未勾选（默认）：保持原生行为，列表不显示未完成的隐藏成就
--   - 勾选：三个筛选函数（全部/已获得/未完成）改用 GetCategoryNumAchievements(categoryID, true)
--           枚举（includeAll），未完成的隐藏成就随列表自然显示，
--           并以区别样式标记（稍淡透明度 + 淡紫色名称）
--   - 已完成的成就不受任何影响
-- 注意：仅个人成就标签页生效（公会/统计/对比视图不受影响）。
-- 机制说明（对照 12.x 客户端源码）：
--   - 原生 AchievementFrame_GetCategoryNumAchievements_All/Complete/Incomplete 调用
--     GetCategoryNumAchievements(categoryID) 时「不传」includeAll，默认枚举不含未完成隐藏成就；
--   - AchievementFrameAchievements_UpdateDataProvider 依据 ACHIEVEMENTUI_SELECTEDFILTER(category)
--     的返回值循环 GetAchievementInfo(category, index) 填充列表，索引枚举口径与最近一次
--     GetCategoryNumAchievements 的 includeAll 一致（WeakAuras 同款枚举模式）——
--     因此「替换」三个筛选全局函数使其在勾选时传 includeAll=true，即可让原生循环自动列出隐藏成就；
--   - 必须替换全局函数本体而非仅 AchievementFrameFilters 表内引用：暴雪默认赋值、
--     本插件 AchievementIncomplete 模块（OnShow 重置筛选）均按名字从 _G 引用这些函数；
--   - 隐藏成就的判定：GetAchievementInfo(id) 第 9 个返回值 flags 的 0x800 位（HIDE_INCOMPLETE）。
-- =========================================================

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

-- 常量定义
local HIDDEN_FLAG = 0x00000800 -- GetAchievementInfo flags：HIDE_INCOMPLETE（隐藏成就，完成前不可见）
local HIDDEN_ALPHA = 0.85             -- 隐藏成就按钮整体透明度
local HIDDEN_LABEL_R, HIDDEN_LABEL_G, HIDDEN_LABEL_B = 0.75, 0.6, 1 -- 隐藏成就名称颜色（淡紫）

-- 模块状态
local showHidden = false -- 「隐藏成就」勾选项是否选中（默认不勾选=隐藏），会话内有效
local hooked = false
local originalFilterFuncs = nil -- 替换前保存的三个原生筛选全局函数（all/complete/incomplete）

-- 判断当前是否处于个人成就标签页
local function IsPersonalView()
    return AchievementFrame and AchievementFrame.selectedTab == 1
end

-- 判断指定成就是否为「未完成的隐藏成就」
local hiddenFlagCache = {}
local function IsHiddenIncomplete(id)
    if not id then return false end
    local hidden = hiddenFlagCache[id]
    if hidden == nil then
        local flags = select(9, GetAchievementInfo(id))
        hidden = flags and bit.band(flags, HIDDEN_FLAG) == HIDDEN_FLAG or false
        hiddenFlagCache[id] = hidden
    end
    if not hidden then return false end
    local completed, wasEarnedByMe = select(4, GetAchievementInfo(id)), select(13, GetAchievementInfo(id))
    return not completed and not wasEarnedByMe
end

-- 刷新成就列表
local function RefreshList()
    if AchievementFrameAchievements and AchievementFrameAchievements:IsShown() and AchievementFrameAchievements_UpdateDataProvider then
        AchievementFrameAchievements_UpdateDataProvider()
    end
end

-- =========================================================
-- 列表注入：替换三个原生筛选「全局函数」本体，勾选时改用 includeAll 枚举
-- （返回值映射完全复刻暴雪原生实现，仅枚举范围变为含隐藏成就）
-- =========================================================
local function WrapFilterFunctions()
    if originalFilterFuncs then return end
    local allFunc = _G.AchievementFrame_GetCategoryNumAchievements_All
    local completeFunc = _G.AchievementFrame_GetCategoryNumAchievements_Complete
    local incompleteFunc = _G.AchievementFrame_GetCategoryNumAchievements_Incomplete
    if type(allFunc) ~= "function" or type(completeFunc) ~= "function" or type(incompleteFunc) ~= "function" then
        return
    end
    originalFilterFuncs = { all = allFunc, complete = completeFunc, incomplete = incompleteFunc }

    local function ShouldIncludeAll()
        return module.enabled and showHidden and IsPersonalView()
    end

    _G.AchievementFrame_GetCategoryNumAchievements_All = function(categoryID)
        if ShouldIncludeAll() then
            local numAchievements, numCompleted = GetCategoryNumAchievements(categoryID, true)
            return numAchievements, numCompleted, 0
        end
        return allFunc(categoryID)
    end
    _G.AchievementFrame_GetCategoryNumAchievements_Complete = function(categoryID)
        if ShouldIncludeAll() then
            local _, numCompleted = GetCategoryNumAchievements(categoryID, true)
            return numCompleted, numCompleted, 0
        end
        return completeFunc(categoryID)
    end
    _G.AchievementFrame_GetCategoryNumAchievements_Incomplete = function(categoryID)
        if ShouldIncludeAll() then
            local numAchievements, _, numIncomplete = GetCategoryNumAchievements(categoryID, true)
            return numIncomplete, 0, numAchievements - numIncomplete
        end
        return incompleteFunc(categoryID)
    end

    -- 暴雪文件加载时已将原函数引用写入 AchievementFrameFilters 表和
    -- ACHIEVEMENTUI_SELECTEDFILTER，统一重指到新函数，保持 == 身份比较一致
    local remap = {
        [allFunc] = _G.AchievementFrame_GetCategoryNumAchievements_All,
        [completeFunc] = _G.AchievementFrame_GetCategoryNumAchievements_Complete,
        [incompleteFunc] = _G.AchievementFrame_GetCategoryNumAchievements_Incomplete,
    }
    if AchievementFrameFilters then
        for _, filter in ipairs(AchievementFrameFilters) do
            if remap[filter.func] then
                filter.func = remap[filter.func]
            end
        end
    end
    if remap[_G.ACHIEVEMENTUI_SELECTEDFILTER] then
        _G.ACHIEVEMENTUI_SELECTEDFILTER = remap[_G.ACHIEVEMENTUI_SELECTEDFILTER]
    end
end

-- =========================================================
-- 样式区分：未完成的隐藏成就以区别样式显示
-- =========================================================
local reInitializing = false -- 枚举口径自检重试标志（防递归）
local function StyleButton(self)
    if not module.enabled then return end
    if not IsPersonalView() then return end
    local elementData = self.GetElementData and self:GetElementData()
    local id = elementData and elementData.id or self.id
    -- 枚举口径自检：Init 通过 GetAchievementInfo(category, index) 取数；
    -- 若 index 枚举口径在 Init 前被其他代码重置为默认（不含隐藏成就），
    -- self.id 会与 elementData.id 不一致，此时以 includeAll 口径重置后重试一次
    if showHidden and not reInitializing
        and elementData and elementData.category and elementData.index
        and elementData.id and self.id ~= elementData.id then
        reInitializing = true
        GetCategoryNumAchievements(elementData.category, true)
        self:Init(elementData)
        reInitializing = false
        return
    end
    if IsHiddenIncomplete(id) then
        self:SetAlpha(HIDDEN_ALPHA)
        if self.Label then
            self.Label:SetVertexColor(HIDDEN_LABEL_R, HIDDEN_LABEL_G, HIDDEN_LABEL_B)
        end
    else
        -- 按钮被复用为普通成就时显式还原透明度（名称颜色由暴雪 Init 的 Saturate/Desaturate 重置）
        if self:GetAlpha() ~= 1 then
            self:SetAlpha(1)
        end
    end
end

-- =========================================================
-- 筛选菜单注入
-- =========================================================
local function InjectMenu()
    if not (Menu and Menu.ModifyMenu) then return end
    Menu.ModifyMenu("MENU_ACHIEVEMENT_FILTER", function(owner, rootDescription)
        if not module.enabled then return end
        if not IsPersonalView() then return end
        rootDescription:CreateDivider()
        rootDescription:CreateCheckbox(L["AHF_Hidden"] or "隐藏成就",
            function() return showHidden end,
            function()
                showHidden = not showHidden
                RefreshList()
            end)
    end)
end

-- =========================================================
-- 钩子安装（延迟到成就界面加载）
-- =========================================================
local function InstallHook()
    if hooked then return end
    if not AchievementFrame then return end
    hooked = true
    InjectMenu()
    WrapFilterFunctions()
    if AchievementTemplateMixin then
        hooksecurefunc(AchievementTemplateMixin, "Init", StyleButton)
    end
end

-- ============================================================
-- 模块生命周期
-- ============================================================
-- Blizzard_AchievementUI 是懒加载插件，首次打开成就界面时才加载，
-- 因此 OnEnable 中既要立即尝试安装 hook（可能已加载），
-- 也要监听 ADDON_LOADED 以便后续补装（与 AchievementIncomplete 同模式）。
local eventFrame -- 监听 Blizzard_AchievementUI 懒加载事件的 Frame

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

    if C_AddOns.IsAddOnLoaded("Blizzard_AchievementUI") then
        InstallHook()
    end
end

-- 停止监听；hook/菜单回调内部均检查 module.enabled，禁用后不再生效
function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
    showHidden = false
    RefreshList()
end
