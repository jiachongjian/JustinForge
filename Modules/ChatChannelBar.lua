-- ============================================================
-- JustinForge 模块8: 聊天频道快捷栏 (ChatChannelBar.lua)
-- ============================================================
-- 功能描述：
--   在聊天框附近提供一排单字按钮（说/喊/队/会/副/团/世/骰/确/倒），
--   左键点击聊天类按钮直接以对应频道激活聊天输入框，点击命令类按钮
--   直接执行斜杠指令（/roll、/rc、/cd 10）。
--   「世」按钮（大脚世界频道）支持右键：未加入时自动加入频道，
--   已加入时退出频道。
--   按钮外观使用暴雪原生方形按钮模板（UIPanelSquareButton）。
--   （实现逻辑提取自 ExwindTools 的 ExTools.ChatChannelBar，去除其
--     编辑模式/吸附/每频道自定义等复杂设置，仅保留坐标定位）
--
-- 定位方式：
--   模块不提供拖动，位置由设置面板中的「水平位置 (X)」
--   「垂直位置 (Y)」两个滑条决定（以屏幕中心为原点，左/下为负）。
--   坐标持久化于 JustinForgeDB.profile.chatChannelBar.posX/posY。
--
-- 实现要点：
--   1. 频道切换：ChatFrame_OpenChat("/g ") 直接以指定频道打开输入框
--   2. 世界频道（大脚世界频道）：先 GetChannelName 取频道号，
--      再以 "/<id> " 打开输入框；未加入时输出红色提示
--   3. 斜杠指令：优先遍历 SlashCmdList 按 SLASH_* 别名匹配直接调用，
--      匹配不到时回退为通过聊天框发送（兼容 /cd 等插件指令）
--   4. 按钮容器 EnableMouse(false)（锁定），按钮自身 EnableMouse(true)，
--      互不影响
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

-- 固定样式（提取自 ExwindTools 默认值，不提供设置项）
local FONT_SIZE = 16
local BUTTON_SIZE = 30
local BUTTON_PADDING = 3

-- 屏幕尺寸在文件加载时即可获取，作为坐标滑条的上限
local screenWidth = math.floor(UIParent:GetWidth() or 1920)
local screenHeight = math.floor(UIParent:GetHeight() or 1080)

-- ============================================================
-- 模块注册（附带坐标设置项，Config.lua 自动生成为滑条）
-- ============================================================
-- 坐标以屏幕中心为原点：默认位置折算自旧的屏幕左下角 (46, 207)
local halfWidth = math.floor(screenWidth / 2)
local halfHeight = math.floor(screenHeight / 2)

local module = ns.Module:Register({
    key            = "chatChannelBar",
    name           = L["ChatChannelBar_Name"],
    description    = L["ChatChannelBar_Desc"],
    defaultEnabled = true,
    options = {
        { type = "slider", key = "posX", name = L["ChatChannelBar_PosX"], min = -halfWidth,  max = halfWidth,  step = 1, default = 46 - halfWidth },
        { type = "slider", key = "posY", name = L["ChatChannelBar_PosY"], min = -halfHeight, max = halfHeight, step = 1, default = 207 - halfHeight },
    },
})

-- 频道定义（固定列表，世界频道位于「团」之后）：
--   chat  普通聊天频道，点击后以该频道打开输入框
--   named 具名频道（世界频道），左键先解析频道号再打开输入框；
--         右键在未加入时加入频道、已加入时退出频道
--   slash 斜杠指令，点击后直接执行
local WORLD_CHANNEL_NAME = "大脚世界频道"
local CHANNELS = {
    { name = "说", cmd = "/s",                chat = true,  r = 1,    g = 1,    b = 1 },
    { name = "喊", cmd = "/y",                chat = true,  r = 1,    g = 0.25, b = 0.25 },
    { name = "队", cmd = "/p",                chat = true,  r = 0.67, g = 0.67, b = 1 },
    { name = "会", cmd = "/g",                chat = true,  r = 0.25, g = 1,    b = 0.25 },
    { name = "副", cmd = "/i",                chat = true,  r = 1,    g = 0.5,  b = 0 },
    { name = "团", cmd = "/raid",             chat = true,  r = 1,    g = 0.5,  b = 0 },
    { name = "世", cmd = WORLD_CHANNEL_NAME,  named = true, r = 1,    g = 0.5,  b = 0.5 },
    { name = "骰", cmd = "/roll",             slash = true, r = 1,    g = 1,    b = 0 },
    { name = "确", cmd = "/rc",               slash = true, r = 0,    g = 1,    b = 1 },
    { name = "倒", cmd = "/cd 10",            slash = true, r = 1,    g = 0,    b = 1 },
}

local barFrame = nil
local buttons = {}

