-- ============================================================
-- JustinForge 模块3: 商人窗口扩展 (MerchantExpand.lua)
-- ============================================================
-- 功能描述：
--   将商人窗口加宽为多列布局（列数 2-5 可调，不改变窗口高度），
--   商人页每页为 列数×5 个物品，回购页同步扩展为 列数×6；
--   并重新排列修理、出售垃圾、翻页按钮与货币栏，修复加宽后
--   底部边框纹理截断与货币栏接缝的视觉问题。
--   （布局方案借鉴 ExwindTools 的 MerchantExpansion 子模块，
--     保留本插件特有的 OnDisable 恢复逻辑）
--
-- 实现原理：
--   1. 设置 MERCHANT_ITEMS_PER_PAGE / BUYBACK_ITEMS_PER_PAGE
--      全局变量，暴雪分页逻辑按新容量翻页
--   2. 按公式 11 + 列数*153 + (列数-1)*12 + 19 计算窗口宽度
--   3. 应用扩展时用原生 MerchantItemTemplate 一次性补建按钮
--      （必须先于暴雪首次刷新，详见 EnsureItemButtons 注释）
--   4. Hook MerchantFrame_Update（统一刷新入口，覆盖切页/切Tab）
--      与 MerchantFrame_UpdateRepairButtons，每次刷新重排布局
--   5. 物品按列优先纵向填充（与原版一致：先填满一列再向右排），
--      容量内按钮显隐完全交给暴雪刷新逻辑管理，绝不强制显示
--      （空槽位被强制显示会遮挡底部修理按钮，并在回购页叠加
--      残留的购买页内容）
--   6. 底部处理：隐藏原生底部左边框，用 UI-Merchant-BotFrame
--      图集纹理整段重铺；货币栏拉成单一全宽 inset 消除接缝
--
-- 关键细节（来自 ExwindTools 的实战经验）：
--   - 所有重排必须先 ClearAllPoints 再 SetPoint：暴雪
--     MerchantFrame_UpdateRepairButtons 内部 SetPoint 不清点，
--     锚点叠加会导致按钮图标变形
--   - HookScript("OnShow") 与 hooksecurefunc 均为后置 Hook，
--     首次打开时暴雪原生刷新必然先执行，因此扩展按钮必须在
--     改写 MERCHANT_ITEMS_PER_PAGE 的同一时刻提前补建到位，
--     否则暴雪按新容量索引 MerchantItem 按钮会 nil 报错
--   - hooksecurefunc 回调内不可再调用 MerchantFrame_Update，
--     否则会递归触发自身
--
-- 加载时机说明：
--   12.0 起商人框架并入随客户端加载的 Blizzard_UIPanels_Game，
--   插件加载时 MerchantFrame 通常已存在，OnEnable 会直接应用；
--   ADDON_LOADED 等待 Blizzard_MerchantUI 的分支仅作旧版按需
--   加载结构的兜底保留。
--
-- 禁用说明：
--   hooksecurefunc/HookScript 无法卸载，已挂载的 Hook 通过
--   enabled 标志短路为空操作。禁用时恢复每页物品数/窗口宽度、
--   隐藏扩展按钮与自建纹理、恢复被隐藏的原生底部元素；
--   已重排的锚点需 /reload 后完全复原。
-- ============================================================

local addonName, ns = ...

local L = ns.L
local Util = ns.Util

-- ============================================================
-- 模块注册
-- ============================================================
-- 注册到模块框架，key 必须与 Init.lua defaults 表中的键名一致
-- options 声明列数滑条，值绑定到 DB.profile.merchantExpand.columns
local module = ns.Module:Register({
    key            = "merchantExpand",
    name           = L["MerchantExpand_Name"],
    description    = L["MerchantExpand_Desc"],
    defaultEnabled = true,
    options = {
        { type = "slider", key = "columns", name = L["MerchantExpand_Columns"],
          min = 2, max = 5, step = 1, default = 4, tooltip = L["MerchantExpand_ColumnsTip"] },
    },
})

