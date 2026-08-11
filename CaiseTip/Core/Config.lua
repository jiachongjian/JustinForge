----------------------------------------------------------------------
-- CaiseTip / Core / Config
-- 设置面板
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

-- Lua standard library
local pairs = pairs
local type = type

-- WoW global API
local print = print

-- ==================== 配置初始化 ====================
-- 默认配置
local defaults = {
    -- 显示设置
    showTitle = true,
    showServer = true,
    showGuild = true,
    showMount = true,
    showMountSource = true,
    showRank = true,
    showRankIndex = false,
    showMythicScore = true,
    mythicDungeonMode = "ALWAYS",
    mythicDungeonModifier = "CTRL",
    -- 玩家信息显示
    showItemLevel = true,
    showFactionIcon = "ALWAYS",
    showShadow = true,
    showHealthBar = true,
    showHealthText = true,
    healthTextMode = "CURRENT_MAX_PERCENT",
    healthNumberStyle = "AUTO",
    friendlyHealthColor = "ff19ff19",
    hideinCombat = false,

    -- 位置设置
    anchor = "RIGHT",
    combatFollow = false,

    -- 基准偏移（各方向的默认位置）
    baseOffset = {
        NONE      = { x = 0, y = 0 },
        RIGHT     = { x = 20, y = 20 },
        LEFT      = { x = -20, y = 20 },
        TOP       = { x = 0, y = 10 },   -- 好像无法调整位置
        CURSOR_BR = { x = 40, y = -30 }, -- 动态跟随右下
    },

    -- 缩放设置
    scale = 1.0,

    -- 字体设置
    hfontSize = 18,               -- 标题字体大小
    fontSize = 16,                -- 正文字体大小
    sfontSize = 14,               -- 小字体大小
    healthFontSize = 11,          -- 生命值文本字体大小
    fontOutline = "THICKOUTLINE", -- 字体描边 "OUTLINE"，"THICKOUTLINE"，"NONE"
    hpfontOutline = "THICKOUTLINE",

    -- ID 显示设置
    showIDs = true,
    showItemInfo = false,

    -- 公会显示设置
    showFullGuildWithModifier = true,
    showGuildRealm = true,
    guildModifier = "CTRL",

    -- 外观设置
    bgColor = "ff000000",
    bgAlpha = 0.7,
    borderStyle = "PIXEL",
    itemLevelColorLow = "ffb0b0b0",
    itemLevelColorGreen = "ff1eff00",
    itemLevelColorBlue = "ff0070dd",
    itemLevelColorPurple = "ffa335ee",
    itemLevelColorOrange = "ffff8000",

    -- 品质边框着色
    enableQualityBorder = true,

    -- 启用默认渐隐（关闭时提示框立即消失）
    enableDefaultFade = false,

    debug = false,
}

--- 深合并表
local function MergeDefaults(target, source)
    for k, v in pairs(source) do
        if type(v) == "table" then
            if target[k] == nil then
                target[k] = {}
            end
            MergeDefaults(target[k], v)
        else
            if target[k] == nil then
                target[k] = v
            end
        end
    end

    -- 删除多余字段（包括嵌套）
    for k in pairs(target) do
        if source[k] == nil then
            target[k] = nil
        elseif type(source[k]) == "table" and type(target[k]) == "table" then
            -- 递归删除子表中的多余字段
            MergeDefaults(target[k], source[k])
        end
    end
end

function P:LoadConfig()
    CaiseTipDB = CaiseTipDB or {}
    MergeDefaults(CaiseTipDB, defaults)
    self.db = CaiseTipDB
end


