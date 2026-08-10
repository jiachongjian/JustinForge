-- ============================================================
-- JustinForge Core: 初始化模块 (Init.lua)
-- ============================================================
-- 职责：
--   1. 创建插件命名空间 ns（贯穿所有文件的共享表，避免污染全局环境）
--   2. 定义默认配置表（用户首次使用或配置缺失时填充默认值）
--   3. 监听 ADDON_LOADED 事件，在插件加载完成时：
--      a) 读取持久化的 SavedVariables (JustinForgeDB)
--      b) 将默认值合并到用户配置中（仅填充缺失键，不覆盖用户已有设置）
--      c) 根据保存的开关状态启用所有已注册模块
--      d) 初始化原生设置面板
-- ============================================================

-- addonName = "JustinForge"，ns = 贯穿所有文件的命名空间表
-- Lua 的 ... 机制：TOC 中每个文件加载时， Blizzard 会传入 (addonName, nsTable)
local addonName, ns = ...

-- 插件版本号，可用于后续更新检测或日志展示
ns.version = "1.0.0"
-- 调试模式开关：true 时 ns.Util:Debug 会输出日志，生产环境设为 false
ns.debug = false

-- ============================================================
-- 默认配置表
-- ============================================================
-- 结构与 SavedVariables (JustinForgeDB) 一致
-- 每个模块对应 profile 下的一个键，键名与模块的 key 字段一致
-- enabled = true 表示该模块默认启用
-- 新增模块时在此处添加一行默认配置，键名需与 Module:Register 中的 key 完全一致
-- 坐标类设置项以屏幕中心为原点（0 居中，左/下为负，右/上为正）
local screenWidth = math.floor(UIParent:GetWidth() or 1920)
local screenHeight = math.floor(UIParent:GetHeight() or 1080)
local defaults = {
    profile = {
        guildCloak      = { enabled = true },  -- 功能1：公会披风自动还原
        mapCenter       = { enabled = true },  -- 功能2：地图窗口居中
        -- 功能3：商人窗口扩展（columns 为物品显示列数，范围 2-5）
        merchantExpand  = { enabled = true, columns = 4 },
        lustMusic       = { enabled = true },  -- 功能4：嗜血音乐循环
        druidFlightForm = { enabled = true },  -- 功能5：德鲁伊自动取消旅行形态
        chatHideLearn   = { enabled = true },  -- 功能6：隐藏学习/遗忘消息
        macroEnhance    = { enabled = true },  -- 功能7：宏界面增强
        -- 功能8：聊天频道快捷栏（posX/posY 为相对屏幕中心的偏移，默认左下角附近）
        chatChannelBar  = { enabled = true,
            posX = 46 - math.floor(screenWidth / 2), posY = 207 - math.floor(screenHeight / 2) },
        -- 功能9：人物属性面板（posX/posY 为相对屏幕中心的偏移，默认屏幕左侧中部）
        characterStats  = { enabled = true, posX = 20 - math.floor(screenWidth / 2), posY = 0 },
        -- 功能10：虫洞抽屉（宏由玩家手动创建，内容为 /click JFDrawerBtn1）
        drawerMacro     = { enabled = true },
        -- 功能11：鼠标提示大秘境信息（评分/钥石/各副本最佳成绩）
        mythicPlusTooltip = { enabled = true },
        hideCrafter     = { enabled = true },  -- 功能12：隐藏制造业制造者
        quickFocus      = { enabled = true },  -- 功能13：Shift+右键快速焦点
    },
}

-- ============================================================
-- 递归合并默认值到用户配置表
-- ============================================================
-- 作用：仅填充用户配置中缺失的键，不覆盖用户已设置的值
-- 例如用户曾禁用某模块，重新登录时不会因默认值而被重置为启用
-- 参数：
--   db       用户当前的 SavedVariables 表（会被原地修改）
--   defaults 默认配置表
-- 逻辑：
--   - 若 defaults[k] 是表，则递归进入子表（确保嵌套结构存在）
--   - 若 defaults[k] 是标量，仅当 db[k] == nil 时才赋值
local function mergeDefaults(db, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            -- 子表不存在则创建空表
            if db[k] == nil then
                db[k] = {}
            end
            -- 仅当子表也是 table 时递归（防止用户数据类型异常）
            if type(db[k]) == "table" then
                mergeDefaults(db[k], v)
            end
        else
            -- 标量值：仅当缺失时填充默认值
            if db[k] == nil then
                db[k] = v
            end
        end
    end
end

-- ============================================================
-- ADDON_LOADED 事件处理
-- ============================================================
-- 创建一个隐藏的 Frame 用于接收事件（Frame 是 WoW 中接收事件的唯一载体）
-- ADDON_LOADED 在插件及其 SavedVariables 全部加载完成后触发
-- 参数 loadedAddon 为刚加载的插件名，需过滤只处理本插件
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(self, event, loadedAddon)
    -- 只处理本插件的加载事件（其他插件加载时也会触发此事件）
    if loadedAddon ~= addonName then return end

    -- 本插件已加载完成，取消事件监听以避免重复处理（一次性事件）
    self:UnregisterEvent("ADDON_LOADED")

    -- ---- 步骤1：加载 SavedVariables ----
    -- JustinForgeDB 是全局变量，由客户端在 ADDON_LOADED 前从磁盘读取并注入
    -- 首次使用时该变量不存在，需初始化为空表
    if not JustinForgeDB then
        JustinForgeDB = {}
    end
    if not JustinForgeDB.profile then
        JustinForgeDB.profile = {}
    end
    -- 合并默认值：确保所有模块的配置键都存在
    mergeDefaults(JustinForgeDB, defaults)

    -- 将全局 DB 引用挂载到命名空间，供其他模块读写
    ns.db = JustinForgeDB

    -- ---- 步骤2：根据保存的开关状态启用模块 ----
    -- 此时 Module.lua 已加载（TOC 顺序在 Init 之后），注册表框架就绪
    -- EnableAll 会遍历所有已注册模块，按 DB 中的 enabled 字段决定是否调用 OnEnable
    -- pcall 保护：单个模块的异常已在 Module.lua 内部捕获提示，
    -- 此处兜底框架级异常（如 DB 结构损坏），防止中断后续设置面板初始化
    if ns.Module then
        local ok, err = pcall(function() ns.Module:EnableAll() end)
        if not ok then
            ns.Util:Error(((ns.L and ns.L["Error_Init"]) or "插件初始化过程中发生异常：%s"):format(tostring(err)))
        end
    end

    -- ---- 步骤3：初始化设置面板 ----
    -- Config.lua 最后加载，此时所有模块已注册完毕
    -- Init 会遍历模块注册表，为每个模块生成一个原生 Checkbox
    -- pcall 保护：Config:Init 内部已有捕获提示，此处兜底其外层异常
    if ns.Config then
        local ok, err = pcall(function() ns.Config:Init() end)
        if not ok then
            ns.Util:Error(((ns.L and ns.L["Error_Init"]) or "插件初始化过程中发生异常：%s"):format(tostring(err)))
        end
    end
end)
