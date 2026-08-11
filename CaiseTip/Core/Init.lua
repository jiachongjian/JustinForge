----------------------------------------------------------------------
-- CaiseTip / Core / Init
-- 插件入口，加载顺序控制，DB初始化
----------------------------------------------------------------------

local A, P = ...

-- Lua standard library
local floor = math.floor
local select = select

-- WoW global API
local GetPhysicalScreenSize = GetPhysicalScreenSize
local UIParent = UIParent

-- 加载顺序：
--   1. Constants    - 颜色/纹理/默认配置等常量
--   2. Locales      - 本地化文本
--   3. Config       - 设置面板 / DB
--   4. Utils        - 工具函数（依赖 Constants）
--   5. Tooltip/*    - 外观、定位、渲染
--   6. Modules/*    - 数据模块
--   7. Features/*   - 额外功能

-- AuroraClassic
local function GetCurrentScale()
    local mult = 1e5
    local scale = UIParent:GetScale()
    return floor(scale * mult + .5) / mult
end

local function UpdateScale()
    local scale = GetCurrentScale()
    local screenHeight = select(2, GetPhysicalScreenSize())
    local pixel = 1
    local ratio = 768 / screenHeight
    P.mult = (pixel / scale) - ((pixel - ratio) / scale)
end

EventRegistry:RegisterFrameEventAndCallback("UI_SCALE_CHANGED", UpdateScale)

-- ========== 插件初始化逻辑 ==========
local function InitializeAddon()
    -- 加载配置
    P:LoadConfig()
    UpdateScale() 
end

-- 在插件加载完成后执行
EventUtil.ContinueOnAddOnLoaded(A, InitializeAddon)
