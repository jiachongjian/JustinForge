-- ============================================================
-- JustinForge 模块7: 宏界面增强 (MacroEnhance.lua)
-- ============================================================
-- 功能描述：
--   1. 加宽加高宏界面（338×424 → 500×560），宏列表固定每行 10 个，
--      宏编辑输入框同步扩大，长宏不再频繁换行
--   2. 图标选择弹窗（改名/换图标）新增搜索框，支持按法术名称、
--      图标文件名、图标 fileID 数字模糊过滤
--   （实现逻辑提取自 ExwindTools 的 ExTools.MacroExtension，去除其
--     设置界面依赖，仅保留启用/禁用）
--
-- 实现原理：
--   1. Blizzard_MacroUI 为按需加载插件，启用模块时若未加载则监听
--      ADDON_LOADED，加载完成后一次性安装 Hook
--   2. ApplyMacroFrameLayout 通过重排 MacroFrame 子控件实现放大布局；
--      禁用时按原始尺寸复原（hook 无法卸载，但全部以 active 标志守护，
--      禁用后不再产生任何布局副作用）
--   3. 图标搜索：替换 MacroPopupFrame.IconSelector 的数据提供者
--      （SetSelectionsDataProvider）为过滤后的图标列表；清空搜索时
--      恢复默认提供者
--
-- 全局帧依赖（暴雪内置，Blizzard_MacroUI 加载后可用）：
--   MacroFrame / MacroPopupFrame / MacroHorizontalBarLeft
--   MacroFrameSelectedMacroBackground / MacroFrameSelectedMacroName
--   MacroEditButton / MacroFrameTextBackground / MacroFrameScrollFrame
--   MacroFrameText / MacroFrameTextButton
-- 若某帧在当前版本不存在则跳过对应重排，不影响其余部分。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "macroEnhance",
    name           = L["MacroEnhance_Name"],
    description    = L["MacroEnhance_Desc"],
    defaultEnabled = true,
})

-- 原始尺寸（暴雪默认）与增强尺寸
local BASE_WIDTH = 338
local BASE_HEIGHT = 424
local TARGET_WIDTH = 500
local TARGET_HEIGHT = 560

-- active: 模块功能是否生效（所有 hook 以此守护，禁用后零副作用）
local active = false
local hooksInstalled = false
local loadFrame -- 延迟加载监听帧（Blizzard_MacroUI 按需加载）

local SpellIconKeywordMap = {}
local IconPathFileIDCache = {}
local IconFileIDProbeTexture = nil

-- ------------------------------------------------------------
-- 工具函数
-- ------------------------------------------------------------
local function TrimText(text)
    if not text then return "" end
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
end

local function Clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function UpdateSearchBoxVisual(searchBox)
    if not searchBox then return end
    if SearchBoxTemplate_OnTextChanged then
        SearchBoxTemplate_OnTextChanged(searchBox)
    elseif searchBox.Instructions then
        searchBox.Instructions:SetShown(searchBox:GetText() == "")
    end
end

-- ------------------------------------------------------------
-- 法术书图标关键字表：把法术名/副名映射到图标，供搜索匹配
-- ------------------------------------------------------------
local function AddIconKeyword(map, icon, keyword)
    if not icon or not keyword or keyword == "" then return end
    local normalized = string.lower(keyword)
    local current = map[icon]
    if not current then
        map[icon] = normalized
        return
    end
    if not string.find(current, normalized, 1, true) then
        map[icon] = current .. "\n" .. normalized
    end
end

local function RebuildSpellIconKeywordMap()
    SpellIconKeywordMap = {}
    if not C_SpellBook or not Enum or not Enum.SpellBookSpellBank then
        return
    end

    local skillLineCount = C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetNumSpellBookSkillLines() or 0
    for skillLineIndex = 1, skillLineCount do
        local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(skillLineIndex)
        if skillLineInfo then
            for i = 1, skillLineInfo.numSpellBookItems do
                local slotIndex = skillLineInfo.itemIndexOffset + i
                local icon = C_SpellBook.GetSpellBookItemTexture(slotIndex, Enum.SpellBookSpellBank.Player)
                local name, subName = C_SpellBook.GetSpellBookItemName(slotIndex, Enum.SpellBookSpellBank.Player)
                AddIconKeyword(SpellIconKeywordMap, icon, name)
                AddIconKeyword(SpellIconKeywordMap, icon, subName)
            end
        end
    end
