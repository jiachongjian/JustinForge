-- ============================================================
-- JustinForge 模块1: 自动脱下传送装备 (TeleportUnequip.lua)
-- ============================================================
-- 功能描述：
--   玩家使用传送装备（公会披风、肯瑞托戒指等）传送后，
--   自动将对应槽位换回传送前的物品，避免传送装备长时间
--   占用装备位。
--
-- 实现原理（触发时机借鉴自 SanluliUtils 的 UnequipTeleportEquipment）：
--   1. 平时用 PLAYER_EQUIPMENT_CHANGED 追踪注册的槽位，
--      把非传送装备记录为「还原目标」，并持久化到
--      SavedVariables（按角色分键），/reload 或重登后不丢失
--   2. 两条触发路径覆盖全部传送场景：
--      a. PLAYER_ENTERING_WORLD：跨地图传送（有读条画面）落地后触发
--      b. BAG_UPDATE_COOLDOWN：同地图传送无读条画面，不触发
--         PLAYER_ENTERING_WORLD，改为通过装备冷却「刚开始」判定使用
--         （穿上装备触发的冷却仅 30 秒，使用冷却为 30min～8h，可区分）
--   3. 换回执行带重试：落地瞬间背包数据可能尚未复制到客户端
--      （GetItemCount 短暂返回 0），间隔重试数次，仅最终失败才提示
--   4. 若处于战斗锁定（战斗中 EquipItemByName 会失败），
--      等待 PLAYER_REGEN_ENABLED 脱战后补执行
--   5. 换回成功 / 无还原目标时在聊天框给出提示
--
-- 为何不在装备瞬间换回：
--   传送装备需先装备再手动使用才能触发传送，若一穿上就换回，
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

-- 装备位编号（WoW 常量，使用 or 兜底防止常量未定义）
local INVSLOT_FINGER1 = INVSLOT_FINGER1 or 11
local INVSLOT_FINGER2 = INVSLOT_FINGER2 or 12
local INVSLOT_BACK    = INVSLOT_BACK    or 15

-- ============================================================
-- 传送装备表（按槽位组织）
-- ============================================================
-- 结构：TELEPORT_EQUIPMENT_SLOTS[槽位][物品ID] = true
-- 手指1与手指2共用同一张表（同一传送戒指可能戴在任一手指）
local TELEPORT_EQUIPMENT_SLOTS = {
    [INVSLOT_FINGER1] = {
        -- 达拉然(晶歌森林) 30min
        [40585] = true,  -- 肯瑞托徽记
        [40586] = true,  -- 肯瑞托指环
        [44934] = true,  -- 肯瑞托指箍
        [44935] = true,  -- 肯瑞托戒指
        [45688] = true,  -- 肯瑞托铭文指环
        [45689] = true,  -- 肯瑞托铭文指箍
        [45690] = true,  -- 肯瑞托铭文戒指
        [45691] = true,  -- 肯瑞托铭文徽记
        [48954] = true,  -- 肯瑞托铭刻指环
        [48955] = true,  -- 肯瑞托铭刻指箍
        [48956] = true,  -- 肯瑞托铭刻戒指
        [48957] = true,  -- 肯瑞托铭刻徽记
        [51557] = true,  -- 肯瑞托符文徽记
        [51558] = true,  -- 肯瑞托符文戒指
        [51559] = true,  -- 肯瑞托符文佩戒
        [51560] = true,  -- 肯瑞托符文指环
        -- 达拉然(破碎群岛) 30min
        [139599] = true, -- 肯瑞托强化指环
        -- 比兹莫搏击俱乐部 联盟 1h
        [95051] = true,  -- 黄铜指虎
        [118907] = true, -- 格斗士的重击指环
        [144391] = true, -- 拳手的重击指环
        -- 比兹莫搏击俱乐部 部落 1h
        [95050] = true,  -- 黄铜指虎
        [118908] = true, -- 格斗士的重击指环
        [144392] = true, -- 拳手的重击指环
        -- 其他
        [142469] = true, -- 魔导大师的紫罗兰印戒 (卡拉赞, 4h)
        [166559] = true, -- 指挥官的战斗玺戒 (达萨罗, 30min)
        [166560] = true, -- 船长的指挥玺戒 (伯拉勒斯, 30min)
    },
    [INVSLOT_BACK] = {
        [65360] = true, -- 协同披风 (暴风城, 2h)
        [65274] = true, -- 协同披风 (奥格瑞玛, 2h)
        [63353] = true, -- 协作披风 (奥格瑞玛, 8h)
        [63206] = true, -- 协和披风 (暴风城, 4h)
        [63352] = true, -- 协作披风 (暴风城, 8h)
        [63207] = true, -- 协和披风 (奥格瑞玛, 4h)
    },
}
-- 手指2与手指1共用同一张表
TELEPORT_EQUIPMENT_SLOTS[INVSLOT_FINGER2] = TELEPORT_EQUIPMENT_SLOTS[INVSLOT_FINGER1]