-- 列数范围与默认值的兜底常量
local MIN_COLUMNS = 2
local MAX_COLUMNS = 5
local DEFAULT_COLUMNS = 4  -- 4列×5行 = 每页 20 个，与旧版 2×10 方案容量一致

-- 行数固定，保持原版窗口高度不变
local MERCHANT_ROWS = 5  -- 商人页行数
local BUYBACK_ROWS  = 6  -- 回购页行数
-- 物品按钮创建上限（5列×6行），覆盖商人页与回购页的最大需求
local MAX_ITEMS = MAX_COLUMNS * BUYBACK_ROWS

-- 单个物品格宽度与水平间距（原版固有几何尺寸）
local ITEM_WIDTH = 153
local SPACING_X = 12

-- 原版每页物品数（首次应用扩展时从全局变量捕获，禁用时恢复）
-- 注意：文件加载时 Blizzard_MerchantUI 尚未加载，全局变量不存在，
-- 只能在 ApplyMerchantExpand 中捕获真实值，此处先声明
local originalItemsPerPage
local originalBuybackPerPage
-- 保存原始窗口宽度，禁用时恢复
local originalWidth
-- 标志：暴雪商人框架是否已加载、扩展是否已应用
local applied = false
-- 等待商人框架加载的事件 Frame（懒创建）
local loaderFrame
-- 当前窗口宽度，供修理按钮居中计算使用
local currentWidth = 0
-- 自建底部边框纹理（懒创建）
local bottomBorder

-- ------------------------------------------------------------
-- GetColumns: 读取当前配置的列数（带范围兜底）
-- ------------------------------------------------------------
local function GetColumns()
    local db = ns.db and ns.db.profile and ns.db.profile.merchantExpand
    local cols = db and tonumber(db.columns) or DEFAULT_COLUMNS
    if cols < MIN_COLUMNS then return MIN_COLUMNS end
    if cols > MAX_COLUMNS then return MAX_COLUMNS end
    return cols
end

-- ------------------------------------------------------------
-- EnsureBottomBorder: 懒创建自建底部边框纹理
-- ------------------------------------------------------------
-- 原生 MerchantFrameBottomLeftBorder 纹理只覆盖原始宽度，加宽后
-- 右侧会出现截断。用同一段 UI-Merchant-BotFrame 图集纹理整段
-- 重铺底部，避免中心拼接线。
local function EnsureBottomBorder()
    if bottomBorder then return end
    bottomBorder = MerchantFrame:CreateTexture(nil, "OVERLAY")
    bottomBorder:SetAtlas("UI-Merchant-BotFrame")
end

-- ------------------------------------------------------------
-- UpdateBottomBorder: 按当前页更新底部边框
-- ------------------------------------------------------------
local function UpdateBottomBorder(isBuyback)
    EnsureBottomBorder()

    -- 原生底部左边框只适配原始宽度，始终隐藏
    if MerchantFrameBottomLeftBorder then
        MerchantFrameBottomLeftBorder:Hide()
    end

    -- 回购页底部由原生其他纹理覆盖，无需重铺
    if isBuyback then
        bottomBorder:Hide()
        return
    end

    bottomBorder:Show()
    bottomBorder:ClearAllPoints()
    bottomBorder:SetPoint("BOTTOMLEFT", MerchantFrame, "BOTTOMLEFT", 1, 26)
    bottomBorder:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -1, 87)
    bottomBorder:SetTexCoord(0.02, 0.47, 0, 1)
end

