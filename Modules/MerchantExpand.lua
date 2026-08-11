-- ============================================================
-- JustinForge 模块3: 商人窗口扩展 (MerchantExpand.lua)
-- ============================================================
-- 功能描述：
--   将商人窗口加宽为固定的 4 列布局（每列 5 行，窗口高度保持原版
--   不变），商人页每页为 4×5 = 20 个物品；
--   并重新排列翻页按钮、修理/出售垃圾按钮、回购框与货币栏。
--
-- 实现逻辑（以 EnhanceQoL 插件的 Merchant 子模块为蓝本重构）：
--   1. 仅改写 MERCHANT_ITEMS_PER_PAGE 全局变量为 20（4列×5行），
--      暴雪分页/刷新逻辑按新容量工作；BUYBACK_ITEMS_PER_PAGE
--      保持原版 12 不动，回购页只重排前 12 个槽位并隐藏其余
--   2. 布局单元为「10 物品块」（2 列×5 行）：块内奇数位向下堆叠、
--      偶数位排到左侧邻居右边；每满 10 个另起一块排到上一块右侧
--   3. 按钮按需补建（MerchantItemTemplate），显隐交给暴雪刷新，
--      仅在回购页隐藏超出 BUYBACK_ITEMS_PER_PAGE 的槽位
--   4. 三个 hooksecurefunc 分别挂暴雪原生分类刷新函数：
--        MerchantFrame_UpdateMerchantInfo  → 商人页槽位重排
--        MerchantFrame_UpdateBuybackInfo   → 回购页槽位重排
--        MerchantFrame_UpdateRepairButtons → 出售垃圾按钮位置
--      （后置 Hook 随原生刷新逐路径触发，无需 Hook OnShow）
--   5. 窗口宽度按公式 36 + 165×4 = 696 计算（与 EnhanceQoL 一致）
--
-- 与旧实现的关键差异（旧实现问题根因）：
--   - 旧实现同时改写 BUYBACK_ITEMS_PER_PAGE 并按列优先重排回购页，
--     导致回购页与购买页槽位错位叠加
--   - 旧实现自建底部边框纹理、重铺货币栏底色，引入截断与接缝；
--     EnhanceQoL 方案只做锚点移动，不新建任何纹理
--   - 旧实现 Hook 统一的 MerchantFrame_Update 再在回调里做全部
--     工作，时序敏感；EnhanceQoL 直接挂两个分类刷新函数，各司其职
--
-- 加载时机说明：
--   12.0 起商人框架并入随客户端加载的 Blizzard_UIPanels_Game，
--   插件加载时 MerchantFrame 已存在，OnEnable 直接应用；
--   ADDON_LOADED 等待 Blizzard_MerchantUI 的分支仅作旧版兜底。
--
-- 禁用说明：
--   hooksecurefunc 无法卸载，已挂载的 Hook 通过 enabled 标志短路。
--   禁用时恢复每页物品数与窗口宽度；已重排的锚点需 /reload
--   后完全复原（与 EnhanceQoL 行为一致）。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

-- ============================================================
-- 模块注册
-- ============================================================
-- 注册到模块框架，key 必须与 Init.lua defaults 表中的键名一致
-- 列数固定为 4（4列×5行 = 每页 20 个，与 EnhanceQoL 一致），不提供设置选项
local COLUMNS = 4          -- 固定列数
local MAX_ITEMS = 20       -- 按钮创建上限（4列×5行 = 20）

local SUBPAGE_SIZE = 10   -- 每个布局块的物品数（2列×5行）

local module = ns.Module:Register({
    key            = "merchantExpand",
    name           = L["MerchantExpand_Name"],
    description    = L["MerchantExpand_Desc"],
    defaultEnabled = true,
})

-- 原版每页物品数（应用扩展时从全局变量捕获，禁用时恢复）
local originalItemsPerPage
-- 保存原始窗口宽度，禁用时恢复
local originalWidth
-- 标志：扩展是否已应用、Hook 是否已挂载
local applied = false
local hooked = false
-- 等待商人框架加载的事件 Frame（懒创建，旧版兜底）
local loaderFrame

