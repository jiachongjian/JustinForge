-- =========================================================
-- 模块：筛选个人隐藏成就（AchievementHiddenFilter）
-- 功能：在成就界面「成就」（个人）标签页的筛选下拉菜单中追加「隐藏成就」勾选项：
--   - 未勾选（默认）：保持原生行为，列表不显示未完成的隐藏成就
--   - 勾选：未完成的隐藏成就追加显示在列表末尾，
--           并以区别样式标记（稍淡透明度 + 淡紫色名称）
--   - 已完成的成就不受任何影响
-- 注意：仅个人成就标签页生效（公会/统计/对比视图不受影响）。
-- 机制说明（对照 12.x 客户端源码）：
--   - 原生三个筛选函数（AchievementFrame_GetCategoryNumAchievements_*）调用
--     GetCategoryNumAchievements(categoryID) 时「不传」includeAll，默认枚举不含未完成隐藏成就；
--   - 本模块在 UpdateDataProvider 后自行用 includeAll 口径枚举分类，把隐藏成就以
--     {category, id, indexAll}（不含 index）追加进 DataProvider——
--     AchievementTemplateMixin:Init 对无 index 的元素走 GetAchievementInfo(self.id)
--     按 ID 取数路径（与索引枚举口径无关，彻底避免口径失效导致的取数失败）；
--   - 展开高度计算 AchievementTemplateMixin.CalculateSelectedHeight 固定用 (category, index)，
--     因此对注入元素通过垫片重设 includeAll 口径后使用 indexAll 调用原函数；
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

-- 获取当前选中的分类ID（从分类列表选中态读取，数字分类才有效）
local function GetSelectedCategoryID()
    local scrollBox = AchievementFrameCategories and AchievementFrameCategories.ScrollBox
    local dataProvider = scrollBox and scrollBox:GetDataProvider()
    if not dataProvider then return nil end
    for _, elementData in dataProvider:Enumerate() do
        if elementData.selected then
            return elementData.id
        end
    end
    return nil
end

-- =========================================================
-- 列表注入：UpdateDataProvider 后置，把未完成的隐藏成就追加进 DataProvider
-- 注入元素不带 index 字段，Init 将按 id 取数（与枚举口径无关）
-- =========================================================
local function InjectHiddenAchievements()
    if not (module.enabled and showHidden) then return end
    if not IsPersonalView() then return end
    local scrollBox = AchievementFrameAchievements and AchievementFrameAchievements.ScrollBox
    local dataProvider = scrollBox and scrollBox:GetDataProvider()
    if not dataProvider then return end

    local category = GetSelectedCategoryID()
    if type(category) ~= "number" then return end -- summary 等

    local existing = {}
    for _, elementData in dataProvider:Enumerate() do
        if elementData.id then
            existing[elementData.id] = true
        end
    end

    -- includeAll 口径枚举（含隐藏成就），索引口径与本次调用一致
    local numAll = GetCategoryNumAchievements(category, true)
    for index = 1, numAll do
        local id = GetAchievementInfo(category, index)
        if id and not existing[id] and IsHiddenIncomplete(id) then
            dataProvider:Insert({ category = category, id = id, indexAll = index })
        end
    end
end

-- =========================================================
-- 展开高度垫片：CalculateSelectedHeight 固定用 (category, index) 取数，
-- 对注入元素改用 indexAll（includeAll 口径索引），调用前重设枚举口径
-- =========================================================
local function WrapCalculateSelectedHeight()
    local orig = AchievementTemplateMixin.CalculateSelectedHeight
    if type(orig) ~= "function" then return end
    AchievementTemplateMixin.CalculateSelectedHeight = function(elementData)
        if module.enabled and elementData and elementData.index == nil
            and elementData.indexAll and elementData.category then
            GetCategoryNumAchievements(elementData.category, true) -- 重设索引枚举口径
            return orig({ category = elementData.category, index = elementData.indexAll, id = elementData.id })
        end
        return orig(elementData)
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
    WrapCalculateSelectedHeight()
    hooksecurefunc("AchievementFrameAchievements_UpdateDataProvider", InjectHiddenAchievements)
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