-- ------------------------------------------------------------
-- UpdateBottomInsets: 统一底部货币栏为单一全宽 inset
-- ------------------------------------------------------------
-- 暴雪原生将底部拆成左右两个 inset（额外货币区 + 金币区），
-- 加宽布局下中间接缝明显。隐藏额外货币区，金币区拉通全宽。
local function UpdateBottomInsets()
    if MerchantExtraCurrencyInset then
        MerchantExtraCurrencyInset:Hide()
    end
    if MerchantExtraCurrencyBg then
        MerchantExtraCurrencyBg:Hide()
    end

    if MerchantMoneyInset then
        MerchantMoneyInset:Show()
        MerchantMoneyInset:ClearAllPoints()
        MerchantMoneyInset:SetPoint("TOPLEFT", MerchantFrame, "BOTTOMLEFT", 4, 27)
        MerchantMoneyInset:SetPoint("BOTTOMRIGHT", MerchantFrame, "BOTTOMRIGHT", -5, 4)
        if MerchantMoneyInset.Bg then
            MerchantMoneyInset.Bg:SetTexture("Interface\\Buttons\\WHITE8X8")
            MerchantMoneyInset.Bg:SetHorizTile(false)
            MerchantMoneyInset.Bg:SetVertTile(false)
            MerchantMoneyInset.Bg:SetVertexColor(0, 0, 0, 0.35)
        end
    end

    if MerchantMoneyBg then
        MerchantMoneyBg:Show()
        MerchantMoneyBg:ClearAllPoints()
        MerchantMoneyBg:SetPoint("TOPLEFT", MerchantFrame, "BOTTOMLEFT", 7, 25)
        MerchantMoneyBg:SetPoint("BOTTOMRIGHT", MerchantFrame, "BOTTOMRIGHT", -7, 6)
        if MerchantMoneyBgMiddle then
            MerchantMoneyBgMiddle:SetTexture("Interface\\Buttons\\WHITE8X8")
            MerchantMoneyBgMiddle:SetTexCoord(0, 1, 0, 1)
            MerchantMoneyBgMiddle:SetVertexColor(0, 0, 0, 1)
        end
    end
end

-- ------------------------------------------------------------
-- FixRepairButtons: 修理/卖垃圾按钮组底部居中排列
-- ------------------------------------------------------------
-- 暴雪 MerchantFrame_UpdateRepairButtons 内部 SetPoint 前不做
-- ClearAllPoints，多次刷新会锚点叠加导致图标变形。这里在其
-- 执行完毕后统一清点重排，按按钮显示状态组合布局：
--   [修理单件] [修理全部] [出售垃圾] [公会修理]
local function FixRepairButtons()
    if not module.enabled or not applied then return end
    if not MerchantFrame or not MerchantFrame:IsShown() then return end

    local centerX = currentWidth / 2
    local btnY = 34

    if MerchantRepairAllButton and MerchantRepairAllButton:IsShown() then
        MerchantRepairAllButton:ClearAllPoints()
        MerchantRepairAllButton:SetPoint("BOTTOM", MerchantFrame, "BOTTOMLEFT", centerX + 10, btnY)
    end

    if MerchantRepairItemButton and MerchantRepairItemButton:IsShown() then
        MerchantRepairItemButton:ClearAllPoints()
        MerchantRepairItemButton:SetPoint("RIGHT", MerchantRepairAllButton, "LEFT", -4, 0)
    end

    if MerchantSellAllJunkButton then
        MerchantSellAllJunkButton:ClearAllPoints()
        if MerchantRepairAllButton and MerchantRepairAllButton:IsShown() then
            -- 有修理按钮时排在修理全部右侧
            MerchantSellAllJunkButton:SetPoint("LEFT", MerchantRepairAllButton, "RIGHT", 12, 0)
        else
            -- 无修理功能时居中显示
            MerchantSellAllJunkButton:SetPoint("BOTTOM", MerchantFrame, "BOTTOMLEFT", centerX, btnY)
        end
    end

    if MerchantGuildBankRepairButton and MerchantGuildBankRepairButton:IsShown() then
        MerchantGuildBankRepairButton:ClearAllPoints()
        MerchantGuildBankRepairButton:SetPoint("LEFT", MerchantSellAllJunkButton, "RIGHT", 4, 0)
    end
end

