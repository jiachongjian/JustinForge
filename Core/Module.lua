-- ============================================================
-- JustinForge Core: 模块注册表框架 (Module.lua)
-- ============================================================
-- 职责：提供统一的模块注册/启用/禁用接口，实现：
--   1. 模块注册：各功能模块调用 Register 将自身信息登记到注册表
--   2. 按需启用/禁用：根据用户设置开关，调用模块的 OnEnable/OnDisable
--   3. 零开销禁用：禁用模块时解绑所有事件和 Hook，不占用任何运行时资源
--   4. 设置面板自动生成：Config.lua 遍历注册表为每个模块生成勾选项
--
-- 模块统一接口约定（每个模块需实现）：
--   info.key            模块唯一标识（与 DB.profile 的键名对应）
--   info.name           显示名称（本地化字符串）
--   info.description    功能描述（本地化字符串）
--   info.defaultEnabled 默认是否启用
--   info.OnEnable()     启用时调用：注册事件、Hook 框架
--   info.OnDisable()    禁用时调用：解绑事件、Hook，清理状态
--
-- 新增功能流程：
--   1. 在 Modules/ 新建一个 .lua 文件
--   2. 调用 ns.Module:Register({...}) 注册模块信息
--   3. 实现 OnEnable / OnDisable 方法
--   4. 在 Init.lua 的 defaults 表和 zhCN.lua 添加对应配置和字符串
--   5. 在 TOC 文件添加加载行
--   设置面板会自动出现该模块的勾选项，无需修改 Config.lua
-- ============================================================

local addonName, ns = ...

ns.Module = {}

-- modules: 以 key 为键存储模块信息表，支持 O(1) 查找
local modules = {}
-- order: 以注册顺序存储 key，用于遍历时保持稳定顺序（设置面板显示顺序）
local order = {}

-- ------------------------------------------------------------
-- Register: 注册一个新模块
-- ------------------------------------------------------------
-- 参数 info：模块信息表，必须包含 key 字段
-- 将模块存入 modules 表和 order 列表
-- 初始化 enabled = false（实际启用由 EnableAll/Enable 根据配置决定）
function ns.Module:Register(info)
    if not info or not info.key then
        error("Module:Register requires a 'key' field")
    end
    modules[info.key] = info
    table.insert(order, info.key)
    info.enabled = false
    -- 返回 info 供调用方继续添加方法（如 function module:OnEnable() ... end）
    return info
end

-- ------------------------------------------------------------
-- Enable: 启用指定模块
-- ------------------------------------------------------------
-- 流程：
--   1. 查找模块，若已启用则跳过（幂等）
--   2. 标记 enabled = true
--   3. 同步状态到 SavedVariables（持久化用户选择）
--   4. 调用模块的 OnEnable 方法（注册事件/Hook）
-- 参数 key：模块标识
function ns.Module:Enable(key)
    local mod = modules[key]
    if not mod then return end
    if mod.enabled then return end  -- 已启用，避免重复初始化
    mod.enabled = true
    -- 将启用状态写入 DB，下次登录时自动恢复
    if ns.db and ns.db.profile and ns.db.profile[key] then
        ns.db.profile[key].enabled = true
    end
    -- 调用模块的启用逻辑（注册事件、Hook 框架等）
    if mod.OnEnable then
        mod:OnEnable()
    end
    ns.Util:Debug("Module enabled: " .. key)
end

-- ------------------------------------------------------------
-- Disable: 禁用指定模块
-- ------------------------------------------------------------
-- 流程与 Enable 对称：
--   1. 查找模块，若已禁用则跳过
--   2. 标记 enabled = false
--   3. 同步状态到 SavedVariables
--   4. 调用 OnDisable（解绑事件/Hook，实现零开销）
function ns.Module:Disable(key)
    local mod = modules[key]
    if not mod then return end
    if not mod.enabled then return end  -- 已禁用，跳过
    mod.enabled = false
    if ns.db and ns.db.profile and ns.db.profile[key] then
        ns.db.profile[key].enabled = false
    end
    -- 调用模块的禁用逻辑（解绑事件、清理状态）
    if mod.OnDisable then
        mod:OnDisable()
    end
    ns.Util:Debug("Module disabled: " .. key)
end

-- ------------------------------------------------------------
-- EnableAll: 根据保存的配置批量启用模块
-- ------------------------------------------------------------
-- 在 ADDON_LOADED 后由 Init.lua 调用
-- 遍历所有已注册模块，读取 DB 中的 enabled 字段：
--   - true  调用 OnEnable 启用
--   - false 保持禁用状态（不调用 OnEnable，零开销）
-- 使用 order 列表保证按注册顺序处理
function ns.Module:EnableAll()
    for _, key in ipairs(order) do
        local mod = modules[key]
        local dbEntry = ns.db and ns.db.profile and ns.db.profile[key]
        if dbEntry and dbEntry.enabled then
            mod.enabled = true
            if mod.OnEnable then
                mod:OnEnable()
            end
            ns.Util:Debug("Module enabled: " .. key)
        else
            mod.enabled = false
        end
    end
end

-- ------------------------------------------------------------
-- GetAll: 获取所有已注册模块（按注册顺序）
-- ------------------------------------------------------------
-- 用途：Config.lua 遍历此列表，为每个模块生成设置面板的 Checkbox
-- 返回：模块信息表的数组（顺序与注册顺序一致）
function ns.Module:GetAll()
    local result = {}
    for _, key in ipairs(order) do
        table.insert(result, modules[key])
    end
    return result
end

-- ------------------------------------------------------------
-- Get: 按 key 获取单个模块
-- ------------------------------------------------------------
-- 用途：其他模块或调试时按标识查找模块
-- 返回：模块信息表，或 nil（不存在）
function ns.Module:Get(key)
    return modules[key]
end
