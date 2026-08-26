-- ============================================================
-- JustinForge Module: 公会查找器增强 (GuildFinderEnhance.lua)
-- ============================================================
-- 功能：增强未加入公会时的「查找公会」界面（公会查找器）
--   1. 打开查找器时自动发起一次空搜索，直接浏览全部招募中的公会（可关闭）
--   2. 补充排序下拉（相关度 / 人数最多 / 最新招募）——暴雪默认只对社区
--      查找器显示排序，对公会搜索隐藏；选择后自动重新搜索
--   3. 鼠标悬停公会卡片时，在暴雪提示后追加：语言、跨阵营、装等要求、
--      仅满级、招募信息更新时间
-- 注：12.0 起暴雪已移除公会招募的「活动时间」数据，无法展示
-- 实现要点：
--   - Blizzard_Communities 懒加载，需等 ADDON_LOADED 后再 hook
--   - 排序设置与社区查找器共用（C_ClubFinder 玩家申请设置）
--   - 语言位掩码解码参考暴雪 ClubFinderFilterDropdownMixin:GetLocaleFlag
-- ============================================================
local addonName, ns = ...
local L = ns.L

local module = ns.Module:Register({
    key            = "guildFinderEnhance",
    name           = L["GuildFinderEnhance_Name"],
    description    = L["GuildFinderEnhance_Desc"],
    defaultEnabled = true,
    options = {
        { type = "checkbox", key = "autoSearch", name = L["GFE_AutoSearch"], default = true },
    },
})

-- 排序选项：flag 对应 Enum.ClubFinderSettingFlags 键名，field 对应
-- C_ClubFinder.GetPlayerApplicantSettings() 返回表中的布尔字段
local SORT_OPTIONS = {
    { flag = "SortRelevance",   field = "sortRelevance", labelKey = "GFE_SortRelevance" },
    { flag = "SortMemberCount", field = "sortMembers",   labelKey = "GFE_SortMembers" },
    { flag = "SortNewest",      field = "sortNewest",    labelKey = "GFE_SortNewest" },
}

local installed = false
local sortDropdown = nil

local function ReportError(err)
    ns.Util:Error(L["Error_FinderHook"]:format(tostring(err)))
end

local function GetFinderFrame()
    return CommunitiesFrame and CommunitiesFrame.GuildFinderFrame
end

-- ---- 排序 ----

local function GetCurrentSort()
    local ok, settings = pcall(C_ClubFinder.GetPlayerApplicantSettings)
    if ok and settings then
        for _, opt in ipairs(SORT_OPTIONS) do
            if settings[opt.field] then
                return opt.flag
            end
        end
    end
    return "SortRelevance"
end

local function GetSortLabel(flag)
    for _, opt in ipairs(SORT_OPTIONS) do
        if opt.flag == flag then
            return L[opt.labelKey]
        end
    end
    return L["GFE_SortRelevance"]
end

local function RefreshSortText()
    if sortDropdown and sortDropdown.SetText then
        sortDropdown:SetText(L["GFE_SortFormat"]:format(GetSortLabel(GetCurrentSort())))
    end
end

local function ApplySort(flag)
    for _, opt in ipairs(SORT_OPTIONS) do
        C_ClubFinder.SetPlayerApplicantSettings(Enum.ClubFinderSettingFlags[opt.flag], opt.flag == flag)
    end
    RefreshSortText()
    -- 已有搜索结果时自动重新搜索，让排序立即生效
    local finderFrame = GetFinderFrame()
    if finderFrame and finderFrame.GuildCards and #finderFrame.GuildCards.CardList > 0 then
        finderFrame.OptionsList:OnSearchButtonClick()
    end
end

local function CreateSortDropdown(finderFrame)
    local optionsList = finderFrame.OptionsList
    sortDropdown = CreateFrame("DropdownButton", nil, optionsList, "WowStyle1DropdownTemplate")
    sortDropdown:SetSize(150, 20)
    sortDropdown:SetPoint("TOP", optionsList.Search, "BOTTOM", 0, -8)
    sortDropdown:SetupMenu(function(_, rootDescription)
        rootDescription:SetTag("JUSTINFORGE_GFE_SORT")
        for _, opt in ipairs(SORT_OPTIONS) do
            local flag = opt.flag
            rootDescription:CreateRadio(L[opt.labelKey], function()
                return GetCurrentSort() == flag
            end, function()
                ApplySort(flag)
            end)
        end
    end)
    RefreshSortText()
end

local function SyncSortVisibility(finderFrame)
    if sortDropdown then
        -- 仅在搜索页（selectedTab == 1）显示，待处理申请页隐藏
        sortDropdown:SetShown(module.enabled and finderFrame.selectedTab == 1)
    end
end

-- ---- 自动搜索 ----