-- 依赖关系表
local dependencies = {
    anchor = {
        -- 第一个条件组：控制三个子项
        {
            children = { "offsetX", "offsetY" },
            enabled = function() return P.db.anchor ~= "NONE" end
        },
        -- 第二个条件组：控制两个子项
        {
            children = { "offsetX", "offsetY" },
            enabled = function() return P.db.anchor ~= "TOP" end
        }
    },
    showFullGuildWithModifier = {
        {
            children = { "guildModifier" },
            enabled = function() return P.db.showFullGuildWithModifier == true end
        }
    },
    showItemLevel = {
        {
            children = {
                "itemLevelColorLow",
                "itemLevelColorGreen",
                "itemLevelColorBlue",
                "itemLevelColorPurple",
                "itemLevelColorOrange",
            },
            enabled = function() return P.db.showItemLevel == true end
        }
    },
    showGuild = {
        {
            children = { "showRank", "showRankIndex", "showFullGuildWithModifier", "showGuildRealm", "guildModifier" },
            enabled = function() return P.db.showGuild == true end
        }
    },
    showHealthBar = {
        {
            children = { "showHealthText", "healthTextMode", "healthFontSize", "hpfontOutline", "friendlyHealthColor" },
            enabled = function() return P.db.showHealthBar == true end
        }
    },
    showHealthText = {
        {
            children = { "healthTextMode", "healthFontSize", "hpfontOutline" },
            enabled = function() return P.db.showHealthText == true end
        }
    },
    showMount = {
        {
            children = { "showMountSource" },
            enabled = function() return P.db.showMount == true end
        }
    },
    showMythicScore = {
        {
            children = { "mythicDungeonMode", "mythicDungeonModifier" },
            enabled = function() return P.db.showMythicScore == true end
        }
    },
    showRank = {
        {
            children = { "showRankIndex" },
            enabled = function() return P.db.showRank == true end
        }
    },
    mythicDungeonMode = {
        {
            children = { "mythicDungeonModifier" },
            enabled = function() return P.db.mythicDungeonMode == "MODIFIER" end
        }
    }
}

local function createOffsetGetter(axis) -- axis = "x" 或 "y"
    return function()
        local anchor = P.db.anchor or "NONE"
        local base = P.db.baseOffset[anchor] or P.db.baseOffset.NONE
        return base[axis]
    end
end

local function createOffsetSetter(axis)
    return function(value)
        local anchor = P.db.anchor or "NONE"
        -- 确保 baseOffset[anchor] 存在
        if not P.db.baseOffset[anchor] then
            P.db.baseOffset[anchor] = { x = 0, y = 0 }
        end
        -- 更新对应方向的值
        P.db.baseOffset[anchor][axis] = value
    end
end

