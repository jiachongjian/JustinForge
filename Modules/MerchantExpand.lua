-- ============================================================
-- JustinForge 模块3: 商人窗口扩展 (MerchantExpand.lua)
-- ============================================================
-- 功能描述：
--   将商人窗口每页物品数从默认的 10 个扩展为 20 个，
--   沿用原版布局方向（2行×5列 → 4行×5列），不改变行列方向。
--
-- 实现原理：
--   1. 读取原版 MerchantItem1~10 按钮的锚点，计算行列间距
--   2. 创建 MerchantItem11~20，复用原生 MerchantItemTemplate 模板
--   3. 按原布局方向延伸排列新增按钮（行数从2增至4）
--   4. 调整 MerchantFrame 高度以容纳新增的2行按钮
--   5. 设置 MERCHANT_ITEMS_PER_PAGE = 20，使暴雪分页逻辑按20翻页
--
-- 污染规避：
--   - 使用 CreateFrame 复用原生模板，保持视觉一致
--   - 仅修改 MERCHANT_ITEMS_PER_PAGE 全局变量（暴雪代码读取此变量分页）
--   - 不覆写暴雪函数，仅扩展按钮和调整尺寸
--
-- 注意事项（需游戏内实测）：
--   - MerchantItemTemplate 模板名在 12.0+ 是否仍有效
--   - MERCHANT_ITEMS_PER_PAGE 全局变量是否仍被暴雪代码使用
--   - 12.0+ 暴雪可能已重构商人框架，需根据实际情况调整
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "merchantExpand",
    name           = L["MerchantExpand_Name"],
    description    = L["MerchantExpand_Desc"],
    defaultEnabled = true,
})

-- 初始化完成标志：防止重复初始化
local initialized = false
-- 保存原始帧高度，禁用时恢复
local originalHeight
-- 保存原始每页物品数（默认10），禁用时恢复
local originalItemsPerPage = 10

-- 原版商人布局每行的列数（2行×5列 = 10个物品）
local NUM_COLS = 5

-- ------------------------------------------------------------
-- InitializeMerchantExpand: 初始化商人窗口扩展
-- ------------------------------------------------------------
-- 创建额外按钮、调整帧尺寸、设置每页20物品
-- 幂等设计：已初始化则直接返回
local function InitializeMerchantExpand()
    if initialized then return end
    -- 等待暴雪商人框架加载完成（首次打开商人时才可用）
    if not MerchantFrame or not MerchantItem1 then return end

    -- ---- 保存原始值用于禁用时恢复 ----
    originalHeight = MerchantFrame:GetHeight()
    if MERCHANT_ITEMS_PER_PAGE then
        originalItemsPerPage = MERCHANT_ITEMS_PER_PAGE
    end

    -- ---- 读取原版按钮布局参数 ----
    -- 通过分析 MerchantItem1 的锚点获取起始位置和参考点
    local b1 = MerchantItem1
    local point, relativeTo, relativePoint, x1, y1 = b1:GetPoint()

    -- 水平步进：按钮1到按钮2的X坐标差（同一行内相邻按钮的间距）
    local b2 = MerchantItem2
    local _, _, _, x2 = b2:GetPoint()
    local hStep = x2 - x1

    -- 垂直步进：按钮1到按钮6的Y坐标差（第一行到第二行的行距）
    -- 原版布局：1-5为第一行，6-10为第二行
    local b6 = MerchantItem6
    local _, _, _, _, y6 = b6:GetPoint()
    local vStep = y6 - y1

    -- ---- 创建额外按钮 MerchantItem11~20 ----
    -- 复用原生 MerchantItemTemplate 模板，保持视觉与原版完全一致
    -- 第5个参数 i 为按钮的序号，模板内部会用它初始化按钮ID
    for i = 11, 20 do
        if not _G["MerchantItem" .. i] then
            local button = CreateFrame("Button", "MerchantItem" .. i, MerchantFrame, "MerchantItemTemplate", i)
            if button then
                -- 计算按钮在网格中的行列位置
                -- i=11 → row=2, col=0（第三行第一个）
                -- i=15 → row=2, col=4（第三行第五个）
                -- i=16 → row=3, col=0（第四行第一个）
                local row = math.floor((i - 1) / NUM_COLS)
                local col = (i - 1) % NUM_COLS
                -- 根据行列位置和步进计算坐标
                local x = x1 + col * hStep
                local y = y1 + row * vStep
                -- 设置锚点，沿用原版的 point/relativeTo/relativePoint
                button:SetPoint(point, relativeTo, relativePoint, x, y)
                -- 初始隐藏，由暴雪更新逻辑在打开商人时显示
                button:Hide()
            else
                Util:Debug("Failed to create MerchantItem" .. i)
            end
        end
    end

    -- ---- 调整帧高度 ----
    -- 原版2行，扩展后4行，新增2行
    local extraRows = 2
    -- vStep 为负数（Y轴向下递减），取绝对值计算高度增量
    local extraHeight = extraRows * math.abs(vStep)
    MerchantFrame:SetHeight(originalHeight + extraHeight)

    -- ---- 更新每页物品数 ----
    -- 暴雪商人代码读取此全局变量决定每页显示多少物品
    -- 设为20后，翻页步进从10变为20，MerchantItem11~20 会被填充数据
    MERCHANT_ITEMS_PER_PAGE = 20

    initialized = true
    Util:Debug("MerchantExpand initialized: 20 items per page")
end

-- ------------------------------------------------------------
-- RestoreMerchantExpand: 恢复商人窗口到原版状态
-- ------------------------------------------------------------
-- 禁用时调用：隐藏额外按钮、恢复帧高度、恢复每页物品数
local function RestoreMerchantExpand()
    if not initialized then return end

    -- 隐藏额外创建的按钮（不销毁，便于再次启用时复用）
    for i = 11, 20 do
        local button = _G["MerchantItem" .. i]
        if button then
            button:Hide()
        end
    end

    -- 恢复帧高度
    if originalHeight and MerchantFrame then
        MerchantFrame:SetHeight(originalHeight)
    end

    -- 恢复每页物品数
    MERCHANT_ITEMS_PER_PAGE = originalItemsPerPage

    -- 若商人窗口当前打开，立即刷新显示
    if MerchantFrame and MerchantFrame:IsShown() and MerchantFrame_Update then
        MerchantFrame_Update()
    end

    initialized = false
    Util:Debug("MerchantExpand restored: " .. originalItemsPerPage .. " items per page")
end

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
-- 调用初始化函数创建扩展按钮和调整布局
-- 注意：若暴雪商人框架尚未加载（未打开过商人），初始化会跳过
--       需在首次打开商人时再次触发（可考虑 Hook MERCHANT_SHOW 事件补充）
function module:OnEnable()
    InitializeMerchantExpand()
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
-- 恢复商人窗口到原版10物品状态
function module:OnDisable()
    RestoreMerchantExpand()
end
