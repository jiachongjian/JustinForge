----------------------------------------------------------------------
-- CaiseTip / Features / Hyperlink
-- 链接悬停增强（物品/法术/成就等链接在 tooltip 中显示额外信息）
----------------------------------------------------------------------

local P = select(2, ...)


function HyperLink_OnEnter(self, link, text, ...)
    -- 1. 显示战斗宠物提示框（如果匹配）
    local linkType = LinkUtil.SplitLinkData(link)
    if linkType == "battlepet" then
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT", 8, 6)
        BattlePetToolTip_ShowLink(text)
    elseif linkType ~= "trade" then
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT", 8, 6)

        local isOK = pcall(GameTooltip.SetHyperlink, GameTooltip, link)
        if not isOK then
            GameTooltip:Hide()
        else
            GameTooltip:Show()
        end
    end
end

function HyperLink_OnLeave(self, _, ...)
    -- 1. 隐藏战斗宠物提示框（如果正在显示）
    BattlePetTooltip:Hide()

    -- 2. 隐藏通用游戏提示框
    GameTooltip:Hide()

end

for i = 1, NUM_CHAT_WINDOWS do
    local frame = _G['ChatFrame' .. i]

    frame:HookScript('OnHyperlinkEnter', HyperLink_OnEnter)
    frame:HookScript('OnHyperlinkLeave', HyperLink_OnLeave)
end

local function hookMessageFrame()
    -- 替换社区聊天框的链接悬停事件处理函数
    CommunitiesFrame.Chat.MessageFrame:HookScript('OnHyperlinkEnter', HyperLink_OnEnter)
    CommunitiesFrame.Chat.MessageFrame:HookScript('OnHyperlinkLeave', HyperLink_OnLeave)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")

local function hookCommunitiesFrame(event, addon)
    if addon == "Blizzard_Communities" then
        hookMessageFrame()
        eventFrame:UnregisterEvent("ADDON_LOADED")  -- 取消注册事件，避免重复执行
    end
end

-- 3. 设置事件处理器
eventFrame:SetScript("OnEvent", hookCommunitiesFrame)

-- 4. 检查是否已经加载了 Blizzard_Communities
if C_AddOns.IsAddOnLoaded("Blizzard_Communities") then
    hookMessageFrame()  -- 如果已加载，直接挂钩
end


