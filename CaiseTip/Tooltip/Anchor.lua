----------------------------------------------------------------------
-- CaiseTip / Tooltip / Anchor
-- 鼠标跟随、锚点逻辑（纯定位）
----------------------------------------------------------------------

local P = select(2, ...)

local isSecret = P.IsSecret

--- 更新工具提示位置
-- [[ 鼠标提示跟随逻辑及智能角对角吸附 ]]
local function SmartAnchor(tooltip, owner, userOffsetX, userOffsetY)
    if not owner or owner:IsForbidden() then return end

    -- 使用 pcall 包装 GetRect，防止在受限区域（如战斗中的姓名板）报错
    local ok, left, bottom, width, height = pcall(owner.GetRect, owner)
    if not ok or not left then return end

    -- 屏幕中心点坐标
    local screenWidth = GetScreenWidth()
    local screenHeight = GetScreenHeight()
    local centerX = screenWidth / 2
    local centerY = screenHeight / 2

    -- owner(按钮/动作条) 中心点坐标 and 尺寸
    --local left, bottom, width, height = owner:GetRect()
    if isSecret(left) or isSecret(bottom) or isSecret(width) or isSecret(height) then
        -- 如果 GetRect 返回被污染的秘密值，回退到基础右下跟随
        --tooltip:SetOwner(owner, "ANCHOR_NONE")
        return
    end

    local scale = owner:GetEffectiveScale()
    local oX = (left + width / 2) * scale
    local oY = (bottom + height / 2) * scale

    -- 判断 owner 所在的象限
    local isRightHalf = oX > centerX
    local isTopHalf = oY > centerY

    tooltip:SetOwner(owner, "ANCHOR_NONE")
    tooltip:ClearAllPoints()

    -- 智能角对角逻辑
    if isRightHalf then
        -- 屏幕右边：提示框右下角对齐按钮左上角
        tooltip:SetPoint("BOTTOMRIGHT", owner, "TOPLEFT")
    else
        -- 屏幕左边或中间：提示框左下角对齐按钮右上角
        tooltip:SetPoint("BOTTOMLEFT", owner, "TOPRIGHT")
    end
end

local anchorMap = {
    NONE = "ANCHOR_NONE",
    RIGHT = "ANCHOR_CURSOR_RIGHT",
    LEFT = "ANCHOR_CURSOR_LEFT",
    TOP = "ANCHOR_CURSOR", -- 好像无法调整位置
}

-- [[ 动态鼠标跟随 (针对 CURSOR_BR 模式) ]]
local function GetCursorAnchorPos(tooltip)
    local scale = UIParent:GetEffectiveScale() * (tooltip:GetScale() or 1)
    local x, y = GetCursorPosition()

    local dbAnchor = P.db.anchor or "NONE"
    local base = P.db.baseOffset[dbAnchor] or { x = 0, y = 0 }

    x = x / scale + (base.x or 0)
    y = y / scale + (base.y or 0)
    return x, y
end

local function UpdateCursorAnchor(self)
    if not self or self:IsForbidden() then return end
    local x, y = GetCursorAnchorPos(self)
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
end

function P.GetAnchor(self, parent)
    if self ~= GameTooltip or self:IsForbidden() then return end

    local dbAnchor = P.db.anchor or "NONE"
    local anchorMode = anchorMap[dbAnchor] or "ANCHOR_NONE"

    -- 如果设置为不跟随且不是特殊的右下跟随模式
    if anchorMode == "ANCHOR_NONE" and dbAnchor ~= "CURSOR_BR" then
        return
    end

    -- 直接从 baseOffset 读取当前方向的偏移值
    local base = P.db.baseOffset[dbAnchor] or P.db.baseOffset.NONE
    local offsetX = base.x or 0
    local offsetY = base.y or 0
    local owner = self:GetOwner()

    -- 战斗状态检查
    if InCombatLockdown() then
        -- 如果启用了"仅战斗外跟随"，战斗中不进行任何锚点设置（使用默认位置）
        if P.db.combatFollow then
            return
        end
    end

    -- 锚点设置逻辑
    if owner == UIParent or owner == WorldFrame then
        if dbAnchor == "CURSOR_BR" then
            UpdateCursorAnchor(self)
        else
            self:SetOwner(owner, anchorMode, offsetX, offsetY)
        end
    else
        SmartAnchor(self, owner)
    end
end

-- 挂钩 OnUpdate 以实现实时跟随
GameTooltip:HookScript("OnUpdate", function(self, elapsed)
    if self:IsShown() and P.db.anchor == "CURSOR_BR" then
        local owner = self:GetOwner()
        if owner == UIParent or owner == WorldFrame then
            UpdateCursorAnchor(self)
        end
    end
end)
