-- ============================================================
-- JustinForge Core: 原生设置面板 (Config.lua)
-- ============================================================
-- 职责：使用魔兽原生 Settings API 注册插件设置分类
--   1. 在「游戏设置 - 插件」中创建 JustinForge 独立页面
--   2. 遍历模块注册表，为每个模块生成一个原生 Checkbox
--   3. 模块若在注册信息中声明了 options（如坐标滑条），
--      自动生成对应的原生控件并绑定到同一 DB 表
--   4. 控件状态与 SavedVariables 双向绑定
--   5. 用户修改时即时调用 Module:Enable/Disable 或模块的
--      OnOptionChanged 回调
--
-- 设计要点：
--   - 使用 11.0+ 重构后的新签名：
--       Settings.RegisterAddOnSetting(category, variable, variableKey,
--           variableTbl, variableType, name, defaultValue)
--       Settings.CreateCheckbox(category, setting, tooltip)
--       Settings.CreateSlider(category, setting, options, tooltip)
--     （旧的「控件工厂」签名已在 11.0 移除，请勿回退）
--   - 遍历注册表自动生成，新增模块无需修改此文件
--   - pcall 包裹注册逻辑，防止 API 变动导致插件加载失败
--
-- 模块附加设置（options）约定：
--   mod.options = {
--       { type = "slider", key = "posX", name = "...", min = 0,
--         max = 2000, step = 1, default = 46, tooltip = "..." },
--   }
--   值绑定到 DB.profile[mod.key][opt.key]，变化时回调
--   mod:OnOptionChanged(opt.key, value)（模块可自行实现）
-- ============================================================

local addonName, ns = ...

ns.Config = {}

-- ------------------------------------------------------------
-- RegisterModuleCheckbox: 为模块生成启用/禁用 Checkbox
-- ------------------------------------------------------------
-- 绑定 DB.profile[mod.key].enabled，变化时即时启用/禁用模块
local function RegisterModuleCheckbox(category, mod, dbEntry)
    local setting = Settings.RegisterAddOnSetting(
        category,
        "JustinForge." .. mod.key,     -- variable：设置项唯一标识（带插件前缀，防跨插件撞名）
        "enabled",                     -- variableKey：dbEntry 中的字段名
        dbEntry,                       -- variableTbl：实际存储表
        Settings.VarType.Boolean,
        mod.name,
        mod.defaultEnabled and true or false
    )
    Settings.CreateCheckbox(category, setting, mod.description)

    -- 勾选/取消勾选时即时响应
    setting:SetValueChangedCallback(function(_, value)
        if value then
            ns.Module:Enable(mod.key)
        else
            ns.Module:Disable(mod.key)
        end
    end)
end

-- ------------------------------------------------------------
-- RegisterModuleOptions: 为模块声明的附加设置生成控件
-- ------------------------------------------------------------
-- 支持 slider（数值类设置）和 button（触发式按钮）
-- button 类型使用代理勾选框实现：勾选后触发回调并自动复位
local function RegisterModuleOptions(category, mod, dbEntry)
    if not mod.options then return end

    for _, opt in ipairs(mod.options) do
        if opt.type == "slider" then
            local setting = Settings.RegisterAddOnSetting(
                category,
                "JustinForge." .. mod.key .. "." .. opt.key, -- variable：带插件+模块前缀避免冲突
                opt.key,                   -- variableKey：dbEntry 中的字段名
                dbEntry,
                Settings.VarType.Number,
                opt.name,
                opt.default
            )
            local sliderOptions = Settings.CreateSliderOptions(opt.min, opt.max, opt.step or 1)
            Settings.CreateSlider(category, setting, sliderOptions, opt.tooltip)

            -- 滑条变化时通知模块（值已由绑定写入 dbEntry）
            -- pcall 保护：模块回调抛异常时聊天框提示，不影响设置面板本身
            setting:SetValueChangedCallback(function(_, value)
                if mod.OnOptionChanged then
                    local ok, err = pcall(mod.OnOptionChanged, mod, opt.key, value)
                    if not ok then
                        ns.Util:Error((ns.L["Error_OptionCallback"]):format(opt.name or opt.key, tostring(err)))
                    end
                end
            end)
        elseif opt.type == "button" then
            -- 按钮类型：用代理勾选框模拟，勾选即触发、触发后自动复位
            local setting = Settings.RegisterAddOnSetting(
                category,
                "JustinForge." .. mod.key .. "." .. opt.key,
                opt.key,
                dbEntry,
                Settings.VarType.Boolean,
                opt.name,
                false
            )
            Settings.CreateCheckbox(category, setting, opt.tooltip)

            setting:SetValueChangedCallback(function(_, value)
                if value then
                    if mod.OnButtonClicked then
                        -- pcall 保护：按钮动作抛异常时聊天框提示
                        local ok, err = pcall(mod.OnButtonClicked, mod, opt.key)
                        if not ok then
                            ns.Util:Error((ns.L["Error_OptionCallback"]):format(opt.name or opt.key, tostring(err)))
                        end
                    end
                    -- 延迟到下一帧复位勾选框，避免与当前值变更事件冲突
                    C_Timer.After(0, function()
                        setting:SetValue(false)
                    end)
                end
            end)
        end
    end
end

-- ------------------------------------------------------------
-- Init: 初始化设置面板
-- ------------------------------------------------------------
-- 在 ADDON_LOADED 后由 Init.lua 调用
-- 此时所有模块已注册完毕，可遍历注册表生成勾选项
function ns.Config:Init()
    -- 检查 Settings API 是否可用（兼容性保护）
    if not Settings or not Settings.RegisterVerticalLayoutCategory then
        ns.Util:Debug("Settings API not available")
        return
    end

    -- 使用 pcall 包裹整个注册流程，防止 API 参数变化导致插件加载中断
    local ok, err = pcall(function()
        local title = ns.L["AddonTitle"]

        -- 注册一个垂直布局的设置分类（原生插件设置页的标准布局）
        -- 注意必须用 Vertical 布局：Canvas 布局只显示自定义画布 Frame，
        -- 不会渲染 CreateCheckbox/CreateSlider 注册的控件初始器
        -- 参数：显示名称（出现在设置面板左侧列表）
        local category = Settings.RegisterVerticalLayoutCategory(title)

        -- 遍历所有已注册模块，为每个模块生成 Checkbox 及附加设置控件
        for _, mod in ipairs(ns.Module:GetAll()) do
            local dbEntry = ns.db.profile[mod.key]
            RegisterModuleCheckbox(category, mod, dbEntry)
            RegisterModuleOptions(category, mod, dbEntry)
        end

        -- 将分类注册到插件设置列表，使其在「设置-插件」中可见
        Settings.RegisterAddOnCategory(category)
    end)

    -- 若注册过程出错，对用户可见提示一次（静默失败会导致设置面板消失且无从排查）
    if not ok then
        ns.Util:Error((ns.L["Error_ConfigInit"]):format(tostring(err)))
    end
end
