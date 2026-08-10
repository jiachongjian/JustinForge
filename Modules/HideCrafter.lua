-- ============================================================
-- JustinForge 模块13: 隐藏制造业制造者 (HideCrafter.lua)
-- ============================================================
-- 功能描述：
--   在装备鼠标提示中隐藏制造业装备上的绿色「<制造者名字>」署名行。
--   （实现逻辑移植自 ElvUI_WindTools 的 Misc/HideCrafter，
--     已去除全部 ElvUI 依赖）
--
-- 实现原理：
--   1. TooltipDataProcessor.AddTooltipPostCall(Item) 回调中
--      遍历提示数据行，定位绿色署名行（|cff00ff00<名字>|r）
--   2. 在真实提示框文本行中找到对应行并置空
--   3. 回调无法卸载，禁用时通过模块开关短路返回，零开销
--
-- 覆盖提示框：GameTooltip / ItemRefTooltip / 购物对比提示
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

local strmatch = strmatch

local TooltipDataProcessor_AddTooltipPostCall = TooltipDataProcessor.AddTooltipPostCall
local Enum_TooltipDataType_Item = Enum.TooltipDataType.Item

-- 12.x 秘密值检查函数（信息受限时文本为秘密值，不可比较）
local issecretvalue = _G.issecretvalue

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "hideCrafter",
    name           = L["HideCrafter_Name"],
    description    = L["HideCrafter_Desc"],
    defaultEnabled = true,
})

-- 生效的提示框集合（按名匹配，O(1) 查找）
local tooltipNames = {
    GameTooltip = true,
    ItemRefTooltip = true,
    ShoppingTooltip1 = true,
    ShoppingTooltip2 = true,
    ItemRefShoppingTooltip1 = true,
    ItemRefShoppingTooltip2 = true,
}

-- ------------------------------------------------------------
-- RemoveCraftInformation: 物品提示后置回调，隐藏绿色署名行
-- ------------------------------------------------------------
local function RemoveCraftInformation(tooltip, data)
    -- 回调无法卸载，通过模块开关短路（零开销）
    if not module.enabled then return end

    local tooltipName = tooltip:GetName()
    if not tooltipName or not tooltipNames[tooltipName] then return end
    if not data or not data.lines then return end

    -- 署名行位于提示末尾附近，从后向前扫描（超过 10 行时只看第 10 行之后）
    for dataIndex = #data.lines, (10 < #data.lines and 10 or 1), -1 do
        local line = data.lines[dataIndex] and data.lines[dataIndex].leftText
        if line and strmatch(line, "^|cff00ff00<(.+)>|r$") then
            -- 数据行索引与真实文本行索引可能有少量偏差，允许 2 行误差
            for tooltipLineIndex = dataIndex, dataIndex + 2 do
                local realLine = _G[tooltipName .. "TextLeft" .. tooltipLineIndex]
                local realText = realLine and realLine:GetText()
                -- 秘密值不可比较，直接跳过
                if realText and not (issecretvalue and issecretvalue(realText)) and realText == line then
                    realLine:SetText("")
                end
            end
        end
    end
end

-- 回调无法卸载，仅注册一次，内部通过 module.enabled 开关控制
TooltipDataProcessor_AddTooltipPostCall(Enum_TooltipDataType_Item, RemoveCraftInformation)

-- ------------------------------------------------------------
-- OnEnable / OnDisable
-- ------------------------------------------------------------
-- 无需注册/注销任何资源，开关由 module.enabled 自动控制回调行为
function module:OnEnable()
    Util:Debug("HideCrafter: 已启用")
end

function module:OnDisable()
    Util:Debug("HideCrafter: 已禁用")
end
