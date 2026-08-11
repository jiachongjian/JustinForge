-- ============================================================
-- JustinForge 模块4: 嗜血音效 (LustMusic.lua)
-- ============================================================
-- 功能描述：
--   监控玩家身上的「心满意足/疲劳」DEBUFF（嗜血/英勇/时间扭曲等
--   施放后附带 10 分钟疲惫 DEBUFF）。当 DEBUFF 出现且剩余时间接近
--   600 秒时判定为「嗜血刚施放」，播放 Interface\lust.ogg，
--   持续 40 秒后自动停止。DEBUFF 消失（嗜血结束）时停止音频。
--   嗜血 CD 就绪时不播放任何提醒音效。
--   无界面展示，无音频选择，只读取固定路径的 lust.ogg。
--
-- 实现逻辑（参考 BLMusic 插件，从底层重构）：
--   1. 检测方式：通过疲惫 DEBUFF 反推嗜血起止（与 BLMusic 一致）
--      - DEBUFF 出现且剩余 > 595 秒 → 嗜血刚施放 → 播放音频
--      - DEBUFF 消失 → 嗜血结束 → 停止音频
--      直接监控 BUFF 的方式在 12.0 下不可靠（光环 API 行为变动），
--      而 DEBUFF 检测经 BLMusic 长期验证稳定可靠。
--   2. 播放方式：PlaySoundFile + C_Timer.NewTimer 定时停止
--      （与 BLMusic 一致），不使用循环补播，简单可靠。
--   3. 音频来源：只读取 Interface\lust.ogg（候选路径按序探测：
--      优先插件目录，其次 Interface 根目录），无需用户选择。
--   4. 精简项：无嗜血 CD 就绪音效（结束音）、无能量灌注音效、
--      无疲惫补充检测（DEBUFF 本身即为检测机制）。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

-- ============================================================
-- 嗜血疲惫 DEBUFF 表（与 BLMusic 一致）
-- ============================================================
-- 嗜血/英勇/时间扭曲等效果施放时，所有团队成员同时获得增益 BUFF
-- 和疲惫 DEBUFF。通过检测 DEBUFF 的出现/消失来判定嗜血的起止。
local BLOODLUST_DEBUFFS = {
    [57723]  = true, -- 疲劳（联盟嗜血后）
    [57724]  = true, -- 心满意足（部落嗜血后）
    [80354]  = true, -- 时间错乱（法师时间扭曲）
    [95809]  = true, -- 癫狂（猎人远古狂乱）
    [160455] = true, -- 疲劳（猎人原始狂怒）
    [264689] = true, -- 疲劳（猎人原始狂怒变体）
    [390435] = true, -- 疲劳（唤魔师巨龙之怒）
}

-- ============================================================
-- 音频文件配置
-- ============================================================
-- lust.ogg 候选路径：优先插件目录（推荐，随插件一起被客户端扫描），
-- 其次游戏 Interface 目录根部；PlaySoundFile 对不存在的文件静默返回
-- false，因此按序探测并以首次成功为准缓存
local SOUND_FILE_CANDIDATES = {
    "Interface\\AddOns\\" .. addonName .. "\\lust.ogg",
    "Interface\\lust.ogg",
}

-- 播放声道：Master 主声道（受主音量控制）
local SOUND_CHANNEL = "Master"
-- 播放持续时间（秒），与嗜血持续时间一致
local PLAY_DURATION = 40
-- 判定「刚施放」的剩余时间阈值（秒），疲惫 DEBUFF 总时长 600 秒
local FRESH_THRESHOLD = 595

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "lustMusic",
    name           = L["LustMusic_Name"],
    description    = L["LustMusic_Desc"],
    defaultEnabled = true,
})

-- 模块附加设置：测试播放/暂停按钮（在设置面板中显示为原生按钮）
module.options = {
    {
        type       = "button",
        key        = "playTest",
        name       = L["LustMusic_Play"],
        buttonText = "播放",
        tooltip    = L["LustMusic_PlayTip"],
    },
    {
        type       = "button",
        key        = "stopTest",
        name       = L["LustMusic_Stop"],
        buttonText = "暂停",
        tooltip    = L["LustMusic_StopTip"],
    },
}

-- ============================================================
-- 状态变量
-- ============================================================
-- 事件 Frame
local eventFrame
-- 当前播放的音频句柄
local soundHandle
-- 自动停止计时器
local stopTimer
-- 当前是否有嗜血 DEBUFF
local hasBloodlust = false
-- 已成功播放的音频路径，命中后直接复用不再探测
local resolvedSoundPath
-- 本次启用期间是否已提示过文件缺失（避免每次嗜血重复刷屏）
local missingFileWarned = false

