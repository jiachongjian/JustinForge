-- ============================================================
-- JustinForge Core: 原生设置面板 (Config.lua)
-- ============================================================
-- 职责：使用魔兽 10.0+ 原生 Settings API 注册插件设置分类
--   1. 在「游戏设置 - 插件」中创建 JustinForge 独立页面
--   2. 遍历模块注册表，为每个模块生成一个原生 Checkbox
--   3. Checkbox 状态与 SavedVariables 双向绑定
--   4. 用户勾选/取消勾选时即时调用 Module:Enable/Disable
--
-- 设计要点：
--   - 使用原生 Settings API 而非 AceConfig，UI 与系统原生一致
--   - 遍历注册表自动生成，新增模块无需修改此文件
--   - pcall 包裹注册逻辑，防止 API 变动导致插件加载失败
-- ============================================================

local addonName, ns = ...

ns.Config = {}

-- ------------------------------------------------------------
-- Init: 初始化设置面板
-- ------------------------------------------------------------
-- 在 ADDON_LOADED 后由 Init.lua 调用
-- 此时所有模块已注册完毕，可遍历注册表生成勾选项
function ns.Config:Init()
    -- 检查 Settings API 是否可用（兼容性保护）
    if not Settings or not Settings.RegisterCanvasLayoutCategory then
        ns.Util:Debug("Settings API not available")
        return
    end

    -- 使用 pcall 包裹整个注册流程，防止 API 参数变化导致插件加载中断
    local ok, err = pcall(function()
        local title = ns.L["AddonTitle"]

        -- 注册一个 Canvas 布局的设置分类（原生插件设置页的标准布局）
        -- 第一个参数：分类的唯一标识（内部 ID）
        -- 第二个参数：显示名称（出现在设置面板左侧列表）
        local category = Settings.RegisterCanvasLayoutCategory(title, title)

        -- 遍历所有已注册模块，为每个模块生成一个 Checkbox
        for _, mod in ipairs(ns.Module:GetAll()) do
            local dbEntry = ns.db.profile[mod.key]

            -- 注册一个插件设置项（Checkbox 类型）
            -- 参数说明：
            --   category    所属分类
            --   mod.key     设置项的唯一标识（与模块 key 一致）
            --   mod.key     显示名称键（此处复用 key，实际显示用 mod.name）
            --   addonName   所属插件名
            --   dbEntry     绑定的数据表（DB.profile[mod.key]）
            --   "enabled"   数据表中的字段名（绑定 dbEntry.enabled）
            --   Settings.CreateCheckbox  创建 Checkbox 控件
            --     mod.name        Checkbox 标签文字
            --     mod.description Checkbox 下方描述
            local setting = Settings.RegisterAddOnSetting(
                category,
                mod.key,
                mod.key,
                addonName,
                dbEntry,
                "enabled",
                Settings.CreateCheckbox(mod.name, mod.description)
            )

            -- 设置值变化回调：用户勾选/取消勾选时即时响应
            -- 参数 value 为布尔值，表示 Checkbox 新状态
            -- true  → 启用模块（注册事件/Hook）
            -- false → 禁用模块（解绑事件/Hook，零开销）
            setting:SetValueChangedCallback(function(_, value)
                if value then
                    ns.Module:Enable(mod.key)
                else
                    ns.Module:Disable(mod.key)
                end
            end)
        end

        -- 将分类注册到插件设置列表，使其在「设置-插件」中可见
        Settings.RegisterAddOnCategory(category)
    end)

    -- 若注册过程出错，输出调试日志但不中断插件运行
    if not ok then
        ns.Util:Debug("Config init failed: " .. tostring(err))
    end
end
