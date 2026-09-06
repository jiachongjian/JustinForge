-- ============================================================
-- JustinForge 模块21: 好友列表增强 (FriendsListEnhance.lua)
-- ============================================================
-- 功能描述：
--   增强 O 键好友面板（FriendsFrame）中战网好友条目的名字行：
--   1. 好友登录了角色后，角色名称颜色由默认浅蓝改为职业颜色
--   2. 角色名称后面追加「空格 + 等级数字」（保持默认颜色，不染色）
--   3. 「战网名称 + 角色名」整行字体缩小一号
--
-- 实现原理：
--   1. 12.0 好友列表由 ScrollBox 驱动，按钮初始化走全局函数
--      FriendsFrame_UpdateFriendButton(button, elementData)
--      使用 hooksecurefunc 后置 Hook，在暴雪设置完文本后重写 name 行
--   2. 战网好友在线且正在 WoW 中时，从 C_BattleNet.GetFriendAccountInfo
--      读取角色名/等级/职业ID，重建文本：
--        战网名 (职业色角色名) 等级
--   3. 字号通过 button.name:SetFont 原字体大小 -1 实现；
--      ScrollBox 会复用按钮，故每次刷新都按条目类型重新设置
--      （战网条目缩一号，其他条目还原原始字号），不会越缩越小
--   4. 仅处理战网（BNET）条目；角色（WOW）条目保持原生显示
--
-- 设计说明：
--   - Blizzard_FriendsFrame 为按需加载插件，未加载时监听
--     ADDON_LOADED，加载完成后再安装 Hook
--   - hooksecurefunc 无法卸载，禁用时通过 module.enabled 短路，
--     并在 OnDisable 中还原已创建按钮的字号、刷新列表还原文本
-- ============================================================

local addonName, ns = ...

local L = ns.L

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "friendsListEnhance",
    name           = L["FriendsListEnhance_Name"],
    description    = L["FriendsListEnhance_Desc"],
    defaultEnabled = true,
})

-- Hook 是否已安装标志：防止重复 Hook（多次启用时只安装一次）
local hooked = false

-- ------------------------------------------------------------
-- ApplyNameFont: 设置按钮名字行字号
-- ------------------------------------------------------------
-- 首次调用时记录按钮原始字体信息（路径/大小/描边），
-- 之后每次刷新按 shrink 参数决定缩小一号或还原原始大小
-- ScrollBox 复用按钮时条目类型会变，因此必须每次都显式设置
local function ApplyNameFont(button, shrink)
    local fs = button.name
    if not fs then return end
    if not button.JF_origNameFont then
        local font, size, flags = fs:GetFont()
        if not font or not size then return end
        button.JF_origNameFont = { font = font, size = size, flags = flags }
    end
    local orig = button.JF_origNameFont
    local newSize = shrink and math.max(orig.size - 1, 1) or orig.size
    fs:SetFont(orig.font, newSize, orig.flags)
end