-- ============================================================
-- StopCurrentMusic: 停止当前播放的音频
-- ============================================================
local function StopCurrentMusic()
    if stopTimer then
        stopTimer:Cancel()
        stopTimer = nil
    end
    if soundHandle then
        StopSound(soundHandle)
        soundHandle = nil
    end
end

-- ============================================================
-- PlayLust: 播放 lust.ogg，PLAY_DURATION 秒后自动停止
-- ============================================================
-- 优先使用已缓存的路径；缓存失效时重新探测全部候选路径。
-- PlaySoundFile 对不存在的文件静默返回 willPlay=false，
-- 首次成功后缓存路径，后续直接复用。
local function PlayLust()
    StopCurrentMusic()

    -- 优先使用已缓存的路径
    if resolvedSoundPath then
        local _, handle = PlaySoundFile(resolvedSoundPath, SOUND_CHANNEL)
        if handle then
            soundHandle = handle
            stopTimer = C_Timer.NewTimer(PLAY_DURATION, function()
                StopCurrentMusic()
            end)
            return
        end
        -- 缓存路径失效，重新探测
        resolvedSoundPath = nil
    end

    -- 逐个尝试候选路径
    for _, path in ipairs(SOUND_FILE_CANDIDATES) do
        local _, handle = PlaySoundFile(path, SOUND_CHANNEL)
        if handle then
            resolvedSoundPath = path
            soundHandle = handle
            stopTimer = C_Timer.NewTimer(PLAY_DURATION, function()
                StopCurrentMusic()
            end)
            return
        end
    end

    -- 所有路径都失败
    if not missingFileWarned then
        missingFileWarned = true
        Util:Print(L["LustMusic_FileMissing"])
    end
end

-- ============================================================
-- CheckBloodlust: 检查是否有嗜血 DEBUFF，返回剩余时间或 nil
-- ============================================================
-- 遍历全部疲惫 DEBUFF，返回首个命中的剩余时间。
-- 12.0 secret value 保护：expirationTime 受限时不可算术，pcall 保护。
local function CheckBloodlust()
    for spellID in pairs(BLOODLUST_DEBUFFS) do
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
        if aura and aura.expirationTime then
            local ok, remaining = pcall(function()
                return aura.expirationTime - GetTime()
            end)
            if ok then
                return remaining
            end
        end
    end
    return nil
end

-- ============================================================
-- OnEvent: 事件分发
-- ============================================================
-- UNIT_AURA: 玩家光环变化时检测嗜血 DEBUFF 的出现/消失
-- PLAYER_ENTERING_WORLD: 登录/重载后初始化状态（不触发播放）
-- PLAYER_DEAD / PLAYER_LEAVING_WORLD: 立即停止音频
local function OnEvent(_, event, arg1)
    if event == "UNIT_AURA" then
        if arg1 ~= "player" then return end

        local remaining = CheckBloodlust()
        local now = remaining ~= nil
        -- 状态未变化时跳过（幂等）
        if now == hasBloodlust then return end

        hasBloodlust = now
        if now and remaining and remaining > FRESH_THRESHOLD then
            -- 嗜血刚施放（剩余时间接近 600 秒）
            PlayLust()
        elseif not now then
            -- 嗜血结束，停止音频（不播放结束音）
            StopCurrentMusic()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- 初始扫描：同步状态但不触发播放
        local remaining = CheckBloodlust()
        hasBloodlust = remaining ~= nil
    elseif event == "PLAYER_DEAD" or event == "PLAYER_LEAVING_WORLD" then
        StopCurrentMusic()
    end
end

-- ============================================================
-- OnEnable: 模块启用
-- ============================================================
function module:OnEnable()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", OnEvent)
    end
    eventFrame:RegisterEvent("UNIT_AURA")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_DEAD")
    eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")

    -- 设置面板关闭时停止试听，防止音频残留
    -- 用 C_Timer.After(0) 推迟执行，避免污染暴雪内部调用链（12.0 secret value 安全机制）
    if SettingsPanel and not module.settingsHooked then
        SettingsPanel:HookScript("OnHide", function()
            C_Timer.After(0, StopCurrentMusic)
        end)
        module.settingsHooked = true
    end

    -- 初始扫描：同步当前状态（不触发播放）
    local remaining = CheckBloodlust()
    hasBloodlust = remaining ~= nil

    -- 重置状态
    missingFileWarned = false
end

-- ============================================================
-- OnDisable: 模块禁用
-- ============================================================
function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
    StopCurrentMusic()
    hasBloodlust = false
end

-- ============================================================
-- OnButtonClicked: 设置面板按钮回调
-- ============================================================
function module:OnButtonClicked(key)
    if key == "playTest" then
        -- 重置缺失提示，允许再次报错
        missingFileWarned = false
        PlayLust()
    elseif key == "stopTest" then
        StopCurrentMusic()
    end
end