-- 选项表（纯数据）
local Options = {
    -- 一般设置分组
    {
        type = "header",
        key = "generalHeader",
        name = L["一般设置"],
        --tooltip = nil,  -- 标题不需要提示
    },
    -- 基础显示
    {
        type = "dropdown",
        key = "borderStyle",
        name = L["边框样式"],
        default = "PIXEL",
        tooltip = L["选择提示框的边框风格。"],
        options = function()
            local container = Settings.CreateControlTextContainer()
            container:Add("PIXEL", L["像素边框"])
            container:Add("BLIZZARD", L["默认边框"])
            return container:GetData()
        end,
    },
    {
        type = "checkbox",
        key = "enableQualityBorder",
        name = L["品质边框着色"],
        default = true,
        tooltip = L["根据物品品质对提示框边框进行着色（仅限普通品质以上）。"]
    },
    {
        type = "checkbox",
        key = "showTitle",
        name = L["显示头衔"],
        default = true,
        tooltip = L["显示或隐藏目标名称前的头衔。"]
    },
    {
        type = "checkbox",
        key = "showServer",
        name = L["显示服务器"],
        default = true,
        tooltip = L["在玩家姓名后显示服务器名称。"]
    },
    {
        type = "checkbox",
        key = "showGuild",
        name = L["显示公会"],
        default = true,
        tooltip = L["显示或隐藏玩家的公会名称。"],
        onChange = function()
            Settings.NotifyUpdate("showRank")
            Settings.NotifyUpdate("showRankIndex")
            Settings.NotifyUpdate("showFullGuildWithModifier")
            Settings.NotifyUpdate("showGuildRealm")
        end
    },
        {
        type = "checkbox",
        key = "showFullGuildWithModifier",
        name = L["显示长公会名"],
        default = true,
        tooltip = L["开启：按住修饰键看全名，关闭：只显示缩写。"],
        onChange = function()
            Settings.NotifyUpdate("guildModifier")
        end
    },
    {
        type = "dropdown",
        key = "guildModifier",
        name = L["修饰键选择"],
        default = "CTRL",
        tooltip = L["选择用于触发显示公会全名的修饰键。"],
        options = function()
            local container = Settings.CreateControlTextContainer()
            container:Add("CTRL", "CTRL")
            container:Add("ALT", "ALT")
            container:Add("SHIFT", "SHIFT")
            return container:GetData()
        end
    },
    {
        type = "checkbox",
        key = "showRank",
        name = L["显示公会会阶"],
        default = false,
        tooltip = L["显示玩家在公会中的职位等级。"],
        onChange = function()
            Settings.NotifyUpdate("showRankIndex")
        end
    },
    {
        type = "checkbox",
        key = "showRankIndex",
        name = L["显示会阶编号"],
        default = false,
        tooltip = L["在会阶名称后显示会阶编号，如 (0) 表示会长。"]
    },
    {
        type = "checkbox",
        key = "showGuildRealm",
        name = L["显示公会服务器"],
        default = true,
        tooltip = L["在公会名称后显示服务器名。"]
    },
    {
        type = "dropdown",
        key = "showFactionIcon",
        name = L["显示阵营图标"],
        default = "ALWAYS",
        tooltip = L["在提示框左侧显示玩家或 NPC 的阵营图标（联盟/部落）。"],
        options = function()
            local container = Settings.CreateControlTextContainer()
            container:Add("PVP", L["仅PVP时显示"])
            container:Add("ALWAYS", L["始终显示"])
            container:Add("NONE", L["不显示"])
            return container:GetData()
        end
    },
    {
        type = "checkbox",
        key = "showShadow",
        name = L["启用阴影(需要RL)"],
        default = true,
        tooltip = L["为提示框添加阴影效果，增强视觉层次感。"]
    },
    {
        type = "checkbox",
        key = "showHealthBar",
        name = L["显示生命条(需要RL)"],
        default = true,
        tooltip = L["显示或隐藏目标的生命条"],
        onChange = function()
            Settings.NotifyUpdate("showHealthText")
            Settings.NotifyUpdate("healthTextMode")
            Settings.NotifyUpdate("healthNumberStyle")
        end
    },
    {
        type = "color",
        key = "friendlyHealthColor",
        name = L["生命条颜色"],
        default = "ff19ff19",
        tooltip = L["秘密值场景下敌方单位生命条的颜色。"],
    },
    {
        type = "checkbox",
        key = "showHealthText",
        name = L["启用血量文本"],
        default = false,
        tooltip = L["在鼠标提示的生命条中央显示血量文本。"],
        onChange = function()
            Settings.NotifyUpdate("healthTextMode")
            Settings.NotifyUpdate("healthNumberStyle")
        end
    },
    {
        type = "dropdown",
        key = "healthTextMode",
        name = L["显示方式"],
        default = "CURRENT_MAX_PERCENT",
        tooltip = L["选择血量文本显示的具体内容组合。"],
        options = function()
            local container = Settings.CreateControlTextContainer()
            container:Add("CURRENT", L["当前血量"])
            container:Add("CURRENT_MAX", L["当前血量/最大血量"])
            container:Add("PERCENT", L["百分比"])
            container:Add("CURRENT_PERCENT", L["当前血量/百分比"])
            container:Add("CURRENT_MAX_PERCENT", L["当前血量/最大血量（百分比）"])
            return container:GetData()
        end,
    },
    {
        type = "slider",
        key = "healthFontSize",
        name = L["生命值字号(需要RL)"],
        default = 11,
        tooltip = L["调整生命条上血量文本的字体大小。"],
        min = 8,
        max = 26,
        step = 1,
    },
    {
        type = "dropdown",
        key = "hpfontOutline",
        name = L["生命值文本描边(需要RL)"],
        default = "THICKOUTLINE",
        tooltip = L["设置生命条上血量文本的描边样式。"],
        options = function()
            local container = Settings.CreateControlTextContainer()
            container:Add("NONE", L["无"])
            container:Add("OUTLINE", L["细描边"])
            container:Add("THICKOUTLINE", L["粗描边"])
            return container:GetData()
        end
    },
    {
        type = "checkbox",
        key = "showMount",
        name = L["显示坐骑"],
        default = true,
        tooltip = L["在提示框中显示玩家当前正在使用的坐骑名称。"],
        onChange = function()
            Settings.NotifyUpdate("showMountSource")
        end
    },
    {
        type = "checkbox",
        key = "showMountSource",
        name = L["显示坐骑来源"],
        default = true,
        tooltip = L["在坐骑名称下方显示获取来源。"]
    },
    {
        type = "checkbox",
        key = "hideinCombat",
        name = L["战斗中隐藏"],
        default = false,
        tooltip = L["在战斗状态下自动隐藏所有鼠标提示信息。"]
    },
    {
        type = "checkbox",
        key = "enableDefaultFade",
        name = L["启用默认渐隐"],
        default = false,
        tooltip = L["开启：使用系统默认渐隐动画；关闭：提示框立即消失。"]
    },
    {
        type = "checkbox",
        key = "showMythicScore",
        name = L["显示大秘境分数"],
        default = true,
        tooltip = L["显示玩家当前赛季的史诗副本（大秘境）分数及最高层数。"]
    },
    {
        type = "dropdown",
        key = "mythicDungeonMode",
        name = L["显示各副本分数"],
        default = "ALWAYS",
        tooltip = L["控制是否在总分数下方列出每个副本的详细分数。"],
        options = function()
            local container = Settings.CreateControlTextContainer()
            container:Add("ALWAYS", L["始终显示"])
            container:Add("MODIFIER", L["按住修饰键显示"])
            container:Add("NONE", L["不显示"])
            return container:GetData()
        end,
        onChange = function()
            Settings.NotifyUpdate("mythicDungeonModifier")
        end
    },
    {
        type = "dropdown",
        key = "mythicDungeonModifier",
        name = L["修饰键选择"],
        default = "CTRL",
        tooltip = L["选择用于触发显示各副本分数的修饰键。"],
        options = function()
            local container = Settings.CreateControlTextContainer()
            container:Add("CTRL", "CTRL")
            container:Add("ALT", "ALT")
            container:Add("SHIFT", "SHIFT")
            return container:GetData()
        end
    },
    {
        type = "checkbox",
        key = "showIDs",
        name = L["显示 ID"],
        default = true,
        tooltip = L["在鼠标提示中显示技能、物品或单位的 ID。"]
    },
    {
        type = "checkbox",
        key = "showItemInfo",
        name = L["显示物品信息"],
        default = false,
        tooltip = L["显示物品堆叠数量、当前持有数量和最大堆叠上限。"]
    },
    -- 装等显示设置
    {
        type = "header",
        key = "itemLevelHeader",
        name = L["装等显示"],
        --tooltip = nil,
    },
    {
        type = "checkbox",
        key = "showItemLevel",
        name = L["显示装等"],
        default = true,
        tooltip = L["显示玩家的平均装等。"]
    },
    {
        type = "color",
        key = "itemLevelColorLow",
        name = L["装等颜色：浅灰"],
        default = "ffb0b0b0",
        tooltip = L["平均装等小于 238 时使用此颜色。"],
    },
    {
        type = "color",
        key = "itemLevelColorGreen",
        name = L["装等颜色：绿色"],
        default = "ff1eff00",
        tooltip = L["平均装等在 238-250 时使用此颜色。"],
    },
    {
        type = "color",
        key = "itemLevelColorBlue",
        name = L["装等颜色：蓝色"],
        default = "ff0070dd",
        tooltip = L["平均装等在 251-263 时使用此颜色。"],
    },
    {
        type = "color",
        key = "itemLevelColorPurple",
        name = L["装等颜色：紫色"],
        default = "ffa335ee",
        tooltip = L["平均装等在 264-276 时使用此颜色。"],
    },
    {
        type = "color",
        key = "itemLevelColorOrange",
        name = L["装等颜色：橙色"],
        default = "ffff8000",
        tooltip = L["平均装等大于等于 277 时使用此颜色。"],
    },


    -- 鼠标跟随分组
    {
        type = "header",
        key = "anchorHeader",
        name = L["鼠标跟随"],
        --tooltip = nil,
    },
    -- 位置设置
    {
        type = "dropdown",
        key = "anchor",
        name = L["跟随鼠标位置"],
        default = "RIGHT",
        tooltip = L["选择提示框贴靠鼠标的具体位置。"],
        options = function()
            local container = Settings.CreateControlTextContainer()
            container:Add("NONE", L["无 (默认位置)"])
            container:Add("RIGHT", L["右侧"])
            container:Add("LEFT", L["左侧"])
            container:Add("TOP", L["上方"])
            container:Add("CURSOR_BR", L["右下方"])
            return container:GetData()
        end,
        onChange = function(value)
            -- 当 anchor 变化时，通知偏移量控件更新显示
            -- 偏移量的值会通过 getter 自动从 baseOffset[新方向] 读取
            Settings.NotifyUpdate("offsetX")
            Settings.NotifyUpdate("offsetY")
        end
    },
    {
        type = "checkbox",
        key = "combatFollow",
        name = L["仅战斗外跟随"],
        default = false,
        tooltip = L["开启此项后，战斗中提示框将回到默认位置。"],
    },
    {
        type = "slider",
        key = "offsetX",
        name = L["水平偏移"],
        default = 0,
        tooltip = L["水平方向偏移量"],
        min = -200,
        max = 200,
        step = 1,
        getter = createOffsetGetter("x"),
        setter = createOffsetSetter("x"),
    },
    {
        type = "slider",
        key = "offsetY",
        name = L["垂直偏移"],
        default = 0,
        tooltip = L["垂直方向偏移量"],
        min = -200,
        max = 200,
        step = 1,
        getter = createOffsetGetter("y"),
        setter = createOffsetSetter("y"),
    },
    -- 鼠标缩放与字体分组
    {
        type = "header",
        key = "scaleHeader",
        name = L["缩放与字体"],
        --tooltip = nil,
    },
    {
        type = "slider",
        key = "scale",
        name = L["缩放"],
        default = 1.0,
        tooltip = L["调整提示框的整体大小。"],
        min = 0.5,
        max = 2.0,
        step = 0.1,
        onChange = function() P.UpdateTipScale() end
    },
    {
        type = "dropdown",
        key = "fontOutline",
        name = L["字体描边"],
        default = "THICKOUTLINE",
        tooltip = L["设置文字的描边样式。"],
        options = function()
            local container = Settings.CreateControlTextContainer()
            container:Add("NONE", L["无"])
            container:Add("OUTLINE", L["细描边"])
            container:Add("THICKOUTLINE", L["粗描边"])
            return container:GetData()
        end,
        onChange = function() P.UpdateTooltipFonts() end
    },
    {
        type = "slider",
        key = "hfontSize",
        name = L["标题字号"],
        default = 18,
        tooltip = L["第一行（姓名、技能名）的字体大小。"],
        min = 10,
        max = 30,
        step = 1,
        onChange = function() P.UpdateTooltipFonts() end
    },
    {
        type = "slider",
        key = "fontSize",
        name = L["正文字号"],
        default = 16,
        tooltip = L["普通提示内容的字体大小。"],
        min = 10,
        max = 30,
        step = 1,
        onChange = function() P.UpdateTooltipFonts() end
    },
    {
        type = "slider",
        key = "sfontSize",
        name = L["小字字号"],
        default = 14,
        tooltip = L["辅助说明或小字内容的字体大小。"],
        min = 10,
        max = 30,
        step = 1,
        onChange = function() P.UpdateTooltipFonts() end
    },
    -- 背景与透明度分组
    {
        type = "header",
        key = "appearanceHeader",
        name = L["背景与透明度"],
    },
    {
        type = "color",
        key = "bgColor",
        name = L["背景颜色"],
        default = "ff000000",
        tooltip = L["调整提示框背景的颜色。"],
    },
    {
        type = "slider",
        key = "bgAlpha",
        name = L["背景透明度"],
        default = 0.7,
        tooltip = L["调整提示框背景的透明度。"],
        min = 0,
        max = 1,
        step = 0.1,
    },
}

