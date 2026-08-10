-- ============================================================
-- JustinForge Core: 原生设置面板 (Config.lua)
-- ============================================================
-- 职责：使用魔兽原生 Settings API 注册插件设置分类
--   1. 在「游戏设置 - 插件」中创建 AddonJustin 独立页面
--   2. 遍历模块注册表，为每个模块生成一个原生 Checkbox
--   3. 模块若在注册信息中声明了 options（如坐标滑条），
--      自动生成对应的原生控件并绑定到同一 DB 表
--   4. 控件状态与 SavedVariables 双向绑定
--   5. 用户修改时即时调用 Module:Enable/Disable 或模块的
--      OnOptionChanged 回调
--
-- 设计要点（已对照 12.0.7 客户端 UI 源码逐一核实）：
--   - Settings.RegisterVerticalLayoutCategory(name) 创建垂直布局分类
--   - Settings.RegisterAddOnSetting(category, variable, variableKey,
--       variableTbl, variableType, name, defaultValue) 注册绑定设置
--   - Settings.CreateCheckbox / Settings.CreateSlider 生成勾选框/滑条
--   - Settings.CreateSliderOptions(minValue, maxValue, rate) 的第三参数
--     是「步长」而非步数（内部 steps = (max - min) / rate），传 1 即步长 1
--   - 分组标题/按钮在 12.0 使用全局工厂函数：
--       CreateSettingsListSectionHeaderInitializer(name, tooltip)
--       CreateSettingsButtonInitializer(name, buttonText, onClick, tooltip, addSearchTags)
--     注意：Settings.CreateSectionHeaderInitializer /
--           Settings.CreateButtonInitializer 在 12.0 并不存在
--   - 12.0 起设置注册统一走 SettingsInbound 安全代理，自定义初始器
--     必须经 Settings.RegisterInitializer(category, initializer) 加入布局，
--     不要再直接调用 layout:AddInitializer
--   - 注册顺序：先创建并注册分类，再逐模块、逐控件 pcall 隔离注册。
--     任何模块的控件注册失败只会跳过该模块并聊天提示，
--     不会导致整个设置面板消失
--
-- 模块附加设置（options）约定：
--   mod.options = {
--       { type = "slider", key = "posX", name = "...", min = -960,
--         max = 960, step = 1, default = 0, tooltip = "..." },
--       -- 坐标类滑条以屏幕中心为原点（min 负、max 正，0 居中）
--       { type = "button", key = "playTest", name = "...",
--         buttonText = "播放", tooltip = "..." },
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
-- RegisterSectionHeader: 在模块控件前插入分组标题
-- ------------------------------------------------------------
-- 12.0 使用全局工厂 CreateSettingsListSectionHeaderInitializer；
-- 保留旧 API 名作为回退。工厂不可用时静默跳过（标题仅为视觉分组，
-- 不影响功能）。任何异常由调用方的 pcall 捕获
local function RegisterSectionHeader(category, mod)
    local initializer
    if CreateSettingsListSectionHeaderInitializer then
        initializer = CreateSettingsListSectionHeaderInitializer(mod.name)
    elseif Settings.CreateSectionHeaderInitializer then
        initializer = Settings.CreateSectionHeaderInitializer(mod.name)
    else
        return
    end
    -- 经 SettingsInbound 安全代理注册，不直接触碰 layout
    Settings.RegisterInitializer(category, initializer)
end

-- ------------------------------------------------------------
-- RegisterModuleOption: 为模块声明的单个附加设置生成控件
-- ------------------------------------------------------------
-- slider：数值类设置（右侧显示当前数值）
-- button：触发式按钮，优先使用原生按钮控件，
--         工厂不可用时回退为「勾选后触发并自动复位」的代理勾选框
local function RegisterModuleOption(category, mod, dbEntry, opt)
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
        -- 第三参数为步长（已核实 12.0 源码：steps = (max - min) / rate）
        local sliderOptions = Settings.CreateSliderOptions(opt.min, opt.max, opt.step or 1)
        -- 在滑条右侧显示当前数值（坐标类滑条为居中 0 的正负数）
        -- pcall 保护：Label/SetLabelFormatter 若被暴雪改动则静默退回纯滑条
        pcall(function()
            sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
                return tostring(math.floor(value + 0.5))
            end)
        end)
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
        -- 按钮类型：优先使用原生按钮控件（SettingButtonControlTemplate），
        -- 工厂 API 不可用时回退为「勾选即触发、触发后自动复位」的代理勾选框
        local function FireButton()
            if mod.OnButtonClicked then
                -- pcall 保护：按钮动作抛异常时聊天框提示
                local ok, err = pcall(mod.OnButtonClicked, mod, opt.key)
                if not ok then
                    ns.Util:Error((ns.L["Error_OptionCallback"]):format(opt.name or opt.key, tostring(err)))
                end
            end
        end

        local buttonRegistered = pcall(function()
            local initializer
            if CreateSettingsButtonInitializer then
                -- 12.0 全局工厂（第 5 个参数 addSearchTags 必传，内部有 assert 校验；
                -- 插件按钮无需进入搜索结果，传 false）
                initializer = CreateSettingsButtonInitializer(
                    opt.name, opt.buttonText or opt.name, FireButton, opt.tooltip, false)
            elseif Settings.CreateButtonInitializer then
                -- 旧版本 API 回退
                initializer = Settings.CreateButtonInitializer(
                    opt.name, opt.buttonText or opt.name, FireButton, opt.tooltip)
            else
                error("no button initializer API available")
            end
            Settings.RegisterInitializer(category, initializer)
        end)

        if not buttonRegistered then
            -- 回退方案：代理勾选框
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
                    FireButton()
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
--
-- 注册分两个阶段，每个阶段独立 pcall：
--   阶段1：创建分类并注册到插件列表 —— 保证面板入口一定出现
--   阶段2：逐模块、逐控件注册 —— 单个失败仅跳过并提示，不拖垮整体
function ns.Config:Init()
    -- 检查 Settings API 是否可用（兼容性保护）
    -- 注意必须对用户可见：静默返回会导致设置面板凭空消失且无从排查
    if not Settings or not Settings.RegisterVerticalLayoutCategory then
        ns.Util:Error(ns.L["Error_ConfigNoAPI"])
        return
    end

    -- ---- 阶段1：创建分类并注册到「设置-插件」列表 ----
    local category
    local ok, err = pcall(function()
        -- 使用垂直布局分类（原生插件设置页的标准布局）。
        -- 注意必须用 Vertical 布局：Canvas 布局只显示自定义画布 Frame，
        -- 不会渲染 CreateCheckbox/CreateSlider 注册的控件初始器
        category = Settings.RegisterVerticalLayoutCategory(ns.L["AddonTitle"])
        -- 立即注册到插件设置列表：即使后续控件注册全部失败，
        -- 面板入口依然可见（页面可能为空，但错误提示会指出原因）
        Settings.RegisterAddOnCategory(category)
    end)
    if not ok then
        ns.Util:Error((ns.L["Error_ConfigInit"]):format(tostring(err)))
        return
    end

    -- ---- 阶段2：逐模块注册控件（pcall 隔离，互不影响） ----
    for _, mod in ipairs(ns.Module:GetAll()) do
        -- 每个模块：分组标题 + 启用勾选框
        local modOk, modErr = pcall(function()
            RegisterSectionHeader(category, mod)
            local dbEntry = ns.db.profile[mod.key]
            RegisterModuleCheckbox(category, mod, dbEntry)
        end)
        if not modOk then
            ns.Util:Error((ns.L["Error_ConfigModule"]):format(mod.key, tostring(modErr)))
        end

        -- 模块的附加设置项：逐项隔离注册
        if mod.options then
            local dbEntry = ns.db.profile[mod.key]
            for _, opt in ipairs(mod.options) do
                local optOk, optErr = pcall(RegisterModuleOption, category, mod, dbEntry, opt)
                if not optOk then
                    ns.Util:Error((ns.L["Error_ConfigModule"]):format(
                        mod.key .. "." .. (opt.key or "?"), tostring(optErr)))
                end
            end
        end
    end
end