-- ============================================================
-- 模块注册
-- ============================================================
-- 注册到模块框架，key 必须与 Init.lua defaults 表中的键名一致
-- name/description 引用本地化字符串，显示在设置面板
local module = ns.Module:Register({
    key            = "teleportUnequip",
    name           = L["TeleportUnequip_Name"],
    description    = L["TeleportUnequip_Desc"],
    tooltip        = L["TeleportUnequip_Tooltip"],
    defaultEnabled = true,
})

-- 事件 Frame：接收装备变更 / 进入世界 / 脱战 / 冷却更新事件
-- 模块禁用时解绑事件，实现零开销
local eventFrame
-- 落地时处于战斗锁定的等待标志（脱战后补执行换回）
local waitingCombatLockdown = false
-- 换回调度令牌：每次新调度使其递增，旧计时器回调比对后自动失效，
-- 避免「使用检测」与「落地检测」两条路径并发产生重复提示
local checkToken = 0
-- 当前调度链已尝试次数
local restoreAttempts = 0
local MAX_RESTORE_ATTEMPTS = 4    -- 首次尝试 + 3 次重试
local RESTORE_RETRY_DELAY = 1     -- 重试间隔（秒）
local USE_DETECT_DELAY = 1.5      -- 检测到使用后延迟换回（等待传送完成）
-- 「使用」冷却判定阈值：装备触发的冷却仅 30 秒，
-- 使用冷却为 30 分钟～8 小时（戒指 30min/1h/4h，披风 2/4/8h），
-- 超过该阈值即视为真正使用了传送
local USE_COOLDOWN_THRESHOLD = 60

-- ------------------------------------------------------------
-- GetRestoreStore: 获取当前角色的「还原目标」持久化存储表
-- ------------------------------------------------------------
-- 还原目标保存在 SavedVariables：
--   ns.db.profile.teleportUnequip.previousItems[角色名-服务器][槽位] = 装备链接
-- 按角色分键，避免多角色共用配置时互相污染；
-- 持久化后 /reload 或重新登录不再丢失还原目标。
-- ns.db 在 ADDON_LOADED 后才挂载，本模块的事件与 OnEnable 均晚于
-- 该时机触发，此处返回 nil 仅为防御异常时序
local function GetRestoreStore()
    local db = ns.db and ns.db.profile and ns.db.profile.teleportUnequip
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
-- TryRestoreTeleportEquipment: 扫描并换回传送装备
-- ------------------------------------------------------------
-- 返回 true 表示「仍穿着传送装备但暂时无法换回，需要稍后重试」。
-- 传送落地瞬间背包数据可能尚未复制到客户端，GetItemCount 会
-- 短暂返回 0，此时静默等待重试而非误报「原装备不在背包」；
-- 只有最后一次尝试仍失败时才给出对应提示。
local function TryRestoreTeleportEquipment()
    local store = GetRestoreStore()
    local needsRetry = false
    local isFinalAttempt = restoreAttempts >= MAX_RESTORE_ATTEMPTS
    for slot in pairs(TELEPORT_EQUIPMENT_SLOTS) do
        if IsTeleportEquipment(slot) then
            local currentLink = GetInventoryItemLink("player", slot)
            local previousLink = store and store[slot]
            if previousLink and GetItemCount(previousLink) > 0 then
                -- 换回传送前的装备
                -- 换回触发的装备事件会把还原目标更新为同一件装备，幂等无循环
                C_Item.EquipItemByName(previousLink, slot)
                Util:Print(L["TeleportUnequip_Restored"]:format(previousLink))
            elseif previousLink and not isFinalAttempt then
                -- 有还原记录但背包数据未就绪，稍后重试，暂不提示
                needsRetry = true
            elseif previousLink then
                -- 有还原记录但原装备已不在背包（被出售/摧毁/存入银行），无法换回
                Util:Print(L["TeleportUnequip_ItemMissing"]:format(currentLink or "?", previousLink))
            else
                -- 没有还原目标（该角色从未记录过其他装备），仅提示不动作
                Util:Print(L["TeleportUnequip_NoPrevious"]:format(currentLink or "?"))
            end
        end
    end
    return needsRetry
