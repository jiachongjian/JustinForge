-- ============================================================
-- JustinForge 模块7: 宏界面增强 (MacroEnhance.lua)
-- ============================================================
-- 功能描述：
--   加高宏界面（338×424 → 338×580），宏列表每页 6 列 × 5 行
--   共 30 个（宽度不变），宏编辑输入框同步加高，长宏不再频繁换行
--
-- 实现原理：
--   1. Blizzard_MacroUI 为按需加载插件，启用模块时若未加载则监听
--      ADDON_LOADED，加载完成后一次性安装 Hook
--   2. ApplyMacroFrameLayout 通过重排 MacroFrame 子控件实现放大布局；
--      禁用时按原始尺寸复原（hook 无法卸载，但全部以 active 标志守护，
--      禁用后不再产生任何布局副作用）
--
-- 全局帧依赖（暴雪内置，Blizzard_MacroUI 加载后可用）：
--   MacroFrame / MacroHorizontalBarLeft
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
-- 增强只加高不加宽：高度 +156 中约 65% 分配给宏列表（保证完整显示 5 行），
-- 其余分配给宏编辑输入框
local BASE_WIDTH = 338
local BASE_HEIGHT = 424
local TARGET_WIDTH = 338
local TARGET_HEIGHT = 580

-- active: 模块功能是否生效（所有 hook 以此守护，禁用后零副作用）
local active = false
local hooksInstalled = false
local loadFrame -- 延迟加载监听帧（Blizzard_MacroUI 按需加载）

-- ------------------------------------------------------------
-- 工具函数
-- ------------------------------------------------------------
local function Clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

-- ------------------------------------------------------------
-- ApplySelectorStructure: 一次性结构改动（仅干净上下文、宏界面首次显示前执行）
-- 关键：绝不在 OnShow / MacroFrame_Update 等污染上下文里调用 Init() 重建 ScrollBox
-- 视图——那会污染 ScrollBox 内部 frame 表，随后 ChangeTab→SaveMacro→EditMacro
-- 会被判定为插件行为而抛 ADDON_ACTION_BLOCKED。结构只在加载时定型一次。
-- ------------------------------------------------------------
local selectorStructureDone = false
local function ApplySelectorStructure()
    if selectorStructureDone then return end
    if not (MacroFrame and MacroFrame.MacroSelector) then return end
    if not active then return end
    selectorStructureDone = true

    local width = TARGET_WIDTH
    local selectorWidth = width - 19
    local deltaHeight = TARGET_HEIGHT - BASE_HEIGHT
    local selectorExtraHeight = math.floor(deltaHeight * 0.65)
    local selectorHeight = math.max(146, 146 + selectorExtraHeight)

    local selector = MacroFrame.MacroSelector
    selector:SetSize(selectorWidth, selectorHeight)
    selector:ClearAllPoints()
    selector:SetPoint("TOPLEFT", MacroFrame, "TOPLEFT", 12, -66)

    local usableWidth = selectorWidth - 32
    local targetStride = 6
    local buttonSize = 36
    local minSpacing = 2
    local maxSpacing = 20
    local horizontalSpacing = math.floor((usableWidth - targetStride * buttonSize) / (targetStride - 1))
    local stride = targetStride
    if horizontalSpacing < minSpacing then
        horizontalSpacing = minSpacing
        stride = Clamp(math.floor((usableWidth + horizontalSpacing) / (buttonSize + horizontalSpacing)), 4, targetStride)
    elseif horizontalSpacing > maxSpacing then
        horizontalSpacing = maxSpacing
    end

    if selector.SetCustomPadding then
        selector:SetCustomPadding(5, 5, 5, 5, horizontalSpacing, 13)
    end
    if selector.SetCustomStride then
        selector:SetCustomStride(stride)
    end

    -- 视图重建只此一次（干净上下文），之后交给暴雪自身的 Update 流程
    if selector.initialized and selector.Init then
        selector.initialized = false
        selector:Init()
    elseif selector.UpdateSelections then
        selector:UpdateSelections()
    end
end

-- ------------------------------------------------------------
-- ApplyMacroFrameLayout: 窗口几何重排（仅 SetSize/SetPoint，不触碰 ScrollBox
-- 内部状态，OnShow 重复应用安全）。禁用时按原始尺寸复原。
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
-- Hook 安装（一次性，hooksInstalled 守护；hook 内均以 active 守护）
-- ------------------------------------------------------------
local function InstallHooks()
    if hooksInstalled or not MacroFrame then return end
    hooksInstalled = true

    MacroFrame:HookScript("OnShow", function()
        if active then
            ApplyMacroFrameLayout()
        end
    end)

    ApplyMacroFrameLayout()
end

-- Blizzard_MacroUI 按需加载，就绪后安装 Hook；返回是否已就绪
local function TryInit()
    if not C_AddOns.IsAddOnLoaded("Blizzard_MacroUI") then
        return false
    end
    if not MacroFrame then
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
-- 复原宏界面原始布局；hook 保留但由 active 守护，不再生效
function module:OnDisable()
    active = false
    if loadFrame then
        loadFrame:UnregisterAllEvents()
    end
    if MacroFrame then
        ApplyMacroFrameLayout() -- active=false，恢复原始尺寸
    end
    Util:Debug("MacroEnhance: 已禁用，布局已复原")
end