-- ============================================================
-- JustinForge 模块4: 嗜血音乐循环 (LustMusic.lua)
-- ============================================================
-- 功能描述：
--   监控玩家身上的各类「嗜血/英勇」类增益（嗜血、英勇、时间扭曲、
--   远古狂乱、原始暴怒、守护巨龙之怒、战鼓），增益生效期间循环播放
--   指定音频 Interface\lust.ogg，增益消失后立即停止。
--   当队友开启嗜血但玩家未获得增益时（死亡/超距离/免疫等），
--   通过疲惫 DEBUFF 检测并在聊天栏提示。
--   无界面展示，无嗜血 CD 就绪音效。
--
-- 设计说明（对比 HighOnHaste / BLMusic / ExwindTools 的取舍）：
--   1. 检测目标：直接监控嗜血「增益 BUFF」本身，而非像两个参考插件
--      那样通过 10 分钟的「心满意足/疲劳」DEBUFF 反推 40 秒嗜血时间。
--      直接监控 BUFF 起止时机精确：BUFF 被点掉/提前结束时音乐立刻
--      停止，不会有残余播放；且逻辑无需关心 DEBUFF 的持续时长。
--   2. 循环方式：借鉴 HighOnHaste —— PlaySoundFile 播放后保存句柄，
--      用 C_Timer 周期检查 C_Sound.IsPlaying，播完立即补播实现循环；
--      BUFF 结束时 StopSound 带短淡出。
--   3. 疲惫 DEBUFF 补充检测：借鉴 ExwindTools —— 当玩家获得疲惫
--      DEBUFF 但没有嗜血 BUFF 时，说明队友开了嗜血而自己未吃到，
--      此时在聊天栏提示。通过 DEBUFF 剩余时间接近 600 秒判定为
--      「刚施放」，并用去重键避免对同一次 DEBUFF 重复提示。
--   4. 精简项：无覆盖层/设置页展示、无嗜血 CD 就绪音效（BLMusic 的
--      结束音）、无随机选曲、无 Ace3 依赖，仅保留「生效即循环」。
--
-- 音频文件要求：
--   将 lust.ogg 放入游戏客户端的 Interface 目录根部
--   （与 Interface\AddOns 同级），即 Interface\lust.ogg。
--   注意：WoW 仅在游戏启动时扫描文件，新增/替换该文件后需完全
--   重启游戏客户端才能生效（/reload 无效）。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

-- 音频文件路径：游戏 Interface 目录根部（非插件目录）
local SOUND_FILE = "Interface\\lust.ogg"
-- 播放声道：Master 主声道（受主音量控制）
local SOUND_CHANNEL = "Master"
-- 循环补播检测间隔（秒）：越小衔接越紧密，0.1 与 HighOnHaste 一致
local LOOP_CHECK_INTERVAL = 0.1
-- 停止时的淡出时长（毫秒），避免戛然而止的爆音感
local FADE_OUT_MS = 150

-- ============================================================
-- 嗜血类增益 BUFF 表
-- ============================================================
-- 结构：LUST_BUFFS[法术ID] = true
-- 涵盖当前正式服全部嗜血类效果；若未来版本新增同类技能
-- 在表中追加一行法术ID即可
local LUST_BUFFS = {
    [2825]   = true, -- 嗜血 (萨满-部落)
    [32182]  = true, -- 英勇 (萨满-联盟)
    [80353]  = true, -- 时间扭曲 (法师)
    [90355]  = true, -- 远古狂乱 (猎人-熔岩犬)
    [264667] = true, -- 原始暴怒 (猎人-狂野系宠物)
    [390386] = true, -- 守护巨龙之怒 (唤魔师)
    [309658] = true, -- 战鼓 (制皮)
}

-- ============================================================
-- 疲惫 DEBUFF 表（检测「队友开了嗜血但你没吃到」的补充场景）
-- ============================================================
-- 嗜血类效果施放时，所有团队成员同时获得增益 BUFF 和疲惫 DEBUFF。
-- 若玩家因死亡/超距离/免疫等原因未获得 BUFF，DEBUFF 仍会生效。
-- 通过 DEBUFF 剩余时间接近 600 秒判定为「刚施放」。
local EXHAUSTION_IDS = { 57723, 57724, 80354, 95809, 160455, 207400, 264689, 390435 }
local EXHAUSTION_DURATION = 600    -- 疲惫 DEBUFF 总时长（秒）
local FRESH_WINDOW = 5             -- 「刚施放」判定容差（秒）
local LOGIN_GRACE_PERIOD = 5       -- 登录/重载宽限期（秒），防止已有 DEBUFF 误触发

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "lustMusic",
    name           = L["LustMusic_Name"],
    description    = L["LustMusic_Desc"],
    defaultEnabled = true,
})

-- 模块附加设置：测试按钮（在设置面板中显示为自动复位的勾选框）
module.options = {
    {
        type    = "button",
        key     = "testSound",
        name    = L["LustMusic_Test"],
        tooltip = L["LustMusic_TestTip"],
    },
}

-- 事件 Frame
local eventFrame
-- 当前播放的音频句柄
local soundHandle
-- 循环补播计时器
local loopTicker
-- 嗜血 BUFF 当前是否生效
local lustActive = false
-- 疲惫 DEBUFF 检测：登录宽限期标记
local isReady = false
-- 疲惫 DEBUFF 去重键（spellID:expirationTime），避免重复提示
local lastExhaustionKey
-- 疲惫 DEBUFF 检查节流标记，避免高频 UNIT_AURA 创建过多计时器
local exhaustionCheckPending = false

