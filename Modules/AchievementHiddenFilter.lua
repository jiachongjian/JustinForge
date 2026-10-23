-- =========================================================
-- 模块：筛选个人隐藏成就（AchievementHiddenFilter）
-- 功能：在成就界面「成就」（个人）标签页的筛选下拉菜单中追加「隐藏成就」勾选项：
--   - 未勾选（默认）：保持原生行为，列表不显示未完成的隐藏成就
--   - 勾选：未完成的隐藏成就追加显示在列表末尾，
--           并以区别样式标记（稍淡透明度 + 淡紫色名称）
--   - 已完成的成就不受任何影响
-- 注意：仅个人成就标签页生效（公会/统计/对比视图不受影响）。
-- 机制说明（对照 12.x 客户端源码与实测结论）：
--   - 原生三个筛选函数调用 GetCategoryNumAchievements(categoryID)「不传」includeAll，
--     默认枚举不含未完成隐藏成就；
--   - GetCategoryNumAchievements(categoryID, true) 的「计数」会包含隐藏成就，
--     但 GetAchievementInfo(category, index) 在隐藏成就对应的索引上返回 nil——
--     即无法通过分类索引枚举拿到隐藏成就 ID（实测确认），
--     因此本模块改为按 ID 全量扫描（分帧执行，一次会话仅一次）建立
--     「分类 -> 未完成隐藏成就 ID」缓存；
--   - 注入元素只带 {category, id}（不含 index）：AchievementTemplateMixin:Init 对无 index
--     的元素走 GetAchievementInfo(self.id) 按 ID 取数路径，取数必然成功；
--   - 展开高度：AchievementTemplateMixin.CalculateSelectedHeight 固定用 (category, index) 取数，
--     故为注入元素复刻一份按 ID 取数的同逻辑实现；
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
local SCAN_CHUNK = 3000               -- 每帧扫描的 ID 数量
local SCAN_PROBE_STEP = 1000          -- 上界探测步长
local SCAN_PROBE_MAX = 200000         -- 上界探测上限

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

-- =========================================================
-- 隐藏成就 ID 索引：按 ID 全量扫描（分帧），建立「分类 -> 未完成隐藏成就」缓存
-- 分类索引枚举拿不到隐藏成就 ID（见文件头说明），只能按 ID 逐条查询
-- =========================================================
local hiddenByCategory -- [categoryID] = { id, ... }，扫描完成后有效
local scanFinished = false
local scanStarted = false
local scanCurrentID = 1
local scanLimit = 1
local scanFrame

local function OnScanComplete()
    scanStarted = false
    scanFinished = true
    if module.enabled and showHidden then
        RefreshList()
    end
end

