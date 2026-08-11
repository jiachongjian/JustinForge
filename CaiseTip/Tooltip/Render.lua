----------------------------------------------------------------------
-- CaiseTip / Tooltip / Render
-- 行渲染调度 + TooltipDataProcessor 注册
----------------------------------------------------------------------

local P = select(2, ...)

-- WoW global API
local GameTooltip = GameTooltip
local Enum = Enum
local hooksecurefunc = hooksecurefunc

local strformat = string.format

local GetDisplayedItem = TooltipUtil.GetDisplayedItem

local isSecret = P.IsSecret

local hideKeywords = { FACTION_ALLIANCE, FACTION_HORDE, PVP }
local function HideLine(tooltip, unit)
    local type = UnitCreatureType(unit)

    for i = 3, tooltip:NumLines() do
        local line = _G[tooltip:GetName() .. "TextLeft" .. i]
        local text = line:GetText()
        if text and not isSecret(text) then
            for j = 1, #hideKeywords do
                if not isSecret(hideKeywords[j]) and text:find(hideKeywords[j]) then
                    line:SetText("")
                    line:Hide()
                    break
                end
            end
            if P._levelLineIndex and i ~= P._levelLineIndex then
                if type and not isSecret(type) and text:find(type) then
                    line:SetText("")
                    line:Hide()
                end
            end
        end
    end
end

local function FactionIcon(self, faction)
    if not self.factionIcon then
        self.factionIcon = self:CreateTexture(nil, "OVERLAY")
        self.factionIcon:Hide()
        self.factionIcon:SetPoint("TOPLEFT", -38, -25)
        self.factionIcon:SetSize(60, 60)
        self.factionIcon:SetAlpha(1)
    end

    self.factionIcon:SetTexture(strformat("Interface\\Timer\\%s-Logo", faction))
    self.factionIcon:Show()
end

local function OnSetItem(self, data)
    if not P.db.enableQualityBorder then return end

    local id = data.id
    if not id or isSecret(id) then return end

    local quality = C_Item.GetItemQualityByID(id)
    if quality and quality > 1 then
        local r, g, b = C_Item.GetItemQualityColor(quality)
        if self._tipbg then
            self._tipbg:SetBackdropBorderColor(r, g, b, 1)
        end
    end
end

local function ResetBorderColor(tooltip)
    if not tooltip or not tooltip._tipbg then
        return
    end

    local r, g, b, a = P.GetBorderBaseColor()
    tooltip._tipbg:SetBackdropBorderColor(r, g, b, a)
end

local function tipCleared(tooltip)
    P._levelLineIndex = nil
    P.ClearPendingItemLevel()
    -- 重置边框颜色
    ResetBorderColor(tooltip)

    if tooltip.factionIcon then
        tooltip.factionIcon:Hide()
    end
end

local function OnSetUnit(tooltip)
    local unit = P.GetUnit(tooltip)
    --P.UpdateHealthBarColor(tooltip)
    if not P.IsSafeUnit(unit) then return end

    local isPlayer = UnitIsPlayer(unit)

    P.LevelLine(tooltip, unit, isPlayer)

    if isPlayer then
        P.GuildLine(tooltip, unit)
        P.SpecLine(tooltip)
        P.ShowItemLevel(tooltip, unit)
        P.ShowMythicScore(tooltip, unit)
        P.ShowTarget(tooltip, unit)
        P.ShowMount(tooltip, unit)
    end
    
    local factionMode = P.db.showFactionIcon
    if factionMode ~= "NONE" then
        local showIcon = factionMode == "ALWAYS" or (factionMode == "PVP" and UnitIsPVP(unit))
        if showIcon then
            local faction = UnitFactionGroup(unit)
            if faction and faction ~= "Neutral" then
                FactionIcon(tooltip, faction)
            end
        end
    end

    HideLine(tooltip, unit)
end

-- 隐藏单位框架提示中的右键点击提示行（通过 hook GameTooltip_AddInstructionLine，安全不污染）
local function HideRightClickInstruction(tooltip, text)
    if text == UNIT_POPUP_RIGHT_CLICK then
        local numLines = tooltip:NumLines()
        -- 隐藏刚才添加的指令行
        local line = _G["GameTooltipTextLeft" .. numLines]
        if line then line:Hide() end
        -- 隐藏指令行前面的空白行（GameTooltip_AddBlankLineToTooltip 添加的）
        if numLines > 1 then
            local blankLine = _G["GameTooltipTextLeft" .. (numLines - 1)]
            if blankLine then blankLine:Hide() end
        end
    end
end

-- 未启用默认渐隐时：拦截引擎淡出动画，提示框立即消失
local function OnFadeOut(self)
    if not P.db.enableDefaultFade then
        self:Hide()
    end
end

local function OnLogin()
    GameTooltip:HookScript("OnTooltipCleared", tipCleared)
    TooltipDataProcessor.AddLinePreCall(Enum.TooltipDataLineType.UnitName, P.NameLine)
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnSetUnit)
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, P.UpdateHealthBarColor)
    -- 注册物品类型提示框处理，实现品质边框着色
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnSetItem)

    hooksecurefunc("GameTooltip_SetDefaultAnchor", P.GetAnchor)
    hooksecurefunc(GameTooltip, "FadeOut", OnFadeOut)

    hooksecurefunc(GameTooltip.StatusBar, "UpdateUnitHealth", P.OnUpdateUnitHealth)

    P.ShowID()
    P.ShowItemInfo()

    hooksecurefunc("GameTooltip_AddInstructionLine", HideRightClickInstruction)

end

-- 注册
EventUtil.ContinueOnPlayerLogin(OnLogin)


-- 全局拦截 BackdropTemplateMixin.SetupTextureCoordinates
local origSetupTextureCoordinates = BackdropTemplateMixin.SetupTextureCoordinates
BackdropTemplateMixin.SetupTextureCoordinates = function(self, ...)
    if not self or self.GetObjectType then
        local objType = self:GetObjectType()
        if objType ~= "Frame" and objType ~= "Button" then
            return origSetupTextureCoordinates(self, ...)
        end
    end
    if not self.GetWidth or not self.GetHeight then
        return origSetupTextureCoordinates(self, ...)
    end
    
    local width, height
    local ok, err = pcall(function()
        width = self:GetWidth()
        height = self:GetHeight()
    end)
    
    if not ok then
        return origSetupTextureCoordinates(self, ...)
    end
    
    if isSecret(width) or isSecret(height) then
        return
    end
    return origSetupTextureCoordinates(self, ...)
end
