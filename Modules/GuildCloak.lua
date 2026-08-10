-- ============================================================
-- JustinForge 模块1: 公会披风自动还原 (GuildCloak.lua)
-- ============================================================
-- 功能描述：
--   玩家使用公会阵营披风传送后，自动将背槽装备换回传送前的
--   物品，避免披风长时间占用背槽装备位。
--
-- 实现原理（触发时机借鉴自 SanluliUtils 的 UnequipTeleportEquipment）：
--   1. 平时用 PLAYER_EQUIPMENT_CHANGED 追踪注册的槽位，
--      把非传送装备记录为「还原目标」，并持久化到
--      SavedVariables（按角色分键），/reload 或重登后不丢失
--   2. 传送落地时（PLAYER_ENTERING_WORLD）扫描这些槽位，
--      若身上仍穿着传送装备，则换回还原目标
--   3. 落地瞬间若处于战斗锁定（战斗中 EquipItemByName 会失败），
--      等待 PLAYER_REGEN_ENABLED 脱战后再补执行
--   4. 换回成功 / 无还原目标时在聊天框给出提示
--
-- 为何不在装备瞬间换回：
--   公会披风需先装备再手动使用才能触发传送，若一穿上就换回，
--   玩家可能来不及使用。改为「传送落地后检测」才不会干扰传送流程。
--
-- 防循环说明：
--   触发点是落地扫描而非装备事件，换回原装备所触发的
--   PLAYER_EQUIPMENT_CHANGED 只会把还原目标更新为同一件装备（幂等），
--   因此不再需要旧版的 isRestoring 防循环标志。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

-- 背槽装备位编号（WoW 常量 INVSLOT_BACK = 15）
-- 使用 or 15 作为兜底，防止常量未定义
local INVSLOT_BACK = INVSLOT_BACK or 15

-- ============================================================
-- 传送装备表（按槽位组织）
-- ============================================================
-- 结构：TELEPORT_EQUIPMENT_SLOTS[槽位][物品ID] = true
-- 当前预置6个公会披风ID（对应不同阵营/版本）
-- 如需扩展其他传送装备（如肯瑞托戒指），在此添加对应槽位表即可：
--   [11] = { [40585] = true, ... },  -- 手指1
--   [12] = { [40585] = true, ... },  -- 手指2
local TELEPORT_EQUIPMENT_SLOTS = {
    [INVSLOT_BACK] = {
        [65360] = true, -- 协同披风 (暴风城, 2h)
        [65274] = true, -- 协同披风 (奥格瑞玛, 2h)
        [63353] = true, -- 协作披风 (奥格瑞玛, 8h)
        [63206] = true, -- 协和披风 (暴风城, 4h)
        [63352] = true, -- 协作披风 (暴风城, 8h)
        [63207] = true, -- 协和披风 (奥格瑞玛, 4h)
    },
}

-- ============================================================
-- 模块注册
-- ============================================================
-- 注册到模块框架，key 必须与 Init.lua defaults 表中的键名一致
-- name/description 引用本地化字符串，显示在设置面板
local module = ns.Module:Register({
    key            = "guildCloak",
    name           = L["GuildCloak_Name"],
    description    = L["GuildCloak_Desc"],
    defaultEnabled = true,
})

-- 事件 Frame：接收装备变更 / 进入世界 / 脱战事件
-- 模块禁用时解绑事件，实现零开销
local eventFrame
-- 落地时处于战斗锁定的等待标志（脱战后补执行换回）
local waitingCombatLockdown = false

-- ------------------------------------------------------------
-- GetRestoreStore: 获取当前角色的「还原目标」持久化存储表
-- ------------------------------------------------------------
-- 还原目标保存在 SavedVariables：
--   ns.db.profile.guildCloak.previousItems[角色名-服务器][槽位] = 装备链接
-- 按角色分键，避免多角色共用配置时互相污染；
-- 持久化后 /reload 或重新登录不再丢失还原目标。
-- ns.db 在 ADDON_LOADED 后才挂载，本模块的事件与 OnEnable 均晚于
-- 该时机触发，此处返回 nil 仅为防御异常时序
local function GetRestoreStore()
    local db = ns.db and ns.db.profile and ns.db.profile.guildCloak
    if not db then return nil end
    if not db.previousItems then
        db.previousItems = {}
    end
    local charKey = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
    if not db.previousItems[charKey] then
        db.previousItems[charKey] = {}
    end
    return db.previousItems[charKey]