end

-- 把图标路径字符串解析为 fileID（缓存结果，失败缓存 false）
local function GetIconFileID(icon)
    if not icon then return nil end
    if type(icon) == "number" then return icon end
    if type(icon) ~= "string" then return nil end

    local cached = IconPathFileIDCache[icon]
    if cached ~= nil then
        return cached
    end

    local fileID = nil
    if GetFileIDFromPath then
        local pathVariants = {
            icon,
            string.gsub(icon, "\\", "/"),
            string.lower(icon),
            string.lower(string.gsub(icon, "\\", "/")),
        }
        for i = 1, #pathVariants do
            local ok, result = pcall(GetFileIDFromPath, pathVariants[i])
            if ok and result and result > 0 then
                fileID = result
                break
            end
        end
    end

    if not fileID then
        -- 兜底：通过临时 Texture 探测 fileID
        if not IconFileIDProbeTexture then
            local probeFrame = CreateFrame("Frame")
            IconFileIDProbeTexture = probeFrame:CreateTexture(nil, "ARTWORK")
        end
        local ok = pcall(IconFileIDProbeTexture.SetTexture, IconFileIDProbeTexture, icon)
        if ok and IconFileIDProbeTexture.GetTextureFileID then
            local probeFileID = IconFileIDProbeTexture:GetTextureFileID()
            if probeFileID and probeFileID > 0 then
                fileID = probeFileID
            end
        end
        IconFileIDProbeTexture:SetTexture(nil)
    end

    IconPathFileIDCache[icon] = fileID or false
    return fileID
end

-- ------------------------------------------------------------
-- ApplyMacroFrameLayout: 按 active 状态应用增强布局或复原默认布局
-- ------------------------------------------------------------
local function ApplyMacroFrameLayout()
    if not MacroFrame then return end

    local width = active and TARGET_WIDTH or BASE_WIDTH
    local height = active and TARGET_HEIGHT or BASE_HEIGHT

    local deltaHeight = height - BASE_HEIGHT
    local selectorExtraHeight = math.floor(deltaHeight * 0.65)
    local inputExtraHeight = deltaHeight - selectorExtraHeight

    MacroFrame:SetSize(width, height)

    if MacroFrame.MacroSelector then
        local selectorWidth = width - 19
        local selectorHeight = math.max(146, 146 + selectorExtraHeight)
        MacroFrame.MacroSelector:SetSize(selectorWidth, selectorHeight)
        MacroFrame.MacroSelector:ClearAllPoints()
        MacroFrame.MacroSelector:SetPoint("TOPLEFT", MacroFrame, "TOPLEFT", 12, -66)

        local selector = MacroFrame.MacroSelector
        local stride, horizontalSpacing
        if active then
            -- 启用增强时优先固定一行 10 个，宽度不足时自动降级
            local usableWidth = selectorWidth - 32
            local targetStride = 10
            local buttonSize = 36
            local minSpacing = 2
            local maxSpacing = 20
            horizontalSpacing = math.floor((usableWidth - targetStride * buttonSize) / (targetStride - 1))
            stride = targetStride

            if horizontalSpacing < minSpacing then
                horizontalSpacing = minSpacing
                stride = Clamp(math.floor((usableWidth + horizontalSpacing) / (buttonSize + horizontalSpacing)), 6,
                    targetStride)
            elseif horizontalSpacing > maxSpacing then
                horizontalSpacing = maxSpacing
            end
        else
            -- 关闭增强时回到暴雪原始 6 列节奏
            stride = 6
            horizontalSpacing = 13
        end

        if selector.SetCustomPadding then
            selector:SetCustomPadding(5, 5, 5, 5, horizontalSpacing, 13)
        end
        if selector.SetCustomStride then
            selector:SetCustomStride(stride)
        end

        -- ScrollBoxSelector 的 stride 在 Init() 时固化，更新后重建视图
        if selector.initialized and selector.Init then
            selector.initialized = false
            selector:Init()
        elseif selector.UpdateSelections then
            selector:UpdateSelections()
        end
    end

    if MacroHorizontalBarLeft then
        MacroHorizontalBarLeft:SetWidth(width - 82)
        MacroHorizontalBarLeft:ClearAllPoints()
        MacroHorizontalBarLeft:SetPoint("TOPLEFT", MacroFrame, "TOPLEFT", 2, -(210 + selectorExtraHeight))
    end

    if MacroFrameSelectedMacroBackground then
        MacroFrameSelectedMacroBackground:ClearAllPoints()
        MacroFrameSelectedMacroBackground:SetPoint("TOPLEFT", MacroFrame, "TOPLEFT", 5,
            -(218 + selectorExtraHeight))
    end

    if MacroFrameSelectedMacroName then
        MacroFrameSelectedMacroName:SetWidth(width - 82)
        MacroFrameSelectedMacroName:ClearAllPoints()
        MacroFrameSelectedMacroName:SetPoint("TOPLEFT", MacroFrameSelectedMacroBackground, "TOPRIGHT", -4, -10)
    end

    if MacroEditButton then
        MacroEditButton:ClearAllPoints()
        MacroEditButton:SetPoint("TOPLEFT", MacroFrameSelectedMacroBackground, "TOPLEFT", 55, -30)
        MacroEditButton:SetWidth(math.max(170, width - 163))
    end

    if MacroFrameTextBackground then
        MacroFrameTextBackground:SetSize(width - 16, 95 + inputExtraHeight)
        MacroFrameTextBackground:ClearAllPoints()
        MacroFrameTextBackground:SetPoint("TOPLEFT", MacroFrame, "TOPLEFT", 6, -(289 + selectorExtraHeight))
    end

    if MacroFrameScrollFrame then
        local scrollWidth = width - 52
        local scrollHeight = 85 + inputExtraHeight
        MacroFrameScrollFrame:SetSize(scrollWidth, scrollHeight)
        MacroFrameScrollFrame:ClearAllPoints()
        MacroFrameScrollFrame:SetPoint("TOPLEFT", MacroFrameSelectedMacroBackground, "BOTTOMLEFT", 11, -13)
        if MacroFrameText then
            MacroFrameText:SetSize(scrollWidth, scrollHeight)
        end
        if MacroFrameTextButton then
            MacroFrameTextButton:SetSize(scrollWidth, scrollHeight)
        end
    end

    SetUIPanelAttribute(MacroFrame, "width", width)
    if MacroFrame:IsShown() then
        UpdateUIPanelPositions(MacroFrame)
    end