-- ------------------------------------------------------------
-- EnsureItemButtons: 提前补建全部扩展物品按钮
-- ------------------------------------------------------------
-- 关键时机：暴雪 MerchantFrame_UpdateMerchantInfo 按
-- MERCHANT_ITEMS_PER_PAGE 循环索引 _G["MerchantItem"..i]，
-- 而本模块在 ApplyMerchantExpand 阶段就把容量改写为扩展值。
-- 暴雪原生刷新先于所有后置 Hook 执行，若等首次刷新再补建
-- 按钮，原生循环会因按钮不存在而 nil 报错。因此按钮必须与
-- 容量改写同时补建到位，补建后先隐藏，显隐由后续刷新决定。
-- 幂等：已补建过的会话内直接返回。
local buttonsReady = false
local function EnsureItemButtons()
    if buttonsReady then return true end
    for i = 1, MAX_ITEMS do
        local name = "MerchantItem" .. i
        if not _G[name] then
            local ok, err = pcall(CreateFrame, "Frame", name, MerchantFrame, "MerchantItemTemplate")
            if not ok or not _G[name] then
                Util:Error("创建商人扩展按钮失败（暴雪可能已重构模板）: " .. tostring(err))
                return false
            end
            _G[name]:Hide()
        end
    end
    buttonsReady = true
    return true
end

-- ------------------------------------------------------------
-- ApplyLayout: 应用整体布局（容量/宽度/底部/翻页按钮）
-- ------------------------------------------------------------
-- 作为 MerchantFrame_Update 与 OnShow 的 Hook 在每次刷新时调用，
-- 也在列数设置变化时主动调用
local function ApplyLayout()
    if not MerchantFrame then return end

    local cols = GetColumns()
    local isBuyback = (MerchantFrame.selectedTab == 2)
    local rows = isBuyback and BUYBACK_ROWS or MERCHANT_ROWS
    local itemsPerPage = cols * rows

    -- 两个全局容量固定设置（不随 Tab 抖动），暴雪分页逻辑读取
    _G.MERCHANT_ITEMS_PER_PAGE = cols * MERCHANT_ROWS
    _G.BUYBACK_ITEMS_PER_PAGE = cols * BUYBACK_ROWS

    -- 按钮已在 ApplyMerchantExpand 中提前补建（见 EnsureItemButtons）。
    -- 此处只隐藏超出当前页容量的按钮（切 Tab / 减少列数后收编，
    -- 复用不销毁）；容量内按钮的显隐必须完全交给暴雪刷新逻辑管理：
    -- 无物品的槽位暴雪会隐藏，若强制显示，空槽会遮挡底部修理按钮，
    -- 回购页还会叠加显示残留的购买页内容
    EnsureItemButtons()
    for i = itemsPerPage + 1, MAX_ITEMS do
        local item = _G["MerchantItem" .. i]
        if item then
            item:Hide()
        end
    end

    -- 只加宽，高度保持原版
    local newWidth = 11 + cols * ITEM_WIDTH + (cols - 1) * SPACING_X + 19
    MerchantFrame:SetWidth(newWidth)
    currentWidth = newWidth

    UpdateBottomBorder(isBuyback)
    UpdateBottomInsets()

    -- 翻页文字居中，翻页按钮分列窗口底部两端
    local centerX = newWidth / 2
    if MerchantPageText then
        MerchantPageText:ClearAllPoints()
        MerchantPageText:SetPoint("BOTTOM", MerchantFrame, "BOTTOMLEFT", centerX, 86)
    end
    if MerchantPrevPageButton then
        MerchantPrevPageButton:ClearAllPoints()
        MerchantPrevPageButton:SetPoint("CENTER", MerchantFrame, "BOTTOMLEFT", 25, 96)
    end
    if MerchantNextPageButton then
        MerchantNextPageButton:ClearAllPoints()
        MerchantNextPageButton:SetPoint("CENTER", MerchantFrame, "BOTTOMLEFT", newWidth - 26, 96)
    end

    -- 修理/卖垃圾按钮组统一重排
    FixRepairButtons()
end