end

-- ------------------------------------------------------------
-- IsTeleportEquipment: 判断某槽位当前装备是否为传送装备
-- ------------------------------------------------------------
-- 未注册追踪的槽位返回 false；槽位为空时 GetInventoryItemID
-- 返回 nil，同样返回 false
local function IsTeleportEquipment(slot)
    local slotTable = TELEPORT_EQUIPMENT_SLOTS[slot]
    if not slotTable then return false end
    local itemID = GetInventoryItemID("player", slot)
    return itemID ~= nil and slotTable[itemID] == true
end

-- ------------------------------------------------------------
-- CheckTeleportEquipment: 扫描并换回传送装备
-- ------------------------------------------------------------
-- 在传送落地（PLAYER_ENTERING_WORLD）或脱战
-- （PLAYER_REGEN_ENABLED）后调用
local function CheckTeleportEquipment()
    local store = GetRestoreStore()
    for slot in pairs(TELEPORT_EQUIPMENT_SLOTS) do
        if IsTeleportEquipment(slot) then
            local currentLink = GetInventoryItemLink("player", slot)
            local previousLink = store and store[slot]
            if previousLink and GetItemCount(previousLink) > 0 then
                -- 换回传送前的装备
                -- 换回触发的装备事件会把还原目标更新为同一件装备，幂等无循环
                EquipItemByName(previousLink, slot)
                Util:Print(L["GuildCloak_Restored"]:format(previousLink))
            elseif previousLink then
                -- 有还原记录但原装备已不在背包（被出售/摧毁/存入银行），无法换回
                Util:Print(L["GuildCloak_ItemMissing"]:format(currentLink or "?", previousLink))
            else
                -- 没有还原目标（该角色从未记录过其他背部装备），仅提示不动作
                Util:Print(L["GuildCloak_NoPrevious"]:format(currentLink or "?"))
            end
        end
    end
end

-- ------------------------------------------------------------
-- OnEvent: 事件分发
-- ------------------------------------------------------------
local function OnEvent(_, event, arg1, arg2)
    if event == "PLAYER_EQUIPMENT_CHANGED" then
        -- arg1 = 发生变更的装备位编号, arg2 = 是否有当前物品
        local equipmentSlot, hasCurrent = arg1, arg2
        -- 卸下装备不影响还原目标，跳过
        if not hasCurrent then return end
        -- 只追踪注册过的槽位
        if not TELEPORT_EQUIPMENT_SLOTS[equipmentSlot] then return end
        -- 只记录非传送装备；传送装备本身不能作为还原目标
        if not IsTeleportEquipment(equipmentSlot) then
            local store = GetRestoreStore()
            if store then
                store[equipmentSlot] = GetInventoryItemLink("player", equipmentSlot)
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- 传送/登录/reload 落地后检测
        if InCombatLockdown() then
            -- 战斗中无法换装，标记后等待脱战
            waitingCombatLockdown = true
        else
            CheckTeleportEquipment()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- 脱战后补执行因战斗锁定而推迟的换回
        if waitingCombatLockdown then
            waitingCombatLockdown = false
            CheckTeleportEquipment()
        end
    end
end

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
-- 1. 创建事件 Frame（懒创建，首次启用时才创建）
-- 2. 注册装备变更 / 进入世界 / 脱战事件
-- 3. 刷新还原目标：记录当前各槽位的非传送装备
--    （若启用时正穿着披风则跳过记录，保留已持久化的还原目标，
--    不会把披风误记为还原目标）
function module:OnEnable()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEvent)
    end
    eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

    local store = GetRestoreStore()
    if store then
        for slot in pairs(TELEPORT_EQUIPMENT_SLOTS) do
            if not IsTeleportEquipment(slot) then
                store[slot] = GetInventoryItemLink("player", slot)
            end
        end
    end
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
-- 1. 解绑所有事件（实现零开销，禁用后不再消耗任何运行时资源）
-- 2. 清理运行时状态标志
-- 注意：不要清空 DB 中的还原目标，持久化记录需跨会话保留
function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
    waitingCombatLockdown = false
end