end

-- ------------------------------------------------------------
-- 图标搜索框（挂在 MacroPopupFrame.BorderBox 上）
-- ------------------------------------------------------------
local function GetSearchBox(popup)
    if not popup or not popup.BorderBox then return nil end
    if popup.JFMacroSearchBox then
        return popup.JFMacroSearchBox
    end

    local searchBox = CreateFrame("EditBox", nil, popup.BorderBox, "SearchBoxTemplate")
    searchBox:SetSize(182, 20)
    -- 锚定图标选择器输入框；12.x 若暴雪移除该子控件则退回锚定 BorderBox 顶部
    if popup.BorderBox.IconSelectorEditBox then
        searchBox:SetPoint("TOPLEFT", popup.BorderBox.IconSelectorEditBox, "BOTTOMLEFT", 0, -13)
    else
        searchBox:SetPoint("TOPLEFT", popup.BorderBox, "TOPLEFT", 20, -40)
    end
    searchBox:SetAutoFocus(false)
    if searchBox.Instructions then
        searchBox.Instructions:SetText(L["MacroEnhance_SearchHint"])
    end

    popup.JFMacroSearchBox = searchBox
    return searchBox
end

local function UpdatePopupHintTextState(popup)
    if not popup or not popup.BorderBox or not popup.BorderBox.IconSelectionText then return end
    if active then
        -- 增强开启时隐藏原提示文字，避免与搜索框重叠
        popup.BorderBox.IconSelectionText:Hide()
        popup.BorderBox.IconSelectionText:SetAlpha(0)
    else
        popup.BorderBox.IconSelectionText:SetAlpha(1)
        local draggingIcon = popup.BorderBox.IconDragArea and popup.BorderBox.IconDragArea:IsShown()
        popup.BorderBox.IconSelectionText:SetShown(not draggingIcon)
    end
end