-- ------------------------------------------------------------
-- PositionItems: 按 列数×行数 网格重排物品按钮
-- ------------------------------------------------------------
-- 布局规则（列优先纵向填充，与原版一致）：
--   - 物品1锚定窗口左上角 (11, -69)
--   - 每列从上往下依次排列，排满 rows 个后向右另起一列
--   - (i-1)%rows==0 时开启新列，锚定到上一列顶部物品的右侧
--   - 列内其余物品依次锚定到上方邻居的下方
local function PositionItems()
    if not MerchantFrame or not MerchantFrame:IsShown() then return end

    local cols = GetColumns()
    local isBuyback = (MerchantFrame.selectedTab == 2)
    local rows = isBuyback and BUYBACK_ROWS or MERCHANT_ROWS
    local offsetY = isBuyback and 15 or 8

    for i = 1, cols * rows do
        local item = _G["MerchantItem" .. i]
        if item then
            item:ClearAllPoints()
            if i == 1 then
                item:SetPoint("TOPLEFT", 11, -69)
            elseif (i - 1) % rows == 0 then
                item:SetPoint("TOPLEFT", _G["MerchantItem" .. (i - rows)], "TOPRIGHT", SPACING_X, 0)
            else
                item:SetPoint("TOPLEFT", _G["MerchantItem" .. (i - 1)], "BOTTOMLEFT", 0, -offsetY)
            end
        end
    end

    -- 回购框原生锚定 MerchantItem10，列数变化后位置错乱，
    -- 固定在窗口右下角，与修理按钮区保持分离
    if MerchantBuyBackItem and not isBuyback then
        MerchantBuyBackItem:ClearAllPoints()
        MerchantBuyBackItem:SetPoint("BOTTOMRIGHT", MerchantFrame, "BOTTOMRIGHT", -8, 33)
    end

    -- 物品总数不超一页时仍显示翻页按钮（保持禁用态），避免布局跳动
    if not isBuyback and MerchantPageText and MerchantPrevPageButton and MerchantNextPageButton then
        local numMerchantItems = securecall("GetMerchantNumItems")
        if numMerchantItems and numMerchantItems <= _G.MERCHANT_ITEMS_PER_PAGE then
            MerchantPageText:Show()
            MerchantPrevPageButton:Show()
            MerchantPrevPageButton:Disable()
            MerchantNextPageButton:Show()
            MerchantNextPageButton:Disable()
        end
    end
end

-- ------------------------------------------------------------
-- RefreshLayout: Hook 回调统一入口（带启用标志短路）
-- ------------------------------------------------------------
local function RefreshLayout()
    if not module.enabled or not applied then return end
    ApplyLayout()
    PositionItems()
end

-- ------------------------------------------------------------
-- ApplyMerchantExpand: 应用商人窗口扩展
-- ------------------------------------------------------------
-- 前置条件：Blizzard_MerchantUI 已加载（帧和全局函数可用）
-- 幂等：已应用则直接返回
local function ApplyMerchantExpand()
    if applied then return end
    if not MerchantFrame or not MerchantFrame_Update then return end

    -- 保存原始窗口宽度与每页容量（此时 MerchantUI 已加载，拿到真实值），禁用时恢复
    originalWidth = MerchantFrame:GetWidth()
    originalItemsPerPage = _G.MERCHANT_ITEMS_PER_PAGE or 10
    originalBuybackPerPage = _G.BUYBACK_ITEMS_PER_PAGE or 12

    -- 立即设置扩展容量：首次打开商人窗口时暴雪分页逻辑读取的就是新值，
    -- 不依赖下方 OnShow Hook 与原 OnShow 的执行先后
    _G.MERCHANT_ITEMS_PER_PAGE = GetColumns() * MERCHANT_ROWS
    _G.BUYBACK_ITEMS_PER_PAGE = GetColumns() * BUYBACK_ROWS

    -- 同步提前补建扩展按钮：暴雪刷新函数按新容量索引 MerchantItem 按钮，
    -- 必须在其首次执行前就位（下方 Hook 均为后置，赶不上首次刷新）。
    -- 若模板失效（暴雪重构商人框架），回滚容量保证原生窗口可用
    if not EnsureItemButtons() then
        _G.MERCHANT_ITEMS_PER_PAGE = originalItemsPerPage
        _G.BUYBACK_ITEMS_PER_PAGE = originalBuybackPerPage
        return
    end

    -- Hook 统一刷新入口：覆盖切页、切Tab、物品更新等全部路径
    -- Hook 为永久挂载（hooksecurefunc/HookScript 无法卸载），
    -- 通过模块 enabled 标志短路，禁用后等同于空操作
    -- 注意：回调内不可再调用 MerchantFrame_Update，否则会递归触发
    hooksecurefunc("MerchantFrame_Update", RefreshLayout)
    hooksecurefunc("MerchantFrame_UpdateRepairButtons", FixRepairButtons)

    -- OnShow 追加一次布局刷新（容量与按钮已在上方提前就位，此处仅兜底重排）
    MerchantFrame:HookScript("OnShow", RefreshLayout)

    applied = true

    -- 若商人窗口当前打开，立即刷新一次应用布局
    if MerchantFrame:IsShown() then
        RefreshLayout()
        MerchantFrame_Update()
    end

    Util:Debug("MerchantExpand applied")
