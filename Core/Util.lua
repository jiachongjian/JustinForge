-- ============================================================
-- JustinForge Core: 共享工具模块 (Util.lua)
-- ============================================================
-- 职责：提供跨模块复用的辅助函数，避免在各模块中重复实现
-- 当前包含：
--   1. AddToChat（内部）- 所有聊天框输出的统一入口
--   2. Print  - 带插件前缀的彩色输出（用户可见的提示信息）
--   3. Error  - 异常提示输出（红色前缀，pcall 捕获异常时调用）
--   4. Debug  - 调试日志（仅 debug 模式开启时输出）
--   5. GetItemIDFromLink - 从物品链接中提取数字物品ID
-- ============================================================

local addonName, ns = ...

-- 创建工具表并挂载到命名空间
ns.Util = {}

-- ------------------------------------------------------------
-- AddToChat: 所有聊天框输出的统一底层入口（内部函数）
-- ------------------------------------------------------------
-- 插件内任何面向聊天框的文字输出都必须经过此函数，
-- 保证输出渠道唯一，后续若要调整输出方式（如输出到指定聊天框）
-- 只需修改此处一处
-- 优先使用 DEFAULT_CHAT_FRAME:AddMessage（带颜色渲染），
-- 极端情况下（聊天框架未就绪）回退到全局 print
-- 参数 coloredMsg：已拼接好颜色码和前缀的完整字符串
local function AddToChat(coloredMsg)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(coloredMsg)
    else
        print(coloredMsg)
    end
end

-- ------------------------------------------------------------
-- Print: 带插件前缀的彩色聊天框输出
-- ------------------------------------------------------------
-- 用途：向用户展示提示信息（如模块启用/禁用、操作完成等）
-- 颜色码 |cFF4FC3F7 ... |r 是浅蓝色，与插件品牌色一致
-- 参数 msg：任意类型，通过 tostring 保证安全转换
function ns.Util:Print(msg)
    AddToChat("|cFF4FC3F7[JustinForge]|r " .. tostring(msg))
end

-- ------------------------------------------------------------
-- Error: 异常提示聊天框输出
-- ------------------------------------------------------------
-- 用途：pcall 捕获到运行时异常时向用户提示（如模块启用失败、
--   设置回调出错等），红色前缀与普通提示 Print 明显区分
-- 颜色码 |cFFFF5252 为红色，直观表达「出现了异常」
-- 参数 msg：任意类型，通过 tostring 保证安全转换
function ns.Util:Error(msg)
    AddToChat("|cFFFF5252[JustinForge 异常]|r " .. tostring(msg))
end

-- ------------------------------------------------------------
-- Debug: 调试日志输出
-- ------------------------------------------------------------
-- 用途：开发调试时输出详细状态，生产环境通过 ns.debug=false 关闭
-- 颜色码 |cFF888888 为灰色，与用户可见的 Print 区分
-- 仅当 ns.debug == true 时才输出，避免生产环境刷屏
function ns.Util:Debug(msg)
    if ns.debug then
        AddToChat("|cFF888888[JustinForge Debug]|r " .. tostring(msg))
    end
end

-- ------------------------------------------------------------
-- GetItemIDFromLink: 从物品链接提取物品ID
-- ------------------------------------------------------------
-- 物品链接格式示例：|cffffffff|Hitem:65360::::::::20|h[公会披风]|h|r
-- 其中 "item:" 后跟的数字即为物品ID
-- 使用 Lua 模式匹配 "item:(%d+)" 提取数字部分
-- 参数 link：物品链接字符串，可为 nil
-- 返回：数字类型的物品ID，或 nil（链接无效时）
function ns.Util.GetItemIDFromLink(link)
    if not link then return nil end
    local itemID = link:match("item:(%d+)")
    return itemID and tonumber(itemID)
end
