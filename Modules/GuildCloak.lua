-- ============================================================
-- JustinForge 模块1: 公会披风自动还原 (GuildCloak.lua)
-- ============================================================
-- 功能描述：
--   玩家使用公会阵营披风（如展示公会徽章）后，自动将背槽装备
--   换回使用前的物品，避免披风占用背槽装备位。
--
-- 实现原理：
--   1. 监听 PLAYER_EQUIPMENT_CHANGED 事件（装备变更时触发）
--   2. 过滤只处理背槽（INVSLOT_BACK = 15）的变更
--   3. 检测新装备的物品ID是否在公会披风ID列表中
--   4. 若是公会披风，延迟0.5秒后用 EquipItemByName 还原前置装备
--   5. isRestoring 标志防止还原操作再次触发事件导致死循环
--
-- 防循环机制：
--   还原装备本身也会触发 PLAYER_EQUIPMENT_CHANGED，
--   通过 isRestoring 标志在还原期间忽略事件，还原完成后重置
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

-- 背槽装备位编号（WoW 常量 INVSLOT_BACK = 15）
-- 使用 or 15 作为兜底，防止常量未定义
local INVSLOT_BACK = INVSLOT_BACK or 15

-- ============================================================
-- 公会披风物品ID列表（用户提供）
-- ============================================================
-- 使用表作为集合（key 为物品ID，value 为 true），查找复杂度 O(1)
-- 如需添加或删除披风ID，直接编辑此表即可
-- 当前预置的6个ID对应不同阵营/版本的公会披风
local GUILD_CLOAK_ITEM_IDS = {
    [65360] = true,
    [65274] = true,
    [63353] = true,
    [63206] = true,
    [63352] = true,
    [63207] = true,
}

-- ============================================================
-- 模块注册
-- ============================================================
-- 注册到模块框架，key 必须与 Init.lua defaults 表中的键名一致
-- name/description 引用本地化字符串，显示在设置面板
-- Register 返回 module 表，后续为其添加 OnEnable/OnDisable 方法
local module = ns.Module:Register({
    key            = "guildCloak",
    name           = L["GuildCloak_Name"],
    description    = L["GuildCloak_Desc"],
    defaultEnabled = true,
})

-- 事件 Frame：用于接收 PLAYER_EQUIPMENT_CHANGED 事件
-- 模块禁用时解绑事件，实现零开销
local eventFrame
-- 记录背槽使用前的装备链接（用于还原）
local previousBackLink
-- 还原进行中标志：true 时忽略装备变更事件，防止死循环
local isRestoring = false

-- ------------------------------------------------------------
-- GetBackItemID: 获取当前背槽装备的物品ID
-- ------------------------------------------------------------
-- 返回数字ID或 nil（背槽为空时）
local function GetBackItemID()
    return GetInventoryItemID("player", INVSLOT_BACK)
end

-- ------------------------------------------------------------
-- OnEquipmentChanged: 装备变更事件处理
-- ------------------------------------------------------------
-- 参数：
--   self           事件 Frame
--   equipmentSlot  发生变更的装备位编号
--   hasCurrent     是否有当前物品（true=装上，false=卸下）
local function OnEquipmentChanged(_, equipmentSlot, hasCurrent)
    -- 只处理背槽变更，其他装备位忽略
    if equipmentSlot ~= INVSLOT_BACK then return end
    -- 还原操作进行中，忽略事件（防循环）
    if isRestoring then return end
    -- 只处理「装上物品」的情况（卸下不触发还原）
    if not hasCurrent then return end

    local currentID = GetBackItemID()
    if not currentID then return end

    if GUILD_CLOAK_ITEM_IDS[currentID] then
        -- ---- 检测到公会披风被装备，执行还原 ----
        -- 仅当记录了前置装备时才还原（避免首次就装备披风无法还原）
        if previousBackLink then
            isRestoring = true  -- 标记还原中，阻止后续事件触发循环
            local linkToRestore = previousBackLink
            previousBackLink = nil

            -- 延迟0.5秒执行还原，等待装备变更动画/服务端确认完成
            C_Timer.After(0.5, function()
                -- 二次检查模块是否仍启用（用户可能在延迟期间禁用了模块）
                if not module.enabled then
                    isRestoring = false
                    return
                end
                -- 执行还原：将前置装备重新装备到背槽
                EquipItemByName(linkToRestore, INVSLOT_BACK)

                -- 还原完成后再延迟0.5秒重置标志
                -- 等待还原触发的 PLAYER_EQUIPMENT_CHANGED 事件过去
                C_Timer.After(0.5, function()
                    isRestoring = false
                    -- 更新追踪：记录还原后的装备（若非公会披风则作为新的前置装备）
                    local restoredID = GetBackItemID()
                    if restoredID and not GUILD_CLOAK_ITEM_IDS[restoredID] then
                        previousBackLink = GetInventoryItemLink("player", INVSLOT_BACK)
                    end
                end)
            end)
        end
    else
        -- ---- 普通装备变更，更新前置装备记录 ----
        -- 记录当前背槽物品链接，作为下次检测到披风时的还原目标
        previousBackLink = GetInventoryItemLink("player", INVSLOT_BACK)
    end
end

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
-- 1. 创建事件 Frame（懒创建，首次启用时才创建）
-- 2. 注册 PLAYER_EQUIPMENT_CHANGED 事件
-- 3. 初始化前置装备追踪（记录当前背槽物品，若非披风则作为还原目标）
function module:OnEnable()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEquipmentChanged)
    end
    eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

    -- 初始化追踪：若当前背槽不是公会披风，记录为前置装备
    local currentID = GetBackItemID()
    if currentID and not GUILD_CLOAK_ITEM_IDS[currentID] then
        previousBackLink = GetInventoryItemLink("player", INVSLOT_BACK)
    else
        -- 当前是披风或背槽为空，暂无前置装备可还原
        previousBackLink = nil
    end
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
-- 1. 解绑事件（实现零开销，禁用后不再消耗任何运行时资源）
-- 2. 清理状态变量，避免下次启用时残留旧数据
function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterEvent("PLAYER_EQUIPMENT_CHANGED")
    end
    previousBackLink = nil
    isRestoring = false
end
