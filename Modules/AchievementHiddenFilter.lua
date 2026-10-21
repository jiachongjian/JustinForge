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
--     的返回值循环 GetAchievementInfo(category, index) 填充列表，索引枚举由最近一次
--     GetCategoryNumAchievements 决定——因此包装筛选函数传 includeAll=true 即可让原生循环
--     自动列出隐藏成就（WeakAuras 同款枚举模式）；
--   - 隐藏成就的判定：GetAchievementInfo(id) 第 9 个返回值 flags 的 0x800 位（HIDE_INCOMPLETE）。
-- =========================================================

local ADDON_NAME, JF = ...
local L = JF.L

local module = JF:RegisterModule("AchievementHiddenFilter", "achievementHiddenFilter")

-- 常量定义
local HIDDEN_FLAG = 0x00000800 -- GetAchievementInfo flags：HIDE_INCOMPLETE（隐藏成就，完成前不可见）
local ACHIEVEMENT_FILTER_ALL = 1
local ACHIEVEMENT_FILTER_COMPLETE = 2
local ACHIEVEMENT_FILTER_INCOMPLETE = 3
local HIDDEN_ALPHA = 0.85             -- 隐藏成就按钮整体透明度
local HIDDEN_LABEL_R, HIDDEN_LABEL_G, HIDDEN_LABEL_B = 0.75, 0.6, 1 -- 隐藏成就名称颜色（淡紫）

-- 模块状态
local showHidden = false -- 「隐藏成就」勾选项是否选中（默认不勾选=隐藏），会话内有效
local hooked = false
local originalFilterFuncs = nil -- 包装前保存的原生筛选函数（按 AchievementFrameFilters 索引）

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
-- 列表注入：包装三个原生筛选函数，勾选时改用 includeAll 枚举
-- （返回值映射完全复刻暴雪原生实现，仅枚举范围变为含隐藏成就）
-- =========================================================
local function WrapFilterFunctions()
    if originalFilterFuncs then return end
    if not AchievementFrameFilters or not ACHIEVEMENTUI_SELECTEDFILTER then return end
    originalFilterFuncs = {}
    for i, filter in ipairs(AchievementFrameFilters) do
        local orig = filter.func
        originalFilterFuncs[i] = orig
        filter.func = function(categoryID)
            if module.enabled and showHidden and IsPersonalView() then
                local numAchievements, numCompleted, numIncomplete = GetCategoryNumAchievements(categoryID, true)
                if i == ACHIEVEMENT_FILTER_ALL then
                    return numAchievements, numCompleted, 0
                elseif i == ACHIEVEMENT_FILTER_COMPLETE then
                    return numCompleted, numCompleted, 0
                else -- ACHIEVEMENT_FILTER_INCOMPLETE
                    return numIncomplete, 0, numAchievements - numIncomplete
                end
            end
            return orig(categoryID)
        end
    end
    -- ACHIEVEMENTUI_SELECTEDFILTER 持有原函数引用，重新指向包装后的对应函数
    for i = 1, #AchievementFrameFilters do
        if ACHIEVEMENTUI_SELECTEDFILTER == originalFilterFuncs[i] then
            ACHIEVEMENTUI_SELECTEDFILTER = AchievementFrameFilters[i].func
            break
        end
    end
end

-- =========================================================
-- 样式区分：未完成的隐藏成就以区别样式显示
-- =========================================================
local function StyleButton(self)
    if not module.enabled then return end
    if not IsPersonalView() then return end
    local elementData = self.GetElementData and self:GetElementData()
    local id = elementData and elementData.id or self.id
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

-- =========================================================
-- 模块生命周期
-- =========================================================
function module:OnInitialize()
    if not self:IsEnabled() then return end
    if C_AddOns and C_AddOns.IsAddOnLoaded("Blizzard_AchievementUI") then
        InstallHook()
    end
end

function module:OnEnable()
    RefreshList()
end

function module:OnDisable()
    showHidden = false
    RefreshList()
end

module:RegisterEvent("ADDON_LOADED", function(self, addonName)
    if addonName == "Blizzard_AchievementUI" then
        InstallHook()
    end
end)