end

-- ------------------------------------------------------------
-- RunRestoreCheck / ScheduleRestoreCheck: 换回执行与调度
-- ------------------------------------------------------------
-- 每次调度生成新令牌，旧计时器回调比对令牌失败即退出，
-- 保证同一时刻只有一条调度链生效（落地检测与使用检测可能
-- 相继触发，后者取代前者）。
local function RunRestoreCheck(token)
    if token ~= checkToken then return end
    if InCombatLockdown() then
        -- 战斗中无法换装，标记后等待脱战
        waitingCombatLockdown = true
        return
    end
    restoreAttempts = restoreAttempts + 1
    if TryRestoreTeleportEquipment() and restoreAttempts < MAX_RESTORE_ATTEMPTS then
        C_Timer.After(RESTORE_RETRY_DELAY, function()
            RunRestoreCheck(token)
        end)
    end
end

local function ScheduleRestoreCheck(delay)
    checkToken = checkToken + 1
    restoreAttempts = 0
    local token = checkToken
    if delay and delay > 0 then
        C_Timer.After(delay, function()
            RunRestoreCheck(token)
        end)
    else
        RunRestoreCheck(token)
    end
end

-- ------------------------------------------------------------
-- CheckEquipmentUsed: 检测传送装备是否「刚被使用」
-- ------------------------------------------------------------
-- 同地图传送没有读条画面，PLAYER_ENTERING_WORLD 不会触发。
-- 使用传送装备后其冷却为 30min～8h（戒指 30min/1h/4h，披风 2/4/8h），
-- 而单纯穿上装备触发的冷却仅 30 秒，据此可区分；再通过
-- 「剩余时长接近总时长」确认冷却刚开始，排除穿着冷却中的装备时
-- 其他物品冷却更新引发的同一事件。
local function CheckEquipmentUsed()
    for slot in pairs(TELEPORT_EQUIPMENT_SLOTS) do
        if IsTeleportEquipment(slot) then
            local start, duration = GetInventoryItemCooldown("player", slot)
            if start and duration and duration > USE_COOLDOWN_THRESHOLD then
                local remaining = start + duration - GetTime()
                if remaining > duration - 3 then
                    ScheduleRestoreCheck(USE_DETECT_DELAY)
                end
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
        -- 传送/登录/reload 落地后检测（重试链覆盖背包数据未就绪的窗口）
        ScheduleRestoreCheck(0)
    elseif event == "BAG_UPDATE_COOLDOWN" then
        -- 同地图传送无读条画面，通过装备冷却刚开始判定「刚使用」
        CheckEquipmentUsed()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- 脱战后补执行因战斗锁定而推迟的换回
        if waitingCombatLockdown then
            waitingCombatLockdown = false
            ScheduleRestoreCheck(0)
        end
    end
end

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
-- 1. 创建事件 Frame（懒创建，首次启用时才创建）
-- 2. 注册装备变更 / 进入世界 / 脱战事件
-- 3. 刷新还原目标：记录当前各槽位的非传送装备
--    （若启用时正穿着传送装备则跳过记录，保留已持久化的还原目标，
--    不会把传送装备误记为还原目标）
function module:OnEnable()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEvent)
    end
    eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")

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
-- 2. 递增调度令牌使未执行的计时器回调失效，清理运行时状态标志
-- 注意：不要清空 DB 中的还原目标，持久化记录需跨会话保留
function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
    checkToken = checkToken + 1
    waitingCombatLockdown = false
end