-- ------------------------------------------------------------
-- DecorateButton: 战网好友条目名字行重写（Hook 回调）
-- ------------------------------------------------------------
-- 在原版 FriendsFrame_UpdateFriendButton 执行完后调用，
-- 此时 button.buttonType / button.id / name 文本均已就绪
local function DecorateButton(button)
    if not button or button.buttonType ~= FRIENDS_BUTTON_TYPE_BNET then
        -- 非战网条目（含复用为角色条目的按钮）：还原字号，文本保持原生
        ApplyNameFont(button, false)
        return
    end

    -- 战网条目（含离线）：名字行字号缩小一号
    ApplyNameFont(button, true)

    local accountInfo = C_BattleNet.GetFriendAccountInfo(button.id)
    if not accountInfo then return end
    local gameAccountInfo = accountInfo.gameAccountInfo
    -- 仅处理「在线且正在玩 WoW 且已登录角色」的战网好友
    if not gameAccountInfo or not gameAccountInfo.isOnline then return end
    if gameAccountInfo.clientProgram ~= BNET_CLIENT_WOW then return end
    local characterName = gameAccountInfo.characterName
    if not characterName or characterName == "" then return end

    -- 职业颜色：classID -> GetClassInfo -> RAID_CLASS_COLORS
    -- 取不到职业色时回退到暴雪原有配色（可合作浅蓝/否则灰绿）
    local classFile
    if gameAccountInfo.classID then
        local _, file = GetClassInfo(gameAccountInfo.classID)
        classFile = file
    end
    local classColor = classFile and RAID_CLASS_COLORS[classFile]
    local nameColorCode
    if classColor then
        nameColorCode = classColor:GenerateHexColorMarkup()
    elseif CanCooperateWithGameAccount(accountInfo) then
        nameColorCode = FRIENDS_WOW_NAME_COLOR_CODE
    else
        nameColorCode = FRIENDS_OTHER_NAME_COLOR_CODE
    end

    -- 与暴雪一致的格式化（校验角色名并附加幻境图标）
    characterName = FriendsFrame_GetFormattedCharacterName(
        characterName, nil, gameAccountInfo.clientProgram, gameAccountInfo.timerunningSeasonID)

    -- 重建名字行：战网名 (职业色角色名) 等级
    local nameText = BNet_GetBNetAccountName(accountInfo)
    nameText = nameText .. " " .. nameColorCode .. "(" .. characterName .. ")" .. FONT_COLOR_CODE_CLOSE
    local level = gameAccountInfo.characterLevel
    if type(level) == "number" and level > 0 then
        nameText = nameText .. " " .. level
    end
    button.name:SetText(nameText)

    -- 收藏星标锚定在名字文本右侧（按字符串宽度定位），
    -- 文本变长后需同步修正，避免星标遮挡等级数字
    if button.Favorite and button.Favorite:IsShown() then
        button.Favorite:ClearAllPoints()
        button.Favorite:SetPoint("TOPLEFT", button.name, "TOPLEFT", button.name:GetStringWidth(), 0)
    end
end

-- ------------------------------------------------------------
-- InstallHook: 安装对暴雪按钮初始化函数的后置 Hook
-- ------------------------------------------------------------
local function InstallHook()
    if hooked or type(FriendsFrame_UpdateFriendButton) ~= "function" then return end
    hooked = true
    hooksecurefunc("FriendsFrame_UpdateFriendButton", function(button)
        -- 模块禁用时直接返回（hooksecurefunc 无法撤销，通过标志短路）
        if not module.enabled then return end
        DecorateButton(button)
    end)
end

-- ------------------------------------------------------------
-- RefreshList: 立即重建好友列表，让改动即时生效/还原
-- ------------------------------------------------------------
local function RefreshList()
    if type(FriendsList_Update) == "function" then
        FriendsList_Update(true)
    end
end

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
function module:OnEnable()
    if C_AddOns.IsAddOnLoaded("Blizzard_FriendsFrame") then
        InstallHook()
    else
        -- Blizzard_FriendsFrame 按需加载：等其加载完成后再 Hook
        local loader = CreateFrame("Frame")
        loader:RegisterEvent("ADDON_LOADED")
        loader:SetScript("OnEvent", function(self, event, loadedAddon)
            if loadedAddon ~= "Blizzard_FriendsFrame" then return end
            self:UnregisterAllEvents()
            -- 等待期间模块可能已被禁用，此处再检查一次
            if module.enabled then
                InstallHook()
                RefreshList()
            end
        end)
    end
    RefreshList()
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
-- 还原所有已创建按钮的名字行字号，并刷新列表让文本恢复原生样式
-- （Hook 仍存在但内部因 enabled = false 短路）
function module:OnDisable()
    if FriendsListFrame and FriendsListFrame.ScrollBox then
        FriendsListFrame.ScrollBox:ForEachFrame(function(button)
            if button.JF_origNameFont and button.name then
                local orig = button.JF_origNameFont
                button.name:SetFont(orig.font, orig.size, orig.flags)
            end
        end)
    end
    RefreshList()
end