-- ------------------------------------------------------------
-- RebuildMerchantFrame: 设置窗口宽度并补建物品按钮
-- ------------------------------------------------------------
-- 对应 EnhanceQoL 的 RebuildMerchantFrame：
-- 只在容量改写后执行，保证暴雪首次按新容量刷新时按钮已就位
local function RebuildMerchantFrame()
    if not module.enabled or not MerchantFrame then return end
    MerchantFrame:SetWidth(36 + 165 * COLUMNS)
    for i = 1, _G.MERCHANT_ITEMS_PER_PAGE do
        if not _G["MerchantItem" .. i] then
            CreateFrame("Frame", "MerchantItem" .. i, MerchantFrame, "MerchantItemTemplate")
        end
    end
end

-- ------------------------------------------------------------
-- UpdateSlotPositions: 商人页槽位重排（EnhanceQoL 同款算法）
-- ------------------------------------------------------------
-- 挂 MerchantFrame_UpdateMerchantInfo 的后置 Hook。
-- 布局规则（10 物品块，2列×5行）：
--   - 每块第 1 个（i%10==1）：i==1 锚定窗口左上角 (24, -70)，
--     否则锚定到上一块第 2 个物品（i-9）的右侧
--   - 块内奇数位：锚定到同块上上个物品（i-2）的下方
--   - 块内偶数位：锚定到左侧邻居（i-1）的右边
local function UpdateSlotPositions()
    if not module.enabled or not MerchantFrame then return end
    local vertSpacing = -16
    local horizSpacing = 12
    local perSubpage = SUBPAGE_SIZE

    for i = 1, _G.MERCHANT_ITEMS_PER_PAGE do
        local buy_slot = _G["MerchantItem" .. i]
        if buy_slot then
            buy_slot:Show()
            if (i % perSubpage) == 1 then
                if i == 1 then
                    buy_slot:SetPoint("TOPLEFT", MerchantFrame, "TOPLEFT", 24, -70)
                else
                    buy_slot:SetPoint("TOPLEFT", _G["MerchantItem" .. (i - (perSubpage - 1))], "TOPRIGHT", 12, 0)
                end
            else
                if (i % 2) == 1 then
                    buy_slot:SetPoint("TOPLEFT", _G["MerchantItem" .. (i - 2)], "BOTTOMLEFT", 0, vertSpacing)
                else
                    buy_slot:SetPoint("TOPLEFT", _G["MerchantItem" .. (i - 1)], "TOPRIGHT", horizSpacing, 0)
                end
            end
        end
    end

    -- 物品总数不超一页时仍显示翻页按钮（保持禁用态），避免布局跳动
    local numMerchantItems = securecall("GetMerchantNumItems")
    if numMerchantItems and numMerchantItems <= _G.MERCHANT_ITEMS_PER_PAGE then
        MerchantPageText:Show()
        MerchantPrevPageButton:Show()
        MerchantPrevPageButton:Disable()
        MerchantNextPageButton:Show()
        MerchantNextPageButton:Disable()
    end
end

-- ------------------------------------------------------------
-- UpdateBuyBackSlotPositions: 回购页槽位重排（EnhanceQoL 同款）
-- ------------------------------------------------------------
-- 挂 MerchantFrame_UpdateBuybackInfo 的后置 Hook。
-- 回购页保持原版 3 列布局、12 个容量，超出容量的槽位隐藏。
local function UpdateBuyBackSlotPositions()
    if not module.enabled or not MerchantFrame then return end
    local vertSpacing = -30
    local horizSpacing = 50

    for i = 1, _G.MERCHANT_ITEMS_PER_PAGE do
        local buyback_slot = _G["MerchantItem" .. i]
        if buyback_slot then
            if i > _G.BUYBACK_ITEMS_PER_PAGE then
                buyback_slot:Hide()
            else
                if i == 1 then
                    buyback_slot:SetPoint("TOPLEFT", MerchantFrame, "TOPLEFT", 64, -105)
                else
                    if (i % 3) == 1 then
                        buyback_slot:SetPoint("TOPLEFT", _G["MerchantItem" .. (i - 3)], "BOTTOMLEFT", 0, vertSpacing)
                    else
                        buyback_slot:SetPoint("TOPLEFT", _G["MerchantItem" .. (i - 1)], "TOPRIGHT", horizSpacing, 0)
                    end
                end
            end
        end
    end