-- ------------------------------------------------------------
-- ExecuteSlashCommand: 统一执行斜杠指令（如 /roll /cd 10）
-- ------------------------------------------------------------
-- 优先按 SLASH_* 注册别名匹配并直接调用处理函数；
-- 匹配不到时回退为把指令填入聊天框发送
local function ExecuteSlashCommand(rawCmd)
    local cmd = string.gsub(tostring(rawCmd or ""), "^%s*(.-)%s*$", "%1")
    if cmd == "" then return false end
    if not string.find(cmd, "^/") then
        cmd = "/" .. cmd
    end

    local slash, args = string.match(cmd, "^(/[^%s]+)%s*(.*)")
    if slash and SlashCmdList then
        slash = string.upper(slash)
        for key, func in pairs(SlashCmdList) do
            local i = 1
            while true do
                local registered = _G["SLASH_" .. key .. i]
                if not registered then break end
                if string.upper(registered) == slash then
                    local ok = pcall(func, args or "")
                    return ok
                end
                i = i + 1
            end
        end
    end

    if ChatEdit_ChooseBoxForSend and ChatEdit_SendText then
        local editBox = ChatEdit_ChooseBoxForSend()
        if editBox then
            editBox:SetText(cmd)
            ChatEdit_SendText(editBox, 0)
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------
-- OpenChatWithSlash: 以指定前缀（如 "/g "）激活聊天输入框
-- ------------------------------------------------------------
local function OpenChatWithSlash(text)
    text = string.gsub(tostring(text or ""), "^%s*(.-)%s*$", "%1")
    if text == "" then return false end

    if ChatFrame_OpenChat then
        ChatFrame_OpenChat(text)
        return true
    end

    if not ChatEdit_ChooseBoxForSend or not ChatEdit_ActivateChat then
        return false
    end
    local editBox = ChatEdit_ChooseBoxForSend()
    if not editBox then return false end
    ChatEdit_ActivateChat(editBox)
    editBox:SetText(text)
    return true
end

-- 具名频道（大脚世界频道）：解析频道号后按 "/<id> " 打开输入框
local function OpenNamedChannel(channelName)
    if not GetChannelName then return false end
    local id = GetChannelName(channelName)
    if not id or id <= 0 then return false end
    return OpenChatWithSlash("/" .. id .. " ")
end

-- 具名频道右键：未加入则加入，已加入则退出
local function ToggleNamedChannel(channelName)
    if not GetChannelName then return end
    local id = GetChannelName(channelName)
    if id and id > 0 then
        if LeaveChannelByName then
            LeaveChannelByName(channelName)
        end
        Util:Print(L["ChatChannelBar_Left"])
    else
        if JoinChannelByName then
            JoinChannelByName(channelName)
        end
        Util:Print(L["ChatChannelBar_Joined"])
    end
end

-- ------------------------------------------------------------
-- 按钮点击分发（button = "LeftButton" / "RightButton"）
-- ------------------------------------------------------------
local function OnButtonClick(channel, button)
    if channel.named then
        if button == "RightButton" then
            ToggleNamedChannel(channel.cmd)
            return
        end
        if not OpenNamedChannel(channel.cmd) then
            Util:Print(L["ChatChannelBar_NoChannel"] .. tostring(channel.cmd))
        end
    elseif channel.slash then
        if not ExecuteSlashCommand(channel.cmd) then
            Util:Print(L["ChatChannelBar_CmdFailed"] .. tostring(channel.cmd))
        end
    else
        if not OpenChatWithSlash(channel.cmd .. " ") then
            Util:Print(L["ChatChannelBar_OpenFailed"] .. tostring(channel.cmd))
        end
    end
end

-- ------------------------------------------------------------
-- 创建按钮容器与频道按钮（仅在首次启用时创建一次）
-- ------------------------------------------------------------
local function CreateBarFrame()
    if barFrame then return end

    barFrame = CreateFrame("Frame", "JFChatChannelBar", UIParent)
    -- 容器始终锁定（不接收鼠标），按钮自身独立接收点击
    barFrame:EnableMouse(false)

    local count = #CHANNELS
    local width = count * BUTTON_SIZE + (count + 1) * BUTTON_PADDING
    barFrame:SetSize(width, BUTTON_SIZE + BUTTON_PADDING * 2)

    for i, channel in ipairs(CHANNELS) do
        -- 暴雪原生方形按钮模板（UI-SquareButton 系列贴图，自带按下/禁用/高亮态）
        local btn = CreateFrame("Button", "JFChatChannelBtn" .. i, barFrame, "UIPanelSquareButton")
        btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
        btn:SetPoint("LEFT", barFrame, "LEFT", BUTTON_PADDING + (i - 1) * (BUTTON_SIZE + BUTTON_PADDING), 0)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        -- 频道文字作为覆盖层显示在按钮贴图之上
        local text = btn:CreateFontString(nil, "OVERLAY")
        text:SetPoint("CENTER")
        text:SetFont(STANDARD_TEXT_FONT, FONT_SIZE, "OUTLINE")
        text:SetText(channel.name)
        text:SetTextColor(channel.r, channel.g, channel.b)
        btn.text = text
        btn.channelData = channel

        -- 模板自带按下/高亮视觉反馈，点击通过 OnClick 分发左右键
        btn:SetScript("OnClick", function(self, button)
            OnButtonClick(self.channelData, button)
        end)

        buttons[i] = btn
    end
end

-- ------------------------------------------------------------
-- ApplyPosition: 按 DB 中的坐标定位（屏幕中心为原点）
-- ------------------------------------------------------------
local function ApplyPosition()
    if not barFrame then return end
    local db = ns.db.profile.chatChannelBar
    barFrame:ClearAllPoints()
    barFrame:SetPoint("BOTTOMLEFT", UIParent, "CENTER",
        db.posX or (46 - halfWidth), db.posY or (207 - halfHeight))
end

-- ------------------------------------------------------------
-- OnOptionChanged: 设置面板坐标滑条变化时即时重定位
-- ------------------------------------------------------------
-- 值已由 Settings 绑定写入 DB.profile.chatChannelBar，此处只需应用
function module:OnOptionChanged(key, value)
    if key == "posX" or key == "posY" then
        ApplyPosition()
    end
end

-- ------------------------------------------------------------
-- OnEnable / OnDisable
-- ------------------------------------------------------------
function module:OnEnable()
    CreateBarFrame()
    ApplyPosition()
    barFrame:Show()
    Util:Debug("ChatChannelBar: 已显示")
end

function module:OnDisable()
    if barFrame then
        barFrame:Hide()
    end
    Util:Debug("ChatChannelBar: 已隐藏")
end
