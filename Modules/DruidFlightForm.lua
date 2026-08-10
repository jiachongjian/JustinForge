-- ============================================================
-- JustinForge 模块5: 德鲁伊自动取消旅行形态 (DruidFlightForm.lua)
-- ============================================================
-- 功能描述：
--   德鲁伊处于旅行形态（变形ID 3）时，进入可飞行区域后自动取消
--   变形，以便重新施放旅行形态自动切换为飞行形态。
--   （实现逻辑移植自 EnhanceQoL 的 autoCancelDruidFlightForm）
--
-- 实现原理：
--   1. 仅在玩家职业为德鲁伊时工作，其他职业启用后零开销
--   2. 监听 MOUNT_JOURNAL_USABILITY_CHANGED 事件：
--      该事件在坐骑/飞行可用性变化时触发，覆盖「步行进入可飞行
--      区域」这一场景，无需轮询
--   3. 触发时检查：当前变形ID == 3（旅行形态）且 IsFlyableArea()
--      为真，则调用 CancelShapeshiftForm() 取消变形
--   4. 若处于战斗锁定（战斗中无法安全取消变形），设置挂起标志，
--      等待 PLAYER_REGEN_ENABLED 脱战后补执行
--
-- 为什么只取消不自动变身：
--   取消变形后，玩家再次按键施放旅行形态时会自动根据区域判定
--   变为飞行形态；自动施法需要安全硬件事件（按键/点击），插件
--   无法直接代劳，因此只负责「取消」这一步。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

-- 旅行形态的变形ID（GetShapeshiftFormID 返回值）
-- 3 = Travel Form（旅行形态，地面/飞行/水生三合一前的通用形态）
local TRAVEL_FORM_ID = 3

-- ============================================================
-- 模块注册
-- ============================================================
-- 注册到模块框架，key 必须与 Init.lua defaults 表中的键名一致
-- name/description 引用本地化字符串，显示在设置面板
local module = ns.Module:Register({
    key            = "druidFlightForm",
    name           = L["DruidFlightForm_Name"],
    description    = L["DruidFlightForm_Desc"],
    defaultEnabled = true,
})

-- 事件 Frame：接收飞行可用性变化 / 脱战事件
-- 模块禁用时解绑事件，实现零开销
local eventFrame
-- 战斗锁定的挂起标志：脱战后补执行取消变形
local pendingCancel = false

-- ------------------------------------------------------------
-- IsPlayerDruid: 判断玩家是否为德鲁伊
-- ------------------------------------------------------------
-- select(2, UnitClass) 返回英文大写职业标识（不受语言影响）
local function IsPlayerDruid()
    local _, classTag = UnitClass("player")
    return classTag == "DRUID"
end

-- ------------------------------------------------------------
-- EvaluateFlightForm: 检查并取消旅行形态
-- ------------------------------------------------------------
-- 触发条件：旅行形态 + 可飞行区域
-- 战斗中设置 pendingCancel 挂起，待脱战后补执行
local function EvaluateFlightForm()
    -- 防御性检查：API 不存在时直接放弃（如版本变动）
    if not GetShapeshiftFormID or not IsFlyableArea or not CancelShapeshiftForm then return end

    if GetShapeshiftFormID() == TRAVEL_FORM_ID and IsFlyableArea() then
        if InCombatLockdown() then
            -- 战斗中无法安全取消变形，标记后等待脱战
            pendingCancel = true
            return
        end
        pendingCancel = false
        CancelShapeshiftForm()
        Util:Debug("DruidFlightForm: 已取消旅行形态（可飞行区域）")
    else
        pendingCancel = false
    end
end

-- ------------------------------------------------------------
-- OnEvent: 事件分发
-- ------------------------------------------------------------
local function OnEvent(_, event)
    if event == "MOUNT_JOURNAL_USABILITY_CHANGED" then
        -- 飞行可用性变化（如步行进入可飞行区域）时评估
        EvaluateFlightForm()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- 脱战后补执行因战斗锁定而推迟的取消变形
        if pendingCancel then
            EvaluateFlightForm()
        end
    end
end

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
-- 1. 非德鲁伊职业直接跳过（不注册任何事件，零开销）
-- 2. 创建事件 Frame（懒创建，首次启用时才创建）
-- 3. 注册飞行可用性变化 / 脱战事件
-- 4. 立即评估一次（启用时已处于旅行形态的场景）
function module:OnEnable()
    if not IsPlayerDruid() then return end

    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEvent)
    end
    eventFrame:RegisterEvent("MOUNT_JOURNAL_USABILITY_CHANGED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

    -- 启用瞬间若已在旅行形态且处于可飞行区域，立即处理
    EvaluateFlightForm()
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
-- 1. 解绑所有事件（实现零开销）
-- 2. 清理挂起标志，避免下次启用时残留旧状态
function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
    pendingCancel = false
end