-- ------------------------------------------------------------
-- HasLustBuff: 检测玩家身上是否存在任意一种嗜血类增益
-- ------------------------------------------------------------
local function HasLustBuff()
    for spellID in pairs(LUST_BUFFS) do
        if C_UnitAuras.GetPlayerAuraBySpellID(spellID) then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------
-- CheckExhaustionNotification: 疲惫 DEBUFF 补充检测
-- ------------------------------------------------------------
-- 当队友施放嗜血但玩家未获得 BUFF 时（死亡/超距离/免疫等），
-- 玩家仍会获得疲惫 DEBUFF。检测 DEBUFF 剩余时间接近 600 秒
-- 判定为「刚施放」，在聊天栏提示玩家。
-- 通过去重键（spellID:expirationTime）确保同一 DEBUFF 只提示一次。
local function CheckExhaustionNotification()
    if not isReady then return end

    for _, spellID in ipairs(EXHAUSTION_IDS) do
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
        if aura and aura.expirationTime then
            -- 12.0 secret value：光环字段受限时不可算术，pcall 保护，失败放弃本次检测
            local ok, remaining = pcall(function()
                return aura.expirationTime - GetTime()
            end)
            if not ok then return end
            if remaining >= EXHAUSTION_DURATION - FRESH_WINDOW then
                local key = spellID .. ":" .. tostring(aura.expirationTime)
                if key ~= lastExhaustionKey then
                    lastExhaustionKey = key
                    if not HasLustBuff() then
                        Util:Print(L["LustMusic_MissedLust"])
                    end
                end
                return
            end
        end
    end
end

-- ------------------------------------------------------------
-- PlayOnce: 播放一次音频并保存句柄
-- ------------------------------------------------------------
local function PlayOnce()
    local willPlay, handle = PlaySoundFile(SOUND_FILE, SOUND_CHANNEL)
    if willPlay and handle then
        soundHandle = handle
    end
end

-- ------------------------------------------------------------
-- StopLoop: 停止循环播放
-- ------------------------------------------------------------
local function StopLoop()
    if loopTicker then
        loopTicker:Cancel()
        loopTicker = nil
    end
    if soundHandle then
        StopSound(soundHandle, FADE_OUT_MS)
        soundHandle = nil
    end
end

-- ------------------------------------------------------------
-- StartLoop: 开始循环播放
-- ------------------------------------------------------------
local function StartLoop()
    StopLoop()
    PlayOnce()

    loopTicker = C_Timer.NewTicker(LOOP_CHECK_INTERVAL, function()
        if not lustActive then return end

        local playing = false
        if soundHandle and C_Sound and C_Sound.IsPlaying then
            playing = C_Sound.IsPlaying(soundHandle)
        end

        if not playing then
            PlayOnce()
        end
    end)
end

-- ------------------------------------------------------------
-- SetLustActive: 嗜血状态切换（幂等）
-- ------------------------------------------------------------
local function SetLustActive(active)
    if active == lustActive then return end
    lustActive = active

    if active then
        StartLoop()
    else
        StopLoop()
    end
end

-- ------------------------------------------------------------
-- TestPlay: 测试播放音频（供设置面板测试按钮调用）
-- ------------------------------------------------------------
local function TestPlay()
    local willPlay = PlaySoundFile(SOUND_FILE, SOUND_CHANNEL)
    if willPlay then
        Util:Print(L["LustMusic_TestSuccess"])
    else
        Util:Print(L["LustMusic_TestFailed"])
    end
end

-- ------------------------------------------------------------
-- OnEvent: 事件分发
-- ------------------------------------------------------------
local function OnEvent(_, event, arg1)
    if event == "UNIT_AURA" then
        if arg1 ~= "player" then return end
        SetLustActive(HasLustBuff())
        -- 延迟 50ms 检查疲惫 DEBUFF，等待光环数据稳定
        -- 使用 pending 标记节流，避免高频 UNIT_AURA 创建过多计时器
        if not exhaustionCheckPending then
            exhaustionCheckPending = true
            C_Timer.After(0.05, function()
                exhaustionCheckPending = false
                CheckExhaustionNotification()
            end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        SetLustActive(HasLustBuff())
        -- 登录/重载后的宽限期，防止已有 DEBUFF 误触发通知
        isReady = false
        C_Timer.After(LOGIN_GRACE_PERIOD, function()
            isReady = true
        end)
    elseif event == "PLAYER_DEAD" or event == "PLAYER_LEAVING_WORLD" then
        SetLustActive(false)
    end
end

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
function module:OnEnable()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEvent)
    end
    eventFrame:RegisterEvent("UNIT_AURA")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_DEAD")
    eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")

    -- 重置疲惫 DEBUFF 检测状态并启动宽限期
    -- PLAYER_ENTERING_WORLD 会在登录后再次触发，重新计时
    isReady = false
    lastExhaustionKey = nil
    exhaustionCheckPending = false
    C_Timer.After(LOGIN_GRACE_PERIOD, function()
        isReady = true
    end)

    SetLustActive(HasLustBuff())
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
    lustActive = false
    isReady = false
    lastExhaustionKey = nil
    exhaustionCheckPending = false
    StopLoop()
end

-- ------------------------------------------------------------
-- OnButtonClicked: 设置面板按钮回调
-- ------------------------------------------------------------
function module:OnButtonClicked(key)
    if key == "testSound" then
        TestPlay()
    end
end