-- 建立父子关系
local function setupDeps(initializers)
    for parentKey, configGroups in pairs(dependencies) do
        local parentInit = initializers[parentKey]
        if not parentInit then
            print(string.format("CaiseTip: 警告 - 父控件 '%s' 不存在", parentKey))
        end

        for _, group in ipairs(configGroups) do
            for _, childKey in ipairs(group.children) do
                local childInit = initializers[childKey]
                if childInit then
                    -- 使用暴雪提供的 API 设置显示条件
                    childInit:SetParentInitializer(parentInit, group.enabled)

                    -- 添加显示条件（隐藏而不是禁用）
                    childInit:AddShownPredicate(group.enabled)
                else
                    print(string.format("CaiseTip: 警告 - 子控件 '%s' 不存在", childKey))
                end
            end
        end
    end
end

-- 通用存取函数
local function createGetter(key)
    return function()
        return P.db[key]
    end
end

local function createSetter(key, onChange)
    return function(value)
        P.db[key] = value
        if onChange then
            onChange(value)
        end
    end
end

-- 滑块数值格式化函数
local function formatSliderValue(value, step)
    -- 如果步长小于1，说明需要小数精度
    if step and step < 1 then
        -- 根据步长自动判断小数位数
        return string.format("%.1f", value) -- 1位小数（步长0.05/0.1）
    else
        -- 整数步长，显示为整数
        return string.format("%d", value) -- %d 自动四舍五入取整
    end
