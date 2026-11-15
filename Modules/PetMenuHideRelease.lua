-- ============================================================
-- JustinForge 模块23: 隐藏宠物右键「释放」项 (PetMenuHideRelease.lua)
-- ============================================================
-- 功能描述：
--   在宠物框体（PetFrame）右键菜单中隐藏「释放」项，
--   避免误点导致宠物被放归、需要重新召唤或找回。
--   同菜单中的「解散」「放弃宠物」保持原样，不受影响。
--
-- 实现原理：
--   暴雪右键菜单（UnitPopup）在弹出瞬间逐项读取全局表
--   UnitPopupMenus[which] 决定显示哪些菜单项，宠物框体使用
--   which = "PET"。本模块启用时把目标项从 UnitPopupMenus["PET"]
--   中移除并记录其原索引，禁用时按原索引插回，
--   菜单结构与顺序和原生完全一致。
--
--   判定目标项：优先按菜单项 ID（PET_RELEASE），
--   再按显示文本包含「释放」兜底匹配，覆盖不同版本 / 译名的差异；
--   「解散」「放弃宠物」通过 ID 与关键词双重排除，确保不会被误隐藏。
--
-- 注意：
--   - 只做纯 Lua 表操作，不 Hook 任何受保护函数，也不操作下拉菜单按钮；
--   - 若客户端改动菜单结构（UnitPopupMenus 不存在），模块静默不生效；
--   - 菜单表在登录期间长期有效，界面重载后按保存的开关状态重新应用。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local tinsert, tremove = table.insert, table.remove
local strfind = strfind

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

-- ------------------------------------------------------------
-- 需要隐藏的菜单项 ID
-- ------------------------------------------------------------
-- PET_RELEASE：「释放」（部分版本译为「释放宠物」）
-- 注意：PET_DISMISS（解散）与 PET_ABANDON（放弃宠物）不在此列
local HIDDEN_ITEM_IDS = {
    PET_RELEASE = true,
}

-- 绝不隐藏的菜单项 ID（即使文本关键词误命中也要排除）
local EXCLUDED_ITEM_IDS = {
    PET_DISMISS = true,  -- 解散宠物
    PET_ABANDON = true,  -- 放弃宠物
}

-- 已被移除的菜单项记录：{ index = 原索引, id = 菜单项 ID }
local removedItems = {}
-- 是否已将隐藏规则应用到当前菜单表
local applied = false

-- ------------------------------------------------------------
-- GetPetMenu: 取宠物框体右键菜单的定义表
-- ------------------------------------------------------------
-- 返回：UnitPopupMenus["PET"]（数组），不可用时返回 nil
local function GetPetMenu()
    local menus = _G.UnitPopupMenus
    if type(menus) ~= "table" then return nil end
    local menu = menus["PET"]
    if type(menu) ~= "table" then return nil end
    return menu
end

-- ------------------------------------------------------------
-- GetItemText: 取菜单项的显示文本
-- ------------------------------------------------------------
-- 菜单项文本定义在 UnitPopupButtons[id].text
-- 返回：字符串，取不到时返回 nil
local function GetItemText(id)
    local buttons = _G.UnitPopupButtons
    local button = buttons and buttons[id]
    local text = button and button.text
    if type(text) == "string" then
        return text
    end
    return nil
end

-- ------------------------------------------------------------
-- IsReleaseItem: 判断某个菜单项是否为需要隐藏的「释放」项
-- ------------------------------------------------------------
-- 参数 id：菜单项 ID（如 "PET_RELEASE"）
-- 返回：true 表示需要隐藏
local function IsReleaseItem(id)
    if type(id) ~= "string" then return false end

    -- 明确排除「解散」「放弃宠物」，优先级最高
    if EXCLUDED_ITEM_IDS[id] then return false end
    if HIDDEN_ITEM_IDS[id] then return true end

    -- 文本兜底：
    --   1) 显示文本等于客户端 PET_RELEASE 字符串
    --   2) 显示文本包含「释放」关键词（排除项已在上面跳过）
    local text = GetItemText(id)
    if not text then return false end

    local releaseText = _G.PET_RELEASE
    if releaseText ~= nil and text == releaseText then
        return true
    end

    local keyword = L["PetMenuHideRelease_Keyword"]
    if keyword and strfind(text, keyword, 1, true) then
        return true
    end

    return false
end

-- ------------------------------------------------------------
-- Apply: 从宠物菜单中移除目标项，并记录原索引
-- ------------------------------------------------------------
local function Apply()
    if applied then return end

    local menu = GetPetMenu()
    if not menu then
        Util:Debug("PetMenuHideRelease: 未找到 UnitPopupMenus.PET，跳过")
        return
    end

    removedItems = {}
    local index = 1
    while index <= #menu do
        local id = menu[index]
        if IsReleaseItem(id) then
            tinsert(removedItems, { index = index, id = id })
            tremove(menu, index)
            -- 移除后该位置已是下一项，索引不递增
        else
            index = index + 1
        end
    end

    applied = true
    Util:Debug("PetMenuHideRelease: 已隐藏宠物右键菜单项 " .. #removedItems)
end

-- ------------------------------------------------------------
-- Restore: 按原索引把移除的项插回，完全还原原生菜单
-- ------------------------------------------------------------
local function Restore()
    if not applied then return end

    local menu = GetPetMenu()
    if menu then
        -- 按记录顺序（原索引升序）插回：每次插入都已还原前段顺序，
        -- 因此原索引即为正确的插入位置；菜单被外部改动时做越界保护
        for _, item in ipairs(removedItems) do
            local pos = item.index
            if pos > #menu + 1 then
                pos = #menu + 1
            end
            tinsert(menu, pos, item.id)
        end
    end

    removedItems = {}
    applied = false
    Util:Debug("PetMenuHideRelease: 已还原宠物右键菜单")
end

-- ------------------------------------------------------------
-- OnEnable / OnDisable
-- ------------------------------------------------------------
function module:OnEnable()
    Apply()
end

function module:OnDisable()
    Restore()
end