-- 单个图标与查询的匹配：数字按 fileID 模糊，字符串按路径/短名/法术名模糊
local function MatchIcon(icon, queryLower, queryNumber)
    if icon == nil then return false end

    if queryNumber then
        if type(icon) == "number" then
            if icon == queryNumber or string.find(tostring(icon), queryLower, 1, true) then
                return true
            end
        elseif type(icon) == "string" then
            local asNumber = tonumber(icon)
            if asNumber and (asNumber == queryNumber or string.find(tostring(asNumber), queryLower, 1, true)) then
                return true
            end

            local fileID = GetIconFileID(icon)
            if fileID and (fileID == queryNumber or string.find(tostring(fileID), queryLower, 1, true)) then
                return true
            end
        end
    end

    if type(icon) == "string" then
        local iconLower = string.lower(icon)
        if string.find(iconLower, queryLower, 1, true) then
            return true
        end
        local shortName = string.gsub(iconLower, "^interface\\icons\\", "")
        if string.find(shortName, queryLower, 1, true) then
            return true
        end
    elseif type(icon) == "number" then
        if string.find(tostring(icon), queryLower, 1, true) then
            return true
        end
    end

    local keywords = SpellIconKeywordMap[icon]
    if keywords and string.find(keywords, queryLower, 1, true) then
        return true
    end

    return false
end

local function BuildFilteredIcons(popup, query)
    local filtered = {}
    if not popup or not popup.iconDataProvider then
        return filtered
    end

    local queryLower = string.lower(query)
    local queryNumber = tonumber(queryLower)
    local seen = {}

    local function BuildIconKey(icon)
        if type(icon) == "number" then
            return "n:" .. tostring(icon)
        end
        return "s:" .. tostring(icon)
    end

    local function AddUnique(icon)
        if icon == nil then return end
        local key = BuildIconKey(icon)
        if seen[key] then return end
        seen[key] = true
        filtered[#filtered + 1] = icon
    end

    local total = popup.iconDataProvider:GetNumIcons()
    for i = 1, total do
        local icon = popup.iconDataProvider:GetIconByIndex(i)
        if MatchIcon(icon, queryLower, queryNumber) then
            AddUnique(icon)
        end
    end

    -- 纯数字查询时额外补充该 fileID 本身及同名法术图标
    if queryNumber then
        AddUnique(queryNumber)
        if C_Spell and C_Spell.GetSpellTexture then
            local ok, spellIcon = pcall(C_Spell.GetSpellTexture, queryNumber)
            if ok and spellIcon then
                AddUnique(spellIcon)
            end
        end
    end

    return filtered
end

local function ApplyDefaultProvider(popup)
    popup.IconSelector:SetSelectionsDataProvider(
        GenerateClosure(popup.GetIconByIndex, popup),
        GenerateClosure(popup.GetNumIcons, popup)
    )
    popup.IconSelector:UpdateSelections()
end

local function ApplyFilteredProvider(popup, filteredIcons)
    popup._jfMacroFilteredIcons = filteredIcons
    popup.IconSelector:SetSelectionsDataProvider(
        function(index)
            local list = popup._jfMacroFilteredIcons
            return list and list[index] or nil
        end,
        function()
            local list = popup._jfMacroFilteredIcons
            return list and #list or 0
        end
    )
    popup.IconSelector:UpdateSelections()
end

local function ReevaluateSelection(popup, filteredIcons)
    local selectedTexture = popup.BorderBox.SelectedIconArea.SelectedIconButton:GetIconTexture()
    local selectedIndex = nil

    if filteredIcons then
        for i = 1, #filteredIcons do
            if filteredIcons[i] == selectedTexture then
                selectedIndex = i
                break
            end
        end
    else
        selectedIndex = popup:GetIndexOfIcon(selectedTexture)
    end

    popup.IconSelector:SetSelectedIndex(selectedIndex)
    popup:SetSelectedIconText()
    if selectedIndex then
        popup.IconSelector:ScrollToSelectedIndex()
    end
end

local function RefreshIconSearch(popup)
    if not popup or not popup.IconSelector or not popup.iconDataProvider then return end

    local searchBox = GetSearchBox(popup)
    if not searchBox then return end

    if not active then
        searchBox:Hide()
        popup._jfMacroFilteredIcons = nil
        ApplyDefaultProvider(popup)
        ReevaluateSelection(popup, nil)
        UpdatePopupHintTextState(popup)
        return
    end

    UpdatePopupHintTextState(popup)
    searchBox:Show()

    local query = TrimText(searchBox:GetText() or "")
    if query == "" then
        popup._jfMacroFilteredIcons = nil
        ApplyDefaultProvider(popup)
        ReevaluateSelection(popup, nil)
        return
    end

    local filteredIcons = BuildFilteredIcons(popup, query)
    ApplyFilteredProvider(popup, filteredIcons)
    ReevaluateSelection(popup, filteredIcons)
end

local function SetupSearchBoxHandlers(popup)
    local searchBox = GetSearchBox(popup)
    if not searchBox or searchBox._jfMacroHooked then return end

    searchBox:SetScript("OnTextChanged", function(self)
        UpdateSearchBoxVisual(self)
        RefreshIconSearch(popup)
    end)

    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
        RefreshIconSearch(popup)
    end)

    searchBox._jfMacroHooked = true