local function ScanChunk()
    local last = math.min(scanCurrentID + SCAN_CHUNK - 1, scanLimit)
    for id = scanCurrentID, last do
        -- GetAchievementInfo(id) 返回 id, name, points, completed, month, day, year, description, flags, ...
        local realID, name, _, completed, _, _, _, _, flags = GetAchievementInfo(id)
        if realID then
            if flags and bit.band(flags, HIDDEN_FLAG) == HIDDEN_FLAG and not completed then
                hiddenFlagCache[id] = true
                local categoryID = GetAchievementCategory(id)
                if type(categoryID) == "number" and categoryID >= 0 then
                    local list = hiddenByCategory[categoryID]
                    if not list then
                        list = {}
                        hiddenByCategory[categoryID] = list
                    end
                    list[#list + 1] = id
                end
            end
        end
    end
    scanCurrentID = last + 1
    if scanCurrentID > scanLimit then
        OnScanComplete()
    end
end

local function StartScan()
    if scanStarted or scanFinished then return end
    scanStarted = true
    hiddenByCategory = {}
    -- 探测有效 ID 上界（稀疏探测 + 步长余量）
    local upper = 0
    for id = 1, SCAN_PROBE_MAX, SCAN_PROBE_STEP do
        if GetAchievementInfo(id) ~= nil then
            upper = id
        end
    end
    scanLimit = math.min(upper + SCAN_PROBE_STEP, SCAN_PROBE_MAX)
    scanCurrentID = 1
    if not scanFrame then
        scanFrame = CreateFrame("Frame")
    end
    scanFrame:SetScript("OnUpdate", function()
        ScanChunk()
        if scanFinished then
            scanFrame:SetScript("OnUpdate", nil)
        end
    end)
end

-- =========================================================
-- 当前分类 ID
-- =========================================================
local function GetSelectedCategoryID()
    local catScrollBox = AchievementFrameCategories and AchievementFrameCategories.ScrollBox
    local catDataProvider = catScrollBox and catScrollBox:GetDataProvider()
    if catDataProvider then
        for _, elementData in catDataProvider:Enumerate() do
            if elementData.selected then
                return elementData.id
            end
        end
    end
    -- 回退：从成就列表元素读取分类
    local scrollBox = AchievementFrameAchievements and AchievementFrameAchievements.ScrollBox
    local dataProvider = scrollBox and scrollBox:GetDataProvider()
    if dataProvider then
        for _, elementData in dataProvider:Enumerate() do
            if type(elementData.category) == "number" then
                return elementData.category
            end
        end
    end
    return nil
end

-- =========================================================
-- 列表注入：UpdateDataProvider 后置，把未完成的隐藏成就追加进 DataProvider
-- 注入元素不含 index，Init 将按 id 取数（与枚举口径无关）
-- =========================================================
local function InjectHiddenAchievements()
    if not (module.enabled and showHidden) then return end
    if not IsPersonalView() then return end

    if not scanFinished then
        StartScan()
        return -- 扫描完成后会自动刷新列表
    end

    local category = GetSelectedCategoryID()
    if type(category) ~= "number" then return end -- summary 等
    local ids = hiddenByCategory and hiddenByCategory[category]
    if not ids or #ids == 0 then return end

    local scrollBox = AchievementFrameAchievements and AchievementFrameAchievements.ScrollBox
    local dataProvider = scrollBox and scrollBox:GetDataProvider()
    if not dataProvider then return end

    local existing = {}
    for _, elementData in dataProvider:Enumerate() do
        if elementData.id then
            existing[elementData.id] = true
        end
    end
    local inserted = false
    for _, id in ipairs(ids) do
        if not existing[id] and IsHiddenIncomplete(id) then
            dataProvider:Insert({ category = category, id = id, hiddenInjected = true })
            inserted = true
        end
    end
    -- 插入发生在 SetDataProvider 之后，强制立即布局一次确保新元素渲染
    if inserted and ScrollBoxConstants and ScrollBoxConstants.UpdateImmediately then
        scrollBox:FullUpdate(ScrollBoxConstants.UpdateImmediately)
    end
end

-- =========================================================
-- 展开高度：复刻 12.x AchievementTemplateMixin.CalculateSelectedHeight，
-- 唯一差异为首行按 id 取数（原函数固定用 category+index）
-- =========================================================
local function CalculateHiddenHeight(elementData)
    local totalHeight = ACHIEVEMENTBUTTON_COLLAPSEDHEIGHT
    local objectivesHeight = 0

    if not AchievementFrame.textCheckWidth then
        AchievementFrame.PlaceholderName:SetText("- ")
        AchievementFrame.textCheckWidth = AchievementFrame.PlaceholderName:GetStringWidth()
    end

    local id, name, points, completed, month, day, year, description, flags, icon, rewardText, isGuild, wasEarnedByMe, earnedBy = GetAchievementInfo(elementData.id)
    if not id then
        return ACHIEVEMENTBUTTON_COLLAPSEDHEIGHT
    end

    if completed and GetPreviousAchievement(id) then
        local achievementCount = 1
        local nextID = id
        while GetPreviousAchievement(nextID) do
            achievementCount = achievementCount + 1
            nextID = GetPreviousAchievement(nextID)
        end
        local MaxAchievementsPerRow = 6
        objectivesHeight = math.ceil(achievementCount / MaxAchievementsPerRow) * ACHIEVEMENTUI_PROGRESSIVEHEIGHT
    else
        local numExtraCriteriaRows = 0
        local maxCriteriaWidth = 0
        local textStrings = 0
        local progressBars = 0
        local metas = 0
        local numMetaRows = 0
        local numCriteriaRows = 0
        if not completed then
            local requiresRep = GetAchievementGuildRep(id)
            if requiresRep then
                numExtraCriteriaRows = numExtraCriteriaRows + 1
            end
        end

        local numCriteria = GetAchievementNumCriteria(id)
        for i = 1, numCriteria do
            local criteriaString, criteriaType, criteriaCompleted, quantity, reqQuantity, charName, criteriaFlags, assetID = GetAchievementCriteriaInfo(id, i)
            if criteriaType == CRITERIA_TYPE_ACHIEVEMENT and assetID then
                metas = metas + 1
                if metas == 1 or (math.fmod(metas, 2) ~= 0) then
                    numMetaRows = numMetaRows + 1
                end
            elseif bit.band(criteriaFlags, EVALUATION_TREE_FLAG_PROGRESS_BAR) == EVALUATION_TREE_FLAG_PROGRESS_BAR then
                progressBars = progressBars + 1
                numCriteriaRows = numCriteriaRows + 1
            else
                textStrings = textStrings + 1
                local stringWidth = 0
                local maxCriteriaContentWidth
                if criteriaCompleted then
                    maxCriteriaContentWidth = ACHIEVEMENTUI_MAXCONTENTWIDTH - ACHIEVEMENTUI_CRITERIACHECKWIDTH
                    AchievementFrame.PlaceholderName:SetText(criteriaString)
                    stringWidth = math.min(AchievementFrame.PlaceholderName:GetStringWidth(), maxCriteriaContentWidth)
                else
                    maxCriteriaContentWidth = ACHIEVEMENTUI_MAXCONTENTWIDTH - AchievementFrame.textCheckWidth
                    local dashedString = "- " .. criteriaString
                    AchievementFrame.PlaceholderName:SetText(dashedString)
                    stringWidth = math.min(AchievementFrame.PlaceholderName:GetStringWidth() - AchievementFrame.textCheckWidth, maxCriteriaContentWidth)
                end
                if AchievementFrame.PlaceholderName:GetWidth() > maxCriteriaContentWidth then
                    AchievementFrame.PlaceholderName:SetWidth(maxCriteriaContentWidth)
                end
                maxCriteriaWidth = math.max(maxCriteriaWidth, stringWidth + ACHIEVEMENTUI_CRITERIACHECKWIDTH)
                numCriteriaRows = numCriteriaRows + 1
            end
        end

        if textStrings > 0 and progressBars > 0 then
            -- 混合布局，保持原逻辑无额外处理
        elseif textStrings > 1 then
            local numColumns = math.floor(ACHIEVEMENTUI_MAXCONTENTWIDTH / maxCriteriaWidth)
            local forceColumns = numColumns == 1 and textStrings >= FORCE_COLUMNS_MIN_CRITERIA and maxCriteriaWidth <= FORCE_COLUMNS_MAX_WIDTH
            if forceColumns then
                numColumns = 2
            end
            if numColumns > 1 then
                numCriteriaRows = math.ceil(numCriteriaRows / numColumns)
            end
        end

        numCriteriaRows = numCriteriaRows + numExtraCriteriaRows
        local height = numMetaRows * ACHIEVEMENTBUTTON_METAROWHEIGHT + numCriteriaRows * ACHIEVEMENTBUTTON_CRITERIAROWHEIGHT
        if metas > 0 or progressBars > 0 then
            height = height + 10
        end
        objectivesHeight = height
    end

    totalHeight = totalHeight + objectivesHeight

    AchievementFrame.PlaceholderHiddenDescription:SetText(description)
    local numLines = math.ceil(AchievementFrame.PlaceholderHiddenDescription:GetHeight() / ACHIEVEMENTUI_FONTHEIGHT)
    if (totalHeight ~= ACHIEVEMENTBUTTON_COLLAPSEDHEIGHT) or (numLines > ACHIEVEMENTUI_MAX_LINES_COLLAPSED) then
        local descriptionHeight = AchievementFrame.PlaceholderHiddenDescription:GetHeight()
        totalHeight = totalHeight + descriptionHeight - ACHIEVEMENTBUTTON_DESCRIPTIONHEIGHT
        if rewardText ~= "" then
            totalHeight = totalHeight + 4
        end
    end

    if InGuildView() and totalHeight < GUILDACHIEVEMENTBUTTON_MINHEIGHT then
        return GUILDACHIEVEMENTBUTTON_MINHEIGHT
    end
    return totalHeight
end

local function WrapCalculateSelectedHeight()
    local orig = AchievementTemplateMixin.CalculateSelectedHeight
    if type(orig) ~= "function" then return end
    AchievementTemplateMixin.CalculateSelectedHeight = function(elementData)
        if module.enabled and elementData and elementData.hiddenInjected and elementData.id then
            return CalculateHiddenHeight(elementData)
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
                if showHidden then
                    StartScan()
                end
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
local eventFrame

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
    if scanFrame then
        scanFrame:SetScript("OnUpdate", nil)
    end
    showHidden = false
    RefreshList()
end