end

-- ------------------------------------------------------------
-- RestoreMerchantExpand: 恢复商人窗口到原版状态
-- ------------------------------------------------------------
-- 恢复每页物品数/窗口宽度，隐藏扩展按钮与自建纹理，恢复被隐藏
-- 的原生底部元素。已重排的锚点与货币栏底色无法完全复原，
-- 需 /reload（Hook 已为空操作）
local function RestoreMerchantExpand()
    if not applied then return end

    -- 恢复每页物品数（暴雪分页逻辑随之回到原版）
    _G.MERCHANT_ITEMS_PER_PAGE = originalItemsPerPage
    _G.BUYBACK_ITEMS_PER_PAGE = originalBuybackPerPage

    if MerchantFrame then
        -- 恢复窗口宽度
        if originalWidth then
            MerchantFrame:SetWidth(originalWidth)
        end

        -- 隐藏扩展按钮（不销毁，便于再次启用时复用）
        for i = originalItemsPerPage + 1, MAX_ITEMS do
            local item = _G["MerchantItem" .. i]
            if item then item:Hide() end
        end

        -- 恢复底部原生元素显示
        if bottomBorder then bottomBorder:Hide() end
        if MerchantFrameBottomLeftBorder then MerchantFrameBottomLeftBorder:Show() end
        if MerchantExtraCurrencyInset then MerchantExtraCurrencyInset:Show() end
        if MerchantExtraCurrencyBg then MerchantExtraCurrencyBg:Show() end

        -- 若商人窗口当前打开，刷新显示回到原版布局
        if MerchantFrame:IsShown() and MerchantFrame_Update then
            MerchantFrame_Update()
        end
    end

    Util:Debug("MerchantExpand restored (reload 可完全复原锚点)")
end

-- ------------------------------------------------------------
-- OnEnable: 模块启用
-- ------------------------------------------------------------
-- 1. 若商人框架已加载（曾打开过商人），立即应用扩展
-- 2. 否则注册 ADDON_LOADED 等待 Blizzard_MerchantUI 按需加载
function module:OnEnable()
    if MerchantFrame and MerchantFrame_Update then
        ApplyMerchantExpand()
        return
    end

    -- 商人界面为按需加载，等待其加载完成后再应用
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
-- 1. 取消等待加载的监听
-- 2. 恢复商人窗口到原版状态
function module:OnDisable()
    if loaderFrame then
        loaderFrame:UnregisterAllEvents()
    end
    RestoreMerchantExpand()
end

-- ------------------------------------------------------------
-- OnOptionChanged: 附加设置变化回调（由 Config.lua 调用）
-- ------------------------------------------------------------
-- 列数滑条变化时立即按新列数重排；若窗口打开则触发一次
-- 暴雪原生刷新，让物品数据按新容量重新填充
function module:OnOptionChanged(key, value)
    if key ~= "columns" then return end
    if not applied or not MerchantFrame then return end

    RefreshLayout()
    if MerchantFrame:IsShown() and MerchantFrame_Update then
        MerchantFrame_Update()
    end
end
