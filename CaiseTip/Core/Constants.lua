----------------------------------------------------------------------
-- CaiseTip / Core / Constants
-- 颜色、纹理、默认配置等常量
----------------------------------------------------------------------

local P = select(2, ...)   -- addon table

local TOOLTIP_DEFAULT_COLOR = TOOLTIP_DEFAULT_COLOR
local LIGHTGRAY_FONT_COLOR = LIGHTGRAY_FONT_COLOR
local RED_FONT_COLOR = RED_FONT_COLOR
local GREEN_FONT_COLOR = GREEN_FONT_COLOR
local ENCOUNTER_TIMELINE_QUEUED_TEXT_COLOR = ENCOUNTER_TIMELINE_QUEUED_TEXT_COLOR
local ITEM_GOOD_COLOR = ITEM_GOOD_COLOR
local ITEM_SUPERIOR_COLOR = ITEM_SUPERIOR_COLOR
local ITEM_EPIC_COLOR = ITEM_EPIC_COLOR
local ITEM_LEGENDARY_COLOR = ITEM_LEGENDARY_COLOR

P.Colors = {
    --White = CreateColor(1, 1, 1),
    --Grey = CreateColor(0.6, 0.6, 0.6),
    Green = CreateColor(0, 1, 0),
    Alliance = CreateColor(0.290, 0.522, 0.980),     -- #4a85fa
    Horde = CreateColor(1.0, 0.310, 0.251),          -- #ff4f40
    MyGuild = CreateColor(0.4, 0.7, 0.8),              -- #66B2FF
    OtherGuild = CreateColor(0.894, 0.122, 0.608),   -- #e41f9b
    SpecName = CreateColor(0.6, 0.8, 1),             -- #99ccff
    Pink = CreateColor(226/255, 104/255, 152/255),
    Golden = CreateColor(229/255, 204/255, 95/255),

    -- WoW 原生颜色常量
    White          = TOOLTIP_DEFAULT_COLOR,                -- 白色
    LightGray      = LIGHTGRAY_FONT_COLOR,                 -- 浅灰色
    Red            = RED_FONT_COLOR,                       -- 红色
    SpecPrefix     = ENCOUNTER_TIMELINE_QUEUED_TEXT_COLOR, -- 专精前缀色
    ItemGood       = ITEM_GOOD_COLOR,                      -- 绿色品质
    ItemSuperior   = ITEM_SUPERIOR_COLOR,                  -- 蓝色品质
    ItemEpic       = ITEM_EPIC_COLOR,                      -- 紫色品质
    ItemLegendary  = ITEM_LEGENDARY_COLOR,                 -- 橙色品质
}

-- 纹理路径
P.Tex = {
    blank = "Interface\\Buttons\\WHITE8x8",
    shadow = "Interface\\AddOns\\CaiseTip\\Media\\glow.tga",
    defaultborder = "Interface\\Tooltips\\UI-Tooltip-Border",
}

P.font = STANDARD_TEXT_FONT