local function AutoSearch()
    if not module.enabled then return end
    local db = ns.db and ns.db.profile and ns.db.profile.guildFinderEnhance
    if db and db.autoSearch == false then return end
    local finderFrame = GetFinderFrame()
    if not finderFrame or not finderFrame.isGuildType then return end
    if finderFrame.selectedTab ~= 1 then return end
    if not C_ClubFinder.IsEnabled() then return end
    local cards = finderFrame.GuildCards
    -- 已有结果（本次会话搜索过）则不重复搜索
    if not cards or #cards.CardList > 0 then return end
    finderFrame.OptionsList:OnSearchButtonClick()
end

-- ---- 卡片提示增强 ----

local function AppendLanguageLine(info)
    if not info.localeSet or not info.recruitmentLocale then return false end
    if not GetAvailableLocaleInfo then return false end
    local parts = {}
    for _, localeInfo in ipairs(GetAvailableLocaleInfo(true)) do
        local flag = bit.lshift(1, localeInfo.localeId)
        if bit.band(info.recruitmentLocale, flag) ~= 0 then
            local atlas = LocaleUtil and LocaleUtil.GetLanguageAtlas and LocaleUtil.GetLanguageAtlas(localeInfo.localeName)
            if atlas then
                parts[#parts + 1] = ("|A:%s:0:0|a"):format(atlas)
            else
                parts[#parts + 1] = localeInfo.localeName
            end
        end
    end
    if #parts == 0 then return false end
    GameTooltip:AddLine(L["GFE_TipLanguage"]:format(table.concat(parts, " ")), 1, 1, 1)
    return true
end

local function AppendTooltip(card)
    if not module.enabled then return end
    local info = card.cardInfo
    if not info then return end
    local added = false

    if AppendLanguageLine(info) then added = true end

    if info.isCrossFaction then
        GameTooltip:AddLine(L["GFE_TipCrossFaction"], 1, 1, 1)
        added = true
    end

    if info.minILvl and info.minILvl > 0 then
        GameTooltip:AddLine(L["GFE_TipMinIlvl"]:format(info.minILvl), 1, 1, 1)
        added = true
    end

    if info.recruitmentFlags
        and bit.band(info.recruitmentFlags, bit.lshift(1, Enum.ClubFinderSettingFlags.MaxLevelOnly)) ~= 0 then
        GameTooltip:AddLine(L["GFE_TipMaxLevelOnly"], 1, 1, 1)
        added = true
    end

    if info.lastUpdatedTime then
        local elapsed = C_DateAndTime.GetServerTimeLocal() - info.lastUpdatedTime
        local days = math.floor(elapsed / 86400)
        if days <= 0 then
            GameTooltip:AddLine(L["GFE_TipUpdatedToday"], 0.6, 0.6, 0.6)
        else
            GameTooltip:AddLine(L["GFE_TipUpdatedDays"]:format(days), 0.6, 0.6, 0.6)
        end
        added = true
    end

    if added then
        GameTooltip:Show()
    end
end

-- ---- 安装 hook（Blizzard_Communities 加载后执行一次） ----

local function Install()
    if installed then return end
    local finderFrame = GetFinderFrame()
    if not finderFrame or not finderFrame.OptionsList then return end
    if not ClubFinderGuildCardMixin then return end
    installed = true

    CreateSortDropdown(finderFrame)

    -- 公会卡片与待处理申请卡片共用 ClubFinderGuildCardMixin
    hooksecurefunc(ClubFinderGuildCardMixin, "OnEnter", function(card)
        local ok, err = pcall(AppendTooltip, card)
        if not ok then ReportError(err) end
    end)

    -- 切换「搜索 / 待处理申请」标签时同步排序下拉显隐
    hooksecurefunc(finderFrame, "GetDisplayModeBasedOnSelectedTab", function(self)
        local ok, err = pcall(SyncSortVisibility, self)
        if not ok then ReportError(err) end
    end)

    finderFrame:HookScript("OnShow", function()
        local ok, err = pcall(AutoSearch)
        if not ok then ReportError(err) end
    end)

    SyncSortVisibility(finderFrame)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(_, _, name)
    if name == "Blizzard_Communities" then
        local ok, err = pcall(Install)
        if not ok then ReportError(err) end
    end
end)
-- 若本插件加载时 Blizzard_Communities 已就绪则立即安装
if C_AddOns.IsAddOnLoaded("Blizzard_Communities") then
    local ok, err = pcall(Install)
    if not ok then ReportError(err) end
end

function module:OnEnable()
    if sortDropdown then
        local finderFrame = GetFinderFrame()
        if finderFrame then
            SyncSortVisibility(finderFrame)
        end
    end
end

function module:OnDisable()
    if sortDropdown then
        sortDropdown:Hide()
    end
end
