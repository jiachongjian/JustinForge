-- ============================================================
-- JustinForge 模块23: 隐藏宠物右键「释放」项 (PetMenuHideRelease.lua)
-- ============================================================
-- 功能描述：
--   在宠物框体（PetFrame）右键菜单中隐藏「释放」项，
--   避免误点导致宠物被永久释放。
--   同菜单中的「解散」「重命名」「设置焦点」等保持原样。
--
-- 实现原理（12.x / 至暗之夜）：
--   12.0 起单位右键菜单改由新 Menu 系统构建：
--     UnitPopupManager:OpenMenu("PET", contextData)
--       -> MenuUtil.CreateContextMenu + SetTag("MENU_UNIT_PET")
--       -> UnitPopupMenuPet:GetEntries() 返回一组 Button Mixin
--       -> 逐项调用 entry:CanShow(contextData)，为 false 才跳过不显示
--   其中「释放」= UnitPopupPetAbandonButtonMixin（GetText 返回 PET_ABANDON），
--   「解散」= UnitPopupPetDismissButtonMixin（PET_DISMISS），两者互相独立。
--
--   因此只需要包装 UnitPopupPetAbandonButtonMixin.CanShow，
--   在模块启用期间返回 false，即可让「释放」项不参与菜单构建；
--   禁用时还原原函数。只影响该单个菜单项，不改菜单表、不 Hook 菜单构建入口，
--   不会波及「解散」等其它项的点击执行。
--
--   兼容：若客户端仍是旧版 UnitPopup 系统（UnitPopupMenus["PET"] 为数组），
--   则改为从该数组中移除 PET_ABANDON，并在禁用时按原索引插回。
--
-- 注意：
--   - Blizzard_UnitPopupShared 可能晚于本插件加载，故监听 ADDON_LOADED
--     / PLAYER_ENTERING_WORLD 重试包装，避免加载顺序导致失效；
--   - 若客户端改动 Mixin 名称，包装静默跳过（不影响其它功能）。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local strfind = strfind
local tinsert, tremove = table.insert, table.remove

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "petMenuHideRelease",
    name           = L["PetMenuHideRelease_Name"],
    description    = L["PetMenuHideRelease_Desc"],
    tooltip        = L["PetMenuHideRelease_Tooltip"],
    defaultEnabled = true,
})

-- 12.x：宠物「释放」项对应的 Mixin 全局名
local ABANDON_MIXIN_NAME = "UnitPopupPetAbandonButtonMixin"
-- 旧版 UnitPopup 系统中「释放」对应的菜单项 ID
local LEGACY_ITEM_ID = "PET_ABANDON"

-- 原始 CanShow（包装前），用于禁用时还原
local originalCanShow
-- 已被包装的 mixin 表（用于还原时确认对象一致）
local hookedMixin
-- 旧版系统移除记录：原索引数组
local legacyRemovedIndexes = {}
-- 事件监听框架（惰性创建，OnEnable/OnDisable 间复用）
local eventFrame

-- ------------------------------------------------------------
-- HideCanShow: 包装后的 CanShow
-- ------------------------------------------------------------
-- 模块启用期间恒返回 false，使「释放」项不显示；
-- 模块禁用后回落到原始实现（正常情况下已还原，不依赖此分支）
local function HideCanShow(self, contextData)
    if module.enabled then
        return false
    end
    if originalCanShow then
        return originalCanShow(self, contextData)
    end
    return true
end

-- ------------------------------------------------------------
-- ApplyMenuHook: 包装新 Menu 系统的「释放」Mixin.CanShow
-- ------------------------------------------------------------
-- 返回：true 表示已完成包装（mixin 不存在时返回 false）
local function ApplyMenuHook()
    local mixin = _G[ABANDON_MIXIN_NAME]
    if type(mixin) ~= "table" then return false end
    if mixin.CanShow == HideCanShow then return true end

    originalCanShow = mixin.CanShow
    mixin.CanShow = HideCanShow
    hookedMixin = mixin
    Util:Debug("PetMenuHideRelease: 已接管 " .. ABANDON_MIXIN_NAME .. ".CanShow")
    return true
end

-- ------------------------------------------------------------
-- GetLegacyPetMenu: 旧版 UnitPopup 宠物菜单数组
-- ------------------------------------------------------------
local function GetLegacyPetMenu()
    local menus = _G.UnitPopupMenus
    if type(menus) ~= "table" then return nil end
    local menu = menus["PET"]
    if type(menu) ~= "table" then return nil end
    return menu
end

-- ------------------------------------------------------------
-- ApplyLegacy: 旧版系统下从菜单数组中移除 PET_ABANDON
-- ------------------------------------------------------------
local function ApplyLegacy()
    local menu = GetLegacyPetMenu()
    if not menu then return false end

    legacyRemovedIndexes = {}
    local index = 1
    while index <= #menu do
        if menu[index] == LEGACY_ITEM_ID then
            tinsert(legacyRemovedIndexes, index)
            tremove(menu, index)
            -- 移除后该位置已是下一项，索引不递增
        else
            index = index + 1
        end
    end
    return #legacyRemovedIndexes > 0
end

-- ------------------------------------------------------------
-- RestoreLegacy: 旧版系统下按原索引插回
-- ------------------------------------------------------------
local function RestoreLegacy()
    if #legacyRemovedIndexes == 0 then return end

    local menu = GetLegacyPetMenu()
    if menu then
        for _, pos0 in ipairs(legacyRemovedIndexes) do
            local pos = pos0
            if pos > #menu + 1 then
                pos = #menu + 1
            end
            tinsert(menu, pos, LEGACY_ITEM_ID)
        end
    end
    legacyRemovedIndexes = {}
end

-- ------------------------------------------------------------
-- Apply / Restore: 总入口
-- ------------------------------------------------------------
local function Apply()
    local hooked = ApplyMenuHook()
    ApplyLegacy()
    return hooked
end

local function Restore()
    -- 还原新 Menu 系统的 CanShow
    if hookedMixin and hookedMixin.CanShow == HideCanShow then
        hookedMixin.CanShow = originalCanShow
    end
    hookedMixin = nil
    originalCanShow = nil

    -- 还原旧版系统菜单数组
    RestoreLegacy()
end

-- ------------------------------------------------------------
-- EnsureApplied: 幂等应用（应对 Blizzard 插件延迟加载/重定义）
-- ------------------------------------------------------------
local function EnsureApplied()
    if not module.enabled then return end
    Apply()
end

-- ------------------------------------------------------------
-- 事件：等待 Blizzard_UnitPopupShared 加载完成后补装包装
-- ------------------------------------------------------------
local function CreateEventFrame()
    eventFrame = CreateFrame("Frame")
    eventFrame:SetScript("OnEvent", function(_, event, arg1)
        if not module.enabled then return end

        if event == "ADDON_LOADED" then
            -- 只关心 UnitPopup 相关插件（Blizzard_UnitPopupShared 等）
            if type(arg1) == "string" and strfind(arg1, "UnitPopup") then
                EnsureApplied()
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            -- 再次兜底：登录完成后确认包装仍然生效
            EnsureApplied()
        end
    end)
end

-- ------------------------------------------------------------
-- OnEnable / OnDisable
-- ------------------------------------------------------------
function module:OnEnable()
    if not eventFrame then
        CreateEventFrame()
    end
    eventFrame:RegisterEvent("ADDON_LOADED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

    if not Apply() then
        Util:Debug("PetMenuHideRelease: 菜单 Mixin 尚未加载，等待 ADDON_LOADED 后重试")
    end
end

function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
    Restore()
end