end

-- ------------------------------------------------------------
-- Hook 安装（一次性，hooksInstalled 守护；hook 内均以 active 守护）
-- ------------------------------------------------------------
local function InstallHooks()
    if hooksInstalled or not MacroFrame or not MacroPopupFrame then return end
    hooksInstalled = true

    MacroFrame:HookScript("OnShow", function()
        if active then
            ApplyMacroFrameLayout()
        end
    end)

    MacroPopupFrame:HookScript("OnShow", function(popup)
        RebuildSpellIconKeywordMap()
        SetupSearchBoxHandlers(popup)
        UpdatePopupHintTextState(popup)
        if popup.JFMacroSearchBox then
            popup.JFMacroSearchBox:SetText("")
            UpdateSearchBoxVisual(popup.JFMacroSearchBox)
        end
        RefreshIconSearch(popup)
    end)

    MacroPopupFrame:HookScript("OnHide", function(popup)
        if popup.JFMacroSearchBox then
            popup.JFMacroSearchBox:SetText("")
            UpdateSearchBoxVisual(popup.JFMacroSearchBox)
        end
        popup._jfMacroFilteredIcons = nil
    end)

    hooksecurefunc(MacroPopupFrame, "Update", function(popup)
        RefreshIconSearch(popup)
    end)
    -- 12.x 若暴雪改名/移除这些方法则跳过对应 Hook（hooksecurefunc 对
    -- 不存在的函数会报错），不影响其余功能
    if MacroPopupFrame.SetIconFilterInternal then
        hooksecurefunc(MacroPopupFrame, "SetIconFilterInternal", function(popup)
            RefreshIconSearch(popup)
        end)
    end
    if MacroPopupFrame.UpdateStateFromCursorType then
        hooksecurefunc(MacroPopupFrame, "UpdateStateFromCursorType", function(popup)
            UpdatePopupHintTextState(popup)
        end)
    end

    ApplyMacroFrameLayout()
end

-- Blizzard_MacroUI 按需加载，就绪后安装 Hook；返回是否已就绪
local function TryInit()
    if not C_AddOns.IsAddOnLoaded("Blizzard_MacroUI") then
        return false
    end
    if not MacroFrame or not MacroPopupFrame then
        return false
    end
    InstallHooks()
    return true
end

-- ------------------------------------------------------------
-- OnEnable: 启用模块
-- ------------------------------------------------------------
function module:OnEnable()
    active = true
    if not TryInit() then
        -- 宏界面插件尚未加载，监听其加载事件（一次性）
        if not loadFrame then
            loadFrame = CreateFrame("Frame")
            loadFrame:SetScript("OnEvent", function(self, _, name)
                if name ~= "Blizzard_MacroUI" then return end
                self:UnregisterEvent("ADDON_LOADED")
                C_Timer.After(0, function()
                    if active then TryInit() end
                end)
            end)
        end
        loadFrame:RegisterEvent("ADDON_LOADED")
    end
    Util:Debug("MacroEnhance: 已启用")
end

-- ------------------------------------------------------------
-- OnDisable: 禁用模块
-- ------------------------------------------------------------
-- 复原宏界面原始布局并隐藏搜索框；hook 保留但由 active 守护，不再生效
function module:OnDisable()
    active = false
    if loadFrame then
        loadFrame:UnregisterAllEvents()
    end
    if MacroFrame then
        ApplyMacroFrameLayout() -- active=false，恢复原始尺寸
    end
    if MacroPopupFrame then
        RefreshIconSearch(MacroPopupFrame) -- active=false，隐藏搜索框并恢复默认数据
    end
    Util:Debug("MacroEnhance: 已禁用，布局已复原")
end
