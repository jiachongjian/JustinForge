-- ============================================================
-- JustinForge 模块8: 聊天频道条 (ChatChannelBar.lua)
-- ============================================================
-- 功能描述：
--   在聊天框附近提供一排单字按钮（说/喊/队/副/团/世/骰/确/倒），
--   左键点击聊天类按钮直接以对应频道激活聊天输入框，点击命令类按钮
--   直接执行斜杠指令（/roll、/rc、/cd 10）。
--   「世」按钮（大脚世界频道）支持右键：未加入时自动加入频道，
--   已加入时退出频道。
--   按钮为简约风格：无背景无边框的纯文字按钮，按钮区域紧贴文字；
--   鼠标悬停时文字颜色提亮（保留频道色色相，不变白）并轻微放大，
--   移开后恢复频道色与原始字号。
--   （实现逻辑提取自 ExwindTools 的 ExTools.ChatChannelBar，去除其
--     编辑模式/吸附/每频道自定义等复杂设置，仅保留坐标/大小/间距设置）
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

-- 默认样式（可在设置面板中调整）
-- 设置面板中的「文字大小」直接控制字号；
-- 按钮区域 = 文字区域 + 内边距（紧贴文字，不再是大很多的方形区域）
local DEFAULT_FONT_SIZE = 16
local DEFAULT_SPACING = 3
-- 按钮相对文字的上下左右内边距（px）
local BTN_PADDING = 4

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
        { type = "slider", key = "buttonSize", name = L["ChatChannelBar_ButtonSize"], min = 12, max = 48, step = 1, default = DEFAULT_FONT_SIZE },
        { type = "slider", key = "spacing", name = L["ChatChannelBar_Spacing"], min = 0, max = 20, step = 1, default = DEFAULT_SPACING },
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

-- 悬停高亮参数：颜色向白色方向提亮的比例（保留色相，不变纯白）、
-- 文字放大倍数
local HOVER_BRIGHTEN = 0.45
local HOVER_SCALE = 1.15

-- 提亮频道色（向白色方向移动 HOVER_BRIGHTEN 比例，保留色相）
local function BrightenColor(c)
    return c.r + (1 - c.r) * HOVER_BRIGHTEN,
           c.g + (1 - c.g) * HOVER_BRIGHTEN,
           c.b + (1 - c.b) * HOVER_BRIGHTEN
end

-- ------------------------------------------------------------
-- 创建按钮容器与频道按钮（仅在首次启用时创建一次）
-- ------------------------------------------------------------
local function CreateBarFrame()
    if barFrame then return end

    barFrame = CreateFrame("Frame", "JFChatChannelBar", UIParent)
    -- 容器始终锁定（不接收鼠标），按钮自身独立接收点击
    barFrame:EnableMouse(false)

    for i, channel in ipairs(CHANNELS) do
        -- 简约风格：无模板纯文字按钮，无背景/边框贴图
        local btn = CreateFrame("Button", "JFChatChannelBtn" .. i, barFrame)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        -- 频道文字即按钮本体
        local text = btn:CreateFontString(nil, "OVERLAY")
        text:SetPoint("CENTER")
        text:SetJustifyH("CENTER")
        text:SetFont(STANDARD_TEXT_FONT, DEFAULT_FONT_SIZE, "OUTLINE")
        text:SetText(channel.name)
        text:SetTextColor(channel.r, channel.g, channel.b)
        btn.text = text
        btn.channelData = channel
        -- 悬停脚本引用的当前字号（ApplyLayout 会按设置刷新，此处先给默认值兜底）
        btn.fontSize = DEFAULT_FONT_SIZE

        -- 悬停反馈：文字颜色提亮（保留频道色色相）并轻微放大，
        -- 移开后恢复频道色与原始字号（字号记录在 btn.fontSize，
        -- 由 ApplyLayout 维护）
        btn:SetScript("OnEnter", function(self)
            local c = self.channelData
            self.text:SetTextColor(BrightenColor(c))
            self.text:SetFont(STANDARD_TEXT_FONT,
                math.floor(self.fontSize * HOVER_SCALE + 0.5), "OUTLINE")
        end)
        btn:SetScript("OnLeave", function(self)
            local c = self.channelData
            self.text:SetTextColor(c.r, c.g, c.b)
            self.text:SetFont(STANDARD_TEXT_FONT, self.fontSize, "OUTLINE")
        end)

        -- 点击通过 OnClick 分发左右键
        btn:SetScript("OnClick", function(self, button)
            OnButtonClick(self.channelData, button)
        end)

        buttons[i] = btn
    end
end

-- ------------------------------------------------------------
-- ApplyLayout: 按 DB 中的文字大小/间距重排按钮
-- ------------------------------------------------------------
-- 设置值直接作为字号；按钮区域 = 文字区域 + BTN_PADDING 内边距，
-- 按钮随文字走，不再有超出文字很多的空白点击区域
local function ApplyLayout()
    if not barFrame then return end
    local db = ns.db.profile.chatChannelBar
    local fontSize = db.buttonSize or DEFAULT_FONT_SIZE
    local spacing = db.spacing or DEFAULT_SPACING
    local btnSize = fontSize + BTN_PADDING * 2

    local count = #buttons
    barFrame:SetSize(count * btnSize + (count + 1) * spacing, btnSize + spacing * 2)

    for i, btn in ipairs(buttons) do
        btn:SetSize(btnSize, btnSize)
        btn:ClearAllPoints()
        btn:SetPoint("LEFT", barFrame, "LEFT", spacing + (i - 1) * (btnSize + spacing), 0)
        btn.fontSize = fontSize
        btn.text:SetFont(STANDARD_TEXT_FONT, fontSize, "OUTLINE")
        -- 不设 SetWidth：按钮尺寸已跟随字号，单字不会溢出；
        -- 保留宽度限制反而会在悬停放大（×HOVER_SCALE）时截断文字
        btn.text:SetWidth(0)
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
    elseif key == "buttonSize" or key == "spacing" then
        ApplyLayout()
    end
end

-- ------------------------------------------------------------
-- OnEnable / OnDisable
-- ------------------------------------------------------------
function module:OnEnable()
    CreateBarFrame()
    ApplyLayout()
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
