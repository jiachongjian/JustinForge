-- ============================================================
-- JustinForge 模块: 成就对比界面报错修复 (AchievementUiFix.lua)
-- ============================================================
-- 功能描述：
--   修复暴雪 Blizzard_AchievementUI 的一个 bug：在成就「对比」视图下
--   点击顶部的「总结」伪分类时，ID 是字符串 "summary"，而它会被直接
--   传入 AchievementFrameComparison_UpdateStatusBars → GetCategoryNumAchievements，
--   后者只接受数字 categoryID，于是抛出：
--     Usage: GetCategoryNumAchievements(categoryID, includeSuperceded)
--   暴雪源码只对数字哨兵 ACHIEVEMENT_COMPARISON_SUMMARY_ID = -1 做了特判，
--   却没有挡住字符串 "summary"。
--
-- 修复方式：
--   暴力替换全局函数 AchievementFrameComparison_UpdateStatusBars，仅增加一层
--   参数守卫：当 id 不是数字时直接返回（忽略该次刷新，不影响对比结果展示），
--   数字 id（包括 -1 哨兵）原样透传，行为与暴雪默认完全一致。
--   模块禁用时还原为原始函数，零残留。
-- ============================================================

local addonName, ns = ...

local L = ns.L

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "achievementUiFix",
    name           = L["AchievementUiFix_Name"],
    description    = L["AchievementUiFix_Desc"],
    defaultEnabled = true,
})

-- ============================================================
-- 运行时状态
-- ============================================================
local eventFrame       -- 监听 Blizzard_AchievementUI 懒加载事件的 Frame
local originalFunction -- 备份的暴雪原始函数，用于禁用时还原
local patched = false  -- 是否已安装补丁

-- ============================================================
-- ApplyPatch: 安装补丁
-- ============================================================
-- 在 Blizzard_AchievementUI 完成加载后调用（此时才有目标函数）。
-- 包装函数只对非数字 id 短路，数字 id 透传原始实现。
local function ApplyPatch()
    local real = _G.AchievementFrameComparison_UpdateStatusBars
    if type(real) ~= "function" then return end

    -- 避免在重复加载/重复调用时对旧补丁再打包
    if patched then
        if originalFunction ~= real then
            -- 暴雪被（其他插件）改过，重新备份后再打
            originalFunction = real
            _G.AchievementFrameComparison_UpdateStatusBars = function(id)
                if type(id) ~= "number" then return end
                return originalFunction(id)
            end
        end
        return
    end

    originalFunction = real
    _G.AchievementFrameComparison_UpdateStatusBars = function(id)
        -- 字符串 "summary"（总结伪分类）不是合法 categoryID，直接忽略
        if type(id) ~= "number" then
            return
        end
        return originalFunction(id)
    end
    patched = true
end

-- ============================================================
-- RestorePatch: 还原补丁（禁用模块时调用，零残留）
-- ============================================================
local function RestorePatch()
    if patched and originalFunction then
        _G.AchievementFrameComparison_UpdateStatusBars = originalFunction
    end
    patched = false
    originalFunction = nil
end

-- ============================================================
-- OnEnable: 模块启用
-- ============================================================
-- Blizzard_AchievementUI 是懒加载插件，首次使用成就/鼠标提示时才会加载，
-- 因此必须同时：
--   1. 立即尝试打补丁（可能已加载）
--   2. 监听 ADDON_LOADED，在它后续加载完成时补打
function module:OnEnable()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", function(_, _, loadedAddon)
            if loadedAddon == "Blizzard_AchievementUI" then
                ApplyPatch()
            end
        end)
    end
    eventFrame:RegisterEvent("ADDON_LOADED")

    -- 已加载的情形直接打补丁
    if _G.Blizzard_AchievementUI then
        ApplyPatch()
    end
end

-- ============================================================
-- OnDisable: 模块禁用
-- ============================================================
-- 还原原始函数并停止监听，实现零开销、零残留
function module:OnDisable()
    RestorePatch()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
end