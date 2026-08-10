-- ============================================================
-- JustinForge 模块6: 隐藏学习/遗忘消息 (ChatHideLearn.lua)
-- ============================================================
-- 功能描述：
--   在聊天窗口中隐藏系统黄字消息，如「你学会了……」
--   「你遗忘了……」等法术/技能学习提示。
--   （实现逻辑移植自 EnhanceQoL 的 chatHideLearnUnlearn）
--
-- 实现原理：
--   1. 将暴雪全局格式字符串（ERR_LEARN_SPELL_S 等）转换为
--      Lua 匹配模式（自动转义魔法字符，%s→.+，%d→%d+）
--   2. 通过 ChatFrame_AddMessageEventFilter 注册 CHAT_MSG_SYSTEM
--      事件过滤器：消息命中模式时返回 true 拦截显示
--   3. 过滤器对所有聊天框生效（暴雪对过滤后的消息不再渲染），
--      禁用时用 ChatFrame_RemoveMessageEventFilter 移除，零开销
--
-- 全局字符串依赖（暴雪内置，随客户端语言自动本地化）：
--   ERR_LEARN_PASSIVE_S   学会被动技能
--   ERR_LEARN_SPELL_S     学会法术
--   ERR_LEARN_ABILITY_S   学会技能
--   ERR_SPELL_UNLEARNED_S 遗忘法术
-- 若某字符串在当前版本不存在则跳过，不影响其余模式。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

-- 12.x 新增的秘密值检查函数（信息受限时消息内容为秘密值，不可匹配）
-- 低版本客户端不存在该函数，局部变量缓存避免每次全局查找
local issecretvalue = _G.issecretvalue

-- ============================================================
-- 模块注册
-- ============================================================
-- 注册到模块框架，key 必须与 Init.lua defaults 表中的键名一致
-- name/description 引用本地化字符串，显示在设置面板
local module = ns.Module:Register({
    key            = "chatHideLearn",
    name           = L["ChatHideLearn_Name"],
    description    = L["ChatHideLearn_Desc"],
    defaultEnabled = true,
})

-- 消息匹配模式缓存：懒构建一次后复用
local patterns

-- ------------------------------------------------------------
-- FmtToPattern: 将暴雪格式字符串转换为 Lua 匹配模式
-- ------------------------------------------------------------
-- 示例："You have learned %s." → "^You have learned .+%.$"
-- 1. 转义所有 Lua 模式魔法字符（含 % 本身，此时 %% 变成 %%%）
-- 2. 把转义后的格式占位符还原为匹配模式：%%d → %d+，%%s → .+
-- 3. 首尾锚定，避免误伤包含关键字的普通消息
local function FmtToPattern(fmt)
    local pat = fmt:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
    pat = pat:gsub("%%%%d", "%%d+") -- "%d" -> "%d+"
    pat = pat:gsub("%%%%s", ".+")   -- "%s" -> ".+"
    return "^" .. pat .. "$"
end

-- ------------------------------------------------------------
-- BuildPatterns: 构建学习/遗忘消息的匹配模式表
-- ------------------------------------------------------------
-- 全局字符串由客户端提供，已按当前语言本地化，可精确匹配系统消息
local function BuildPatterns()
    if patterns then return patterns end
    patterns = {}
    if ERR_LEARN_PASSIVE_S then table.insert(patterns, FmtToPattern(ERR_LEARN_PASSIVE_S)) end
    if ERR_LEARN_SPELL_S then table.insert(patterns, FmtToPattern(ERR_LEARN_SPELL_S)) end
    if ERR_LEARN_ABILITY_S then table.insert(patterns, FmtToPattern(ERR_LEARN_ABILITY_S)) end
    if ERR_SPELL_UNLEARNED_S then table.insert(patterns, FmtToPattern(ERR_SPELL_UNLEARNED_S)) end
    return patterns
end

-- ------------------------------------------------------------
-- ChatLearnFilter: CHAT_MSG_SYSTEM 消息过滤器
-- ------------------------------------------------------------
-- 暴雪过滤器协议：返回 true 表示拦截该消息（不显示）
-- 返回 false/nil 表示放行
local function ChatLearnFilter(_, _, msg)
    if not msg then return false end
    -- 秘密值（信息受限场景）不可做字符串匹配，直接放行
    if issecretvalue and issecretvalue(msg) then return end
    for _, pat in ipairs(BuildPatterns()) do
        if msg:match(pat) then return true end
    end
    return false
end

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
-- 构建模式表并注册聊天过滤器（对所有聊天框生效）
function module:OnEnable()
    BuildPatterns()
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", ChatLearnFilter)
    Util:Debug("ChatHideLearn: 已注册消息过滤器")
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
-- 移除过滤器，实现零开销
function module:OnDisable()
    ChatFrame_RemoveMessageEventFilter("CHAT_MSG_SYSTEM", ChatLearnFilter)
    Util:Debug("ChatHideLearn: 已移除消息过滤器")
end