end

-- 创建分组标题
local function createHeader(category, opt)
    -- 使用暴雪提供的 API 创建标题
    local header = CreateSettingsListSectionHeaderInitializer(opt.name, opt.tooltip)
    Settings.RegisterInitializer(category, header)
    return header
end

-- 控件创建函数（返回 initializer）
local function createCheckbox(category, opt)
    local getter = opt.getter or createGetter(opt.key)
    local setter = opt.setter or createSetter(opt.key, opt.onChange)

    local setting = Settings.RegisterProxySetting(
        category,
        opt.key,
        Settings.VarType.Boolean,
        opt.name,
        opt.default,
        getter,
        setter
    )
    local init = Settings.CreateCheckbox(category, setting, opt.tooltip)
    return init
end

local function createSlider(category, opt)
    local getter = opt.getter or createGetter(opt.key)
    local setter = opt.setter or createSetter(opt.key, opt.onChange)

    local setting = Settings.RegisterProxySetting(
        category,
        opt.key,
        Settings.VarType.Number,
        opt.name,
        opt.default,
        getter,
        setter
    )
    local options = Settings.CreateSliderOptions(opt.min, opt.max, opt.step)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
        function(v) return formatSliderValue(v, opt.step) end)
    local init = Settings.CreateSlider(category, setting, options, opt.tooltip)
    return init