end

-- ------------------------------------------------------------
-- RebuildTokenPositions: 货币栏重排（EnhanceQoL 同款）
-- ------------------------------------------------------------
-- 金币区固定在窗口右下角，额外货币区贴到金币区左侧，
-- 代币按钮按数量从右往左排列。只做锚点移动，不改底色纹理。
local function RebuildTokenPositions()
    if not module.enabled or not MerchantFrame then return end

    if MerchantMoneyBg then
        MerchantMoneyBg:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -8, 25)
        MerchantMoneyBg:SetPoint("BOTTOMLEFT", MerchantFrame, "BOTTOMRIGHT", -169, 6)
    end

    if MerchantExtraCurrencyInset and MerchantMoneyInset then
        MerchantExtraCurrencyInset:ClearAllPoints()
        MerchantExtraCurrencyInset:SetPoint("TOPLEFT", MerchantMoneyInset, "TOPLEFT", -171, 0)
        MerchantExtraCurrencyInset:SetPoint("BOTTOMRIGHT", MerchantMoneyInset, "BOTTOMLEFT", 0, 0)
    end

    if MerchantExtraCurrencyBg and MerchantMoneyBg then
        MerchantExtraCurrencyBg:ClearAllPoints()
        MerchantExtraCurrencyBg:SetPoint("TOPLEFT", MerchantMoneyBg, "TOPLEFT", -171, 0)
        MerchantExtraCurrencyBg:SetPoint("BOTTOMRIGHT", MerchantMoneyBg, "BOTTOMLEFT", -3, 0)
    end

    local currencies = { GetMerchantCurrencies() }
    MerchantFrame.numCurrencies = #currencies
    for index = 1, MerchantFrame.numCurrencies do
        local tokenButton = _G["MerchantToken" .. index]
        if tokenButton then
            tokenButton:ClearAllPoints()
            if index == 1 then
                tokenButton:SetPoint("BOTTOMRIGHT", -16, 8)
            elseif index == 4 then
                tokenButton:SetPoint("RIGHT", _G["MerchantToken" .. index - 1], "LEFT", -15, 0)
            else
                tokenButton:SetPoint("RIGHT", _G["MerchantToken" .. index - 1], "LEFT", 0, 0)
            end
        end
    end
end

-- ------------------------------------------------------------
-- RebuildSellAllJunkButtonPositions: 出售垃圾按钮（EnhanceQoL 同款）
-- ------------------------------------------------------------
-- 挂 MerchantFrame_UpdateRepairButtons 的后置 Hook：
-- 商人不可修理时，出售垃圾按钮贴到回购框左侧
local function RebuildSellAllJunkButtonPositions()
    if not module.enabled then return end
    if not securecall("CanMerchantRepair") then
        if MerchantSellAllJunkButton and MerchantBuyBackItem then
            MerchantSellAllJunkButton:SetPoint("RIGHT", MerchantBuyBackItem, "LEFT", -18, 0)
        end
    end
end

-- ------------------------------------------------------------
-- RebuildGuildBankRepairButtonPositions: 公会修理按钮位置
-- ------------------------------------------------------------
local function RebuildGuildBankRepairButtonPositions()
    if not module.enabled then return end
    if MerchantGuildBankRepairButton and MerchantRepairAllButton then
        MerchantGuildBankRepairButton:SetPoint("LEFT", MerchantRepairAllButton, "RIGHT", 10, 0)
    end
end

-- ------------------------------------------------------------
-- RebuildBuyBackItemPositions: 回购框位置（EnhanceQoL 同款）
-- ------------------------------------------------------------
-- 固定锚定 MerchantItem10 下方，与商人页布局联动
local function RebuildBuyBackItemPositions()
    if not module.enabled then return end
    if MerchantBuyBackItem and MerchantItem10 then
        MerchantBuyBackItem:SetPoint("TOPLEFT", MerchantItem10, "BOTTOMLEFT", 17, -20)
    end
end

