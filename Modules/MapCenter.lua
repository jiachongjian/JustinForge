-- ============================================================
-- JustinForge 模块2: 地图窗口居中 (MapCenter.lua)
-- ============================================================
-- 功能描述：
--   每次打开世界地图窗口时，自动将窗口定位到屏幕正中央。
--   仅在打开瞬间执行一次，打开后玩家仍可自由拖动窗口位置。
--
-- 实现原理：
--   1. 使用 HookScript 挂载 WorldMapFrame 的 OnShow 事件
--      （HookScript 是追加式 Hook，不覆盖暴雪原有 OnShow 逻辑）
--   2. OnShow 触发时，若窗口非最大化模式，执行 ClearAllPoints + SetPoint("CENTER")
--   3. 通过 module.enabled 标志控制是否执行居中（禁用时 Hook 仍存在但为空操作）
--
-- 设计说明：
--   - HookScript 无法撤销（暴雪 API 限制），因此禁用时不尝试移除 Hook
--   - 而是通过 enabled 标志在 Hook 内部短路，实现逻辑上的零开销
--   - 仅在非最大化（小窗口）模式下居中，避免干扰全屏地图体验
-- ============================================================

local addonName, ns = ...

local L = ns.L

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "mapCenter",
    name           = L["MapCenter_Name"],
    description    = L["MapCenter_Desc"],
    defaultEnabled = true,
})

-- Hook 是否已安装标志：防止重复 Hook（多次启用时只 Hook 一次）
local hooked = false

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
-- 挂载 WorldMapFrame 的 OnShow 事件
-- 使用 HookScript 而非 SetScript，保留暴雪原有 OnShow 逻辑
function module:OnEnable()
    if not hooked and WorldMapFrame then
        hooked = true
        -- HookScript("OnShow", func) 会在暴雪原有 OnShow 之后追加执行 func
        -- 参数 self 为 WorldMapFrame 本身
        WorldMapFrame:HookScript("OnShow", function(self)
            -- 模块禁用时直接返回（HookScript 无法撤销，通过标志短路）
            if not module.enabled then return end

            -- 仅在非最大化（小窗口）模式下居中
            -- 最大化模式为全屏地图，居中无意义且会干扰体验
            local isMaximized = self.IsMaximized and self:IsMaximized()
            if not isMaximized then
                -- ClearAllPoints 清除所有锚点，避免多锚点冲突
                self:ClearAllPoints()
                -- SetPoint("CENTER", UIParent, "CENTER", 0, 0) 将窗口中心对齐到屏幕中心
                -- UIParent 是 WoW 的根 UI 容器，其 CENTER 即屏幕中心
                self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            end
        end)
    end
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
-- 说明：HookScript 一旦安装无法撤销（暴雪 API 限制）
-- 因此此处不尝试移除 Hook，而是依赖 OnEnable 中 Hook 内部的
-- module.enabled 检查实现短路。禁用时 Hook 虽仍被调用，
-- 但第一行即 return，实际开销可忽略不计。
function module:OnDisable()
    -- 无需操作：enabled 标志已在 Hook 内部处理
end