end

local function createDropdown(category, opt)
    local getter = opt.getter or createGetter(opt.key)
    local setter = opt.setter or createSetter(opt.key, opt.onChange)

    local setting = Settings.RegisterProxySetting(
        category,
        opt.key,
        Settings.VarType.String,
        opt.name,
        opt.default,
        getter,
        setter
    )

    local optionsTable = opt.options()
    local init = Settings.CreateDropdown(category, setting, function() return optionsTable end, opt.tooltip)
    return init
end

local function createColorSwatch(category, opt)
    local getter = opt.getter or createGetter(opt.key)
    local setter = opt.setter or createSetter(opt.key, opt.onChange)

    local setting = Settings.RegisterProxySetting(
        category,
        opt.key,
        Settings.VarType.String,
        opt.name,
        opt.default,
        getter,
        setter
    )
    -- 原生选色器接口：(category, setting, tooltip, options)
    local init = Settings.CreateColorSwatch(category, setting, opt.tooltip)
    return init
end

-- 初始化设置界面
local function InitializeSettings()
    local category = Settings.RegisterVerticalLayoutCategory(L["CaiseTip 设置"])
    SettingsCategory = category

    -- 存储所有控件的 initializer
    local initializers = {}

    -- 统一循环创建所有元素
    for _, opt in ipairs(Options) do
        local init

        if opt.type == "header" then
            -- 创建分组标题
            init = createHeader(category, opt)
            -- 标题不需要加入 initializers 表，因为它没有设置关联
        else
            -- 创建普通控件
            if opt.type == "checkbox" then
                init = createCheckbox(category, opt)
            elseif opt.type == "slider" then
                init = createSlider(category, opt)
            elseif opt.type == "dropdown" then
                init = createDropdown(category, opt)
            elseif opt.type == "color" then
                init = createColorSwatch(category, opt)
            end

            if init then
                initializers[opt.key] = init
            end
        end
    end

    -- 第二阶段：根据 dependencies 表建立所有父子关系
    setupDeps(initializers)

    Settings.RegisterAddOnCategory(category)
end

-- 注册
EventUtil.ContinueOnPlayerLogin(InitializeSettings)

-- 命令
SLASH_CAISETIP1 = "/ctip"
SLASH_CAISETIP2 = "/caisetip"
SlashCmdList["CAISETIP"] = function()
    Settings.OpenToCategory(SettingsCategory:GetID())
end