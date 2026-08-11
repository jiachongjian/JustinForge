----------------------------------------------------------------------
-- CaiseTip / Modules / SpecInfo
-- 专精信息显示
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

local strformat = string.format

local isSecret = P.IsSecret
local Colors = P.Colors

local specPrefix = Colors.SpecPrefix:WrapTextInColorCode(SPECIALIZATION .. ":")

function P.SpecLine(tooltip)
    if not P._levelLineIndex then return end  -- ← 加这行
    local lineIndex = P._levelLineIndex + 1

    local linetext = _G[tooltip:GetName() .. "TextLeft" .. lineIndex]
    if isSecret(linetext) or not linetext then return end

    local text = linetext:GetText()

    if text and not isSecret(text) and text ~= "" then 
        -- 尝试匹配 "专精名(含空格) 职业名" 的格式
        -- (.-%s)  → 贪心捕获到最后一个空格之前的所有内容（即专精部分）
        -- (%S+)$  → 行尾的连续非空白字符（即职业名）
        local specName = text:match("^(.+%s)(%S+)$")
        if specName then
            -- 专精名染色 (使用模板)
            local coloredSpecName = Colors.SpecName:WrapTextInColorCode(specName:trim())
            specName = strformat("%s %s", specPrefix, coloredSpecName)
        else
            -- 无专精（只有职业名）：隐藏该行
            specName = ""
        end
        linetext:SetText(specName)
    end
end
