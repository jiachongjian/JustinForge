----------------------------------------------------------------------
-- CaiseTip / Tooltip / Skin
-- 边框/背景/阴影/字体/缩放（纯视觉）
----------------------------------------------------------------------

local P = select(2, ...)

local font = P.font

--- 应用工具提示外观
local function SkinStatusBar(self)
    if not self or self._skinnedStatusBar then return end
    local bar = self.StatusBar or self.statusBar or _G[self:GetName() .. "StatusBar"]
    if not bar then return end

    if P.db.showHealthBar then
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", self, "BOTTOMLEFT", P.mult + 2, -2 * P.mult)
        bar:SetPoint("TOPRIGHT", self, "BOTTOMRIGHT", -P.mult - 2, -2 * P.mult)
        bar:SetHeight(4)
        bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")

        local hfontsize = P.db.healthFontSize
        local outline = P.db.hpfontOutline
        if outline == "NONE" then outline = "" end -- SetFont 不支持 "NONE"

        -- 动态创建生命值文本
        if not bar.HealthText then
            local text = bar:CreateFontString(nil, "OVERLAY")
            text:SetFont(font, hfontsize, outline)
            text:SetPoint("CENTER", bar, "CENTER", 0, 0)
            text:SetTextColor(1, 1, 1)
            bar.HealthText = text
        end

        -- 使用统一美化函数
        P.CreatePxSBD(bar, 0.8, "PIXEL")
    else
        bar:SetStatusBarTexture(0)
    end

    self._skinnedStatusBar = true
end

local function SkinTip(self)
    if not self or self:IsForbidden() then return end

    if not self._skinned then
        if self.NineSlice then
            self.NineSlice:SetAlpha(0)
        end
        if self.StatusBar or self.statusBar then
            SkinStatusBar(self)
        end

        if self.Background then self.Background:Hide() end

        -- 使用统一美化函数
        if not self._tipbg then
            self._tipbg = P.CreatePxSBD(self)
            self._tipbg:SetPoint("TOPLEFT", self, "TOPLEFT", P.mult, -P.mult)
            self._tipbg:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -P.mult, P.mult)
        end

        self._skinned = true
    end

    local header = self.CompareHeader
    if header then
        P.StripBlizzardTextures(header)
    end

    if self._tipbg then
        local style = P.db.borderStyle or "PIXEL"
        if self._tipbg._borderStyle ~= style then
            P.ApplyBackdropStyle(self._tipbg, style)
        end
        P.UpdateBackdropColor(self._tipbg)
    end
end

local tooltips = nil
function P.UpdateTipScale()
    if tooltips then
        for _, tt in ipairs(tooltips) do
            if tt and tt.SetScale then
                tt:SetScale(P.db.scale)
            end
        end
    end
end

-- 来源：NDui
tooltips = {
    ChatMenu,
    EmoteMenu,
    LanguageMenu,
    VoiceMacroMenu,
    GameTooltip,
    EmbeddedItemTooltip,
    ItemRefTooltip,
    ItemRefShoppingTooltip1,
    ItemRefShoppingTooltip2,
    ShoppingTooltip1,
    ShoppingTooltip2,
    AutoCompleteBox,
    FriendsTooltip,
    QuestScrollFrame.StoryTooltip,
    QuestScrollFrame.CampaignTooltip,
    GeneralDockManagerOverflowButtonList,
    ReputationParagonTooltip,
    NamePlateTooltip,
    QueueStatusFrame,
    FloatingGarrisonFollowerTooltip,
    FloatingGarrisonFollowerAbilityTooltip,
    FloatingGarrisonMissionTooltip,
    GarrisonFollowerAbilityTooltip,
    GarrisonFollowerTooltip,
    FloatingGarrisonShipyardFollowerTooltip,
    GarrisonShipyardFollowerTooltip,
    BattlePetTooltip,
    PetBattlePrimaryAbilityTooltip,
    PetBattlePrimaryUnitTooltip,
    FloatingBattlePetTooltip,
    FloatingPetBattleAbilityTooltip,
    IMECandidatesFrame,
    QuickKeybindTooltip,
    GameSmallHeaderTooltip,
}
for _, f in pairs(tooltips) do
    if f then
        f:HookScript("OnShow", function(self)
            if self:IsForbidden() then return end

            -- 战斗中隐藏逻辑
            if P.db.hideinCombat and InCombatLockdown() then
                self:Hide()
                return
            end

            -- 原有逻辑：设置缩放并应用美化
            self:SetScale(P.db.scale)
            SkinTip(self)
        end)
    end
end

function P.UpdateTooltipFonts()
    local hfontsize = P.db.hfontSize
    local ffontsize = P.db.fontSize
    local sfontsize = P.db.sfontSize
    local outline = P.db.fontOutline
    if outline == "NONE" then outline = "" end -- SetFont 不支持 "NONE"

    GameTooltipText:SetFont(font, ffontsize, outline)
    GameTooltipTextSmall:SetFont(font, sfontsize, outline)
    GameTooltipHeaderText:SetFont(font, hfontsize, outline)
end