-- ------------------------------------------------------------
-- RebuildPageButtonPositions: 翻页按钮/页码位置（EnhanceQoL 同款）
-- ------------------------------------------------------------
-- 位置按原版相对底部居中的固定偏移，不随列数变化
local function RebuildPageButtonPositions()
    if not module.enabled then return end
    MerchantPrevPageButton:SetPoint("CENTER", MerchantFrame, "BOTTOM", 36, 55)
    MerchantPageText:SetPoint("BOTTOM", MerchantFrame, "BOTTOM", 166, 50)
    MerchantNextPageButton:SetPoint("CENTER", MerchantFrame, "BOTTOM", 296, 55)
end

-- ------------------------------------------------------------
-- ApplyMerchantExpand: 应用商人窗口扩展
-- ------------------------------------------------------------
-- 对应 EnhanceQoL 的 MerchantMod:Enable()：
-- 改写容量 → 补建按钮/设宽 → 静态部件重排 → 挂载 Hook →
-- 若窗口已打开则立即按新布局执行一次槽位重排
local function ApplyMerchantExpand()
    if applied then return end
    if not MerchantFrame then return end

    -- 保存原始窗口宽度与每页容量（此时全局变量已存在），禁用时恢复
    originalWidth = MerchantFrame:GetWidth()
    originalItemsPerPage = _G.MERCHANT_ITEMS_PER_PAGE or 10

    -- 扩展容量（仅商人页；回购页容量保持原版 12 不动）
    _G.MERCHANT_ITEMS_PER_PAGE = COLUMNS * 5

    RebuildMerchantFrame()
    RebuildPageButtonPositions()
    RebuildBuyBackItemPositions()
    RebuildTokenPositions()
    RebuildGuildBankRepairButtonPositions()

    -- 永久 Hook（hooksecurefunc 无法卸载），通过 enabled 标志短路
    if not hooked then
        hooksecurefunc("MerchantFrame_UpdateRepairButtons", RebuildSellAllJunkButtonPositions)
        hooksecurefunc("MerchantFrame_UpdateMerchantInfo", UpdateSlotPositions)
        hooksecurefunc("MerchantFrame_UpdateBuybackInfo", UpdateBuyBackSlotPositions)
        hooked = true
    end

    applied = true

    -- 若商人窗口当前打开，立即应用一次布局
    if MerchantFrame:IsShown() then
        UpdateSlotPositions()
        UpdateBuyBackSlotPositions()
    end

    Util:Debug("MerchantExpand applied")
end

-- ------------------------------------------------------------
-- RestoreMerchantExpand: 恢复商人窗口到原版状态
-- ------------------------------------------------------------
-- 恢复每页物品数与窗口宽度，隐藏扩展按钮。已重排的锚点
-- 无法完全复原，需 /reload（与 EnhanceQoL 行为一致）
local function RestoreMerchantExpand()
    if not applied then return end

    _G.MERCHANT_ITEMS_PER_PAGE = originalItemsPerPage

    if MerchantFrame then
        if originalWidth then
            MerchantFrame:SetWidth(originalWidth)
        end
        for i = originalItemsPerPage + 1, MAX_ITEMS do
            local item = _G["MerchantItem" .. i]
            if item then item:Hide() end
        end
        if MerchantFrame:IsShown() and MerchantFrame_Update then
            MerchantFrame_Update()
        end
    end

    Util:Debug("MerchantExpand restored (reload 可完全复原锚点)")
end

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
function module:OnEnable()
    if MerchantFrame and MerchantFrame_Update then
        ApplyMerchantExpand()
        return
    end

    -- 旧版按需加载结构的兜底：等待商人框架加载完成后再应用
    if not loaderFrame then
        loaderFrame = CreateFrame("Frame")
        loaderFrame:SetScript("OnEvent", function(self, _, loadedAddon)
            if loadedAddon ~= "Blizzard_MerchantUI" then return end
            self:UnregisterEvent("ADDON_LOADED")
            if module.enabled then
                ApplyMerchantExpand()
            end
        end)
    end
    loaderFrame:RegisterEvent("ADDON_LOADED")
end

-- ------------------------------------------------------------
-- OnDisable: 模块禁用
-- ------------------------------------------------------------
function module:OnDisable()
    if loaderFrame then
        loaderFrame:UnregisterAllEvents()
    end
    RestoreMerchantExpand()
end

-- 无运行时可调设置，故不需要 OnOptionChanged 处理
