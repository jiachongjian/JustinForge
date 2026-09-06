-- ============================================================
-- JustinForge 模块: 个人成就版本筛选 (AchievementVersionFilter.lua)
-- ============================================================
-- 功能描述：
--   在成就界面「成就」（个人）标签页的筛选下拉菜单（全部/已完成/未完成）
--   下方追加「版本」一级选项，悬停展开二级菜单，可按资料片/小版本
--   （如 10.1、10.2）筛选个人成就列表；选「全部版本」恢复不过滤。
--
-- 实现机制（已对照至暗之夜客户端 Blizzard_AchievementUI 源码核实）：
--   1. 菜单注入：筛选下拉框带 rootDescription:SetTag("MENU_ACHIEVEMENT_FILTER")
--      标签，Menu.ModifyMenu 在菜单末尾追加条目，样式与原生一致。
--   2. 列表过滤：成就列表统一由全局函数
--      AchievementFrameAchievements_UpdateDataProvider() 重建数据
--      （elementData = {category, index, id}）。hooksecurefunc 后置拦截，
--      把 ScrollBox 的 DataProvider 换成仅含目标版本条目的副本。
--      SetDataProvider 不会回触发 UpdateDataProvider，无递归。
--   3. 个人视图判定：AchievementFrame.selectedTab == 1（成就标签页）。
--      公会(2)/统计(3)/对比(nil) 下本模块完全不影响。
--   4. 版本识别（运行时推断，无内置数据库，前瞻兼容）：
--      a) 分类父链：沿 GetCategoryInfo 父链找资料片子分类名
--         （任务→巨龙时代、地下城和团队→巨龙时代 等）得基准 x.0；
--      b) 名称+描述关键词：按资料片作用域识别小版本
--         （如 10.0 作用域内「亚贝鲁斯」→10.1）；
--      c) 成就 ID 年代区间兜底（10.x 起区间细分到小版本，
--         更早版本仅到资料片粒度；边界为经验估值，可调）。
--      解析结果按成就 ID 缓存；扫描在首次打开菜单时执行一次。
--
--   注意：Menu.ModifyMenu / hooksecurefunc 均无法卸载，
--   回调内部先检查 module.enabled，禁用后立即返回并刷新列表还原。
-- ============================================================

local addonName, ns = ...

local L = ns.L

-- ============================================================
-- 模块注册
-- ============================================================
local module = ns.Module:Register({
    key            = "achievementVersionFilter",
    name           = L["AchievementVersionFilter_Name"],
    description    = L["AchievementVersionFilter_Desc"],
    defaultEnabled = true,
})

-- ============================================================
-- 常量表
-- ============================================================
-- 版本清单（key 内部比较用，label 显示在二级菜单）
local VERSIONS = {
    { key = "3.0",  label = "3.0 巫妖王之怒" },
    { key = "4.0",  label = "4.0 大地的裂变" },
    { key = "4.1",  label = "4.1 赞达拉的崛起" },
    { key = "4.2",  label = "4.2 火焰之地" },
    { key = "4.3",  label = "4.3 巨龙之魂" },
    { key = "5.0",  label = "5.0 熊猫人之谜" },
    { key = "5.2",  label = "5.2 雷电王座" },
    { key = "5.4",  label = "5.4 决战奥格瑞玛" },
    { key = "6.0",  label = "6.0 德拉诺之王" },
    { key = "6.2",  label = "6.2 地狱火堡垒" },
    { key = "7.0",  label = "7.0 军团再临" },
    { key = "7.1",  label = "7.1 暗夜要塞" },
    { key = "7.2",  label = "7.2 萨格拉斯之墓" },
    { key = "7.3",  label = "7.3 燃烧王座" },
    { key = "8.0",  label = "8.0 争霸艾泽拉斯" },
    { key = "8.1",  label = "8.1 达萨罗之战" },
    { key = "8.2",  label = "8.2 永恒王宫" },
    { key = "8.3",  label = "8.3 尼奥罗萨" },
    { key = "9.0",  label = "9.0 暗影国度" },
    { key = "9.1",  label = "9.1 统御圣所" },
    { key = "9.2",  label = "9.2 初诞者圣墓" },
    { key = "10.0", label = "10.0 巨龙时代" },
    { key = "10.1", label = "10.1 亚贝鲁斯" },
    { key = "10.2", label = "10.2 阿梅达希尔" },
    { key = "11.0", label = "11.0 地心之战" },
    { key = "11.1", label = "11.1 安德麦" },
    { key = "11.2", label = "11.2 法力熔炉" },
    { key = "12.0", label = "12.0 至暗之夜" },
    { key = "12.1", label = "12.1 乌拉特克" },
}

-- 资料片子分类名 → 基准版本（匹配个人分类树任意层级节点名）
local EXPANSION_NAMES = {
    ["巫妖王之怒"]   = "3.0",
    ["大地的裂变"]   = "4.0",
    ["熊猫人之谜"]   = "5.0",
    ["德拉诺之王"]   = "6.0",
    ["军团再临"]     = "7.0",
    ["争霸艾泽拉斯"] = "8.0",
    ["暗影国度"]     = "9.0",
    ["巨龙时代"]     = "10.0",
    ["地心之战"]     = "11.0",
    ["至暗之夜"]     = "12.0",
}

-- 小版本关键词：{关键词, 版本, 资料片作用域}
-- 仅在成就基准版本等于作用域时生效，避免跨资料片重名误判
-- 匹配成就名称与描述文本
local MINOR_KEYWORDS = {
    -- 大地的裂变
    { "祖尔格拉布",     "4.1",  "4.0" },
    { "祖阿曼",         "4.1",  "4.0" },
    { "火焰之地",       "4.2",  "4.0" },
    { "巨龙之魂",       "4.3",  "4.0" },
    -- 熊猫人之谜
    { "雷电王座",       "5.2",  "5.0" },
    { "雷神岛",         "5.2",  "5.0" },
    { "奥格瑞玛",       "5.4",  "5.0" },
    { "永恒岛",         "5.4",  "5.0" },
    -- 德拉诺之王
    { "地狱火堡垒",     "6.2",  "6.0" },
    { "塔纳安",         "6.2",  "6.0" },
    -- 军团再临
    { "卡拉赞",         "7.1",  "7.0" },
    { "暗夜要塞",       "7.1",  "7.0" },
    { "萨格拉斯之墓",   "7.2",  "7.0" },
    { "破碎海滩",       "7.2",  "7.0" },
    { "阿古斯",         "7.3",  "7.0" },
    { "安托鲁斯",       "7.3",  "7.0" },
    -- 争霸艾泽拉斯
    { "达萨罗",         "8.1",  "8.0" },
    { "纳沙塔尔",       "8.2",  "8.0" },
    { "麦卡贡",         "8.2",  "8.0" },
    { "永恒王宫",       "8.2",  "8.0" },
    { "尼奥罗萨",       "8.3",  "8.0" },
    { "恩佐斯",         "8.3",  "8.0" },
    -- 暗影国度
    { "刻希亚",         "9.1",  "9.0" },
    { "统御圣所",       "9.1",  "9.0" },
    { "塔扎维什",       "9.1",  "9.0" },
    { "扎雷殁提斯",     "9.2",  "9.0" },
    { "初诞者圣墓",     "9.2",  "9.0" },
    -- 巨龙时代
    { "查拉雷克",       "10.1", "10.0" },
    { "亚贝鲁斯",       "10.1", "10.0" },
    { "峈姆",           "10.1", "10.0" },
    { "翡翠梦境",       "10.2", "10.0" },
    { "阿梅达希尔",     "10.2", "10.0" },
    { "梦境守望者",     "10.2", "10.0" },
    -- 地心之战
    { "安德麦",         "11.1", "11.0" },
    { "水闸行动",       "11.1", "11.0" },
    { "卡雷什",         "11.2", "11.0" },
    { "法力熔炉",       "11.2", "11.0" },
    -- 至暗之夜（12.1「乌拉泰克的诅咒」及 12.1.5 内容）
    { "乌拉特克",       "12.1", "12.0" },
    { "乌拉泰克",       "12.1", "12.0" },
    { "盘卷蛇岛",       "12.1", "12.0" },
    { "金多赞",         "12.1", "12.0" },
    { "基希克斯",       "12.1", "12.0" },
}

-- 成就 ID 年代区间兜底（成就系统 3.0 上线，ID 随版本递增）
-- 10.x 起细分到小版本；更早版本仅资料片粒度。边界为经验估值，可调
local ID_ERA = {
    { 0,     4399,  "3.0" },
    { 4400,  6099,  "4.0" },
    { 6100,  8899,  "5.0" },
    { 8900,  10499, "6.0" },
    { 10500, 12499, "7.0" },
    { 12500, 14299, "8.0" },
    { 14300, 15599, "9.0" },
    { 15600, 17699, "10.0" },
    { 17700, 18999, "10.1" },
    { 19000, 39999, "10.2" },
    { 40000, 41399, "11.0" },
    { 41400, 41899, "11.1" },
    { 41900, 59999, "11.2" },
    { 60000, 999999, "12.0" },
}

-- ============================================================
-- 运行时状态
-- ============================================================
local eventFrame
local hooked = false
local selectedVersion = nil   -- 当前选中版本 key（nil = 全部版本）
local expansionCache = {}     -- 分类ID → 资料片基准版本（false = 已判定无）
local versionCache = {}       -- 成就ID → 版本 key（false = 未识别）
local versionCounts = nil     -- 版本 key → 成就数量（分帧扫描填充）
local scanTotal = 0           -- 扫描到的成就总数（诊断用）
local scanUnversioned = 0     -- 未能识别版本的成就数（诊断用）
local unmatchedCategories = nil -- 无资料片归属的分类名 → 成就数（诊断用）
local scanState = nil         -- 分帧扫描迭代状态（nil = 未在扫描）
local scanning = false        -- 是否正在后台扫描
local scanTicker = nil        -- 分帧扫描的 C_Timer 句柄

-- ============================================================
-- IsPersonalView: 是否处于个人成就标签页
-- ============================================================
local function IsPersonalView()
    local frame = _G.AchievementFrame
    return frame and frame.selectedTab == 1
end

-- ============================================================
-- CategoryExpansion: 分类 ID → 资料片基准版本
-- 沿 GetCategoryInfo 父链向上查找，任一节点名命中资料片表即返回
-- （个人树：任务→巨龙时代；地下城和团队→巨龙时代 等）。结果缓存
-- ============================================================
local function CategoryExpansion(categoryID)
    if type(categoryID) ~= "number" then return nil end
    local cached = expansionCache[categoryID]
    if cached ~= nil then
        return cached or nil
    end

    local version
    local cur, depth = categoryID, 0
    while type(cur) == "number" and cur > 0 and depth < 6 do
        local name, parent = GetCategoryInfo(cur)
        if name and EXPANSION_NAMES[name] then
            version = EXPANSION_NAMES[name]
            break
        end
        if type(parent) ~= "number" or parent <= 0 then
            break
        end
        cur = parent
        depth = depth + 1
    end

    expansionCache[categoryID] = version or false
    return version
end

-- ============================================================
-- IDEra: 成就 ID 年代区间兜底
-- ============================================================
local function IDEra(id)
    if type(id) ~= "number" then return nil end
    for _, range in ipairs(ID_ERA) do
        if id >= range[1] and id <= range[2] then
            return range[3]
        end
    end
    return nil
end

-- ============================================================
-- ResolveVersion: 判定成就所属版本
-- 优先级：分类资料片基准 + 作用域关键词（小版本）> ID 年代区间
-- ============================================================
local function ResolveVersion(id, name, description, categoryID)
    local cached = versionCache[id]
    if cached ~= nil then
        return cached or nil
    end

    local version
    local expansion = CategoryExpansion(categoryID)
    if expansion then
        version = expansion
        local text = (type(name) == "string" and name or "")
            .. "\n" .. (type(description) == "string" and description or "")
        for _, kw in ipairs(MINOR_KEYWORDS) do
            if kw[3] == expansion and text:find(kw[1], 1, true) then
                version = kw[2]
                break
            end
        end
    else
        version = IDEra(id)
    end

    versionCache[id] = version or false
    return version
end

-- ============================================================
-- BeginScan: 启动后台分帧扫描（每帧预算 4ms，约 2 秒完成）
-- 数千个成就的遍历若单帧同步执行会造成数秒卡顿，
-- 因此用 C_Timer 逐帧推进；扫描期间 versionCounts 渐进填充，
-- 菜单打开时显示已扫到的版本，扫完后即为完整结果。
-- 登录后由 PLAYER_ENTERING_WORLD 延迟 10 秒启动，避开加载高峰期
local SCAN_BUDGET_MS = 4

local function BeginScan()
    if versionCounts or scanning then return end
    if type(GetCategoryList) ~= "function" then return end

    local categories = GetCategoryList()
    if type(categories) ~= "table" then return end

    versionCounts = {}
    unmatchedCategories = {}
    scanning = true
    scanState = { cats = categories, cat = 1, ach = 0, numAch = 0, categoryID = nil }

    scanTicker = C_Timer.NewTicker(0, function()
        local deadline = debugprofilestop() + SCAN_BUDGET_MS
        local st = scanState
        repeat
            -- 当前分类耗尽则推进到下一个含成就的分类
            while st.ach >= st.numAch do
                if st.cat > #st.cats then
                    scanning = false
                    scanState = nil
                    if scanTicker then
                        scanTicker:Cancel()
                        scanTicker = nil
                    end
                    return
                end
                local entry = st.cats[st.cat]
                st.cat = st.cat + 1
                local categoryID = type(entry) == "table" and entry.id or entry
                st.numAch = 0
                st.ach = 0
                st.categoryID = nil
                if type(categoryID) == "number" then
                    local numAchievements = GetCategoryNumAchievements(categoryID, true)
                    if type(numAchievements) == "number" and numAchievements > 0 then
                        st.categoryID = categoryID
                        st.numAch = numAchievements
                        scanTotal = scanTotal + numAchievements
                        -- 诊断：记录无法归属资料片的分类名（识别命名不匹配）
                        if not CategoryExpansion(categoryID) then
                            local catName = GetCategoryInfo(categoryID)
                            local key = tostring(catName or categoryID)
                            unmatchedCategories[key] = (unmatchedCategories[key] or 0) + numAchievements
                        end
                    end
                end
            end
            -- 处理一个成就
            st.ach = st.ach + 1
            local id, name, _, _, _, _, _, description = GetAchievementInfo(st.categoryID, st.ach)
            if id then
                local version = ResolveVersion(id, name, description, st.categoryID)
                if version then
                    versionCounts[version] = (versionCounts[version] or 0) + 1
                else
                    scanUnversioned = scanUnversioned + 1
                end
            end
        until debugprofilestop() >= deadline
    end)
end

-- ============================================================
-- /jfavf 诊断命令：输出各版本成就统计与无资料片归属的分类
-- 用于排查版本识别问题（分类命名不匹配 / 关键词未命中）
-- ============================================================
SLASH_JFAVF1 = "/jfavf"
SlashCmdList["JFAVF"] = function()
    BeginScan()
    if scanning then
        print("|cff00ff00[JustinForge]|r 成就版本统计（仍在后台扫描，以下为当前进度）：")
    else
        print("|cff00ff00[JustinForge]|r 成就版本统计：")
    end
    for _, info in ipairs(VERSIONS) do
        local count = versionCounts[info.key] or 0
        if count > 0 then
            print(("  %s: %d"):format(info.label, count))
        end
    end
    print(("  未识别版本: %d / 总扫描: %d"):format(scanUnversioned, scanTotal))

    local list = {}
    for catName, count in pairs(unmatchedCategories or {}) do
        list[#list + 1] = { name = catName, count = count }
    end
    table.sort(list, function(a, b) return a.count > b.count end)
    print("  无资料片归属的分类（前15）：")
    for i = 1, math.min(15, #list) do
        print(("    %s: %d"):format(list[i].name, list[i].count))
    end
end

-- ============================================================
-- ApplyVersionFilter: 后置过滤成就列表 DataProvider
-- 原生列表构建完毕后，剔除不匹配当前版本的条目
-- ============================================================
local function ApplyVersionFilter()
    if not module.enabled or not selectedVersion then return end
    if not IsPersonalView() then return end

    local achievements = _G.AchievementFrameAchievements
    local scrollBox = achievements and achievements.ScrollBox
    local dataProvider = scrollBox and scrollBox:GetDataProvider()
    if not dataProvider then return end

    local filtered = CreateDataProvider()
    for _, elementData in dataProvider:Enumerate() do
        local id = elementData.id
        if id then
            local _, name, _, _, _, _, _, description = GetAchievementInfo(id)
            if ResolveVersion(id, name, description, elementData.category) == selectedVersion then
                filtered:Insert(elementData)
            end
        end
    end
    scrollBox:SetDataProvider(filtered)
end

-- ============================================================
-- SetVersion: 切换版本筛选并立即刷新列表
-- ============================================================
local function SetVersion(version)
    selectedVersion = version
    local achievements = _G.AchievementFrameAchievements
    if achievements and achievements:IsShown()
        and type(_G.AchievementFrameAchievements_ForceUpdate) == "function" then
        _G.AchievementFrameAchievements_ForceUpdate()
    end
end

-- ============================================================
-- InjectMenu: 向筛选下拉菜单追加「版本」子菜单
-- ============================================================
local function InjectMenu(_, rootDescription)
    if not module.enabled then return end
    if not IsPersonalView() then return end

    BeginScan()

    local submenu = rootDescription:CreateButton(L["AVF_Version"] or "版本")
    submenu:CreateRadio(
        L["AVF_AllVersions"] or "全部版本",
        function() return selectedVersion == nil end,
        function() SetVersion(nil) end)
    for _, info in ipairs(VERSIONS) do
        if (versionCounts[info.key] or 0) > 0 then
            local key = info.key
            submenu:CreateRadio(
                info.label,
                function() return selectedVersion == key end,
                function() SetVersion(key) end)
        end
    end
end

-- ============================================================
-- InstallHook: Blizzard_AchievementUI 加载后安装 hook 与菜单注入
-- ============================================================
local function InstallHook()
    if hooked then return end
    if type(_G.AchievementFrameAchievements_UpdateDataProvider) ~= "function" then return end
    if not _G.AchievementFrame then return end

    hooksecurefunc("AchievementFrameAchievements_UpdateDataProvider", ApplyVersionFilter)
    Menu.ModifyMenu("MENU_ACHIEVEMENT_FILTER", InjectMenu)
    hooked = true
end

-- ============================================================
-- OnEnable: 模块启用（Blizzard_AchievementUI 懒加载，两种时序都处理）
-- ============================================================
function module:OnEnable()
    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:SetScript("OnEvent", function(_, event, arg1)
            if event == "ADDON_LOADED" and arg1 == "Blizzard_AchievementUI" then
                InstallHook()
            elseif event == "PLAYER_ENTERING_WORLD" then
                -- 登录/进位面后延迟 10 秒启动后台分帧扫描，
                -- 避开加载高峰期，避免与游戏自身的登录负载叠加
                C_Timer.After(10, BeginScan)
            end
        end)
    end
    eventFrame:RegisterEvent("ADDON_LOADED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

    if C_AddOns.IsAddOnLoaded("Blizzard_AchievementUI") then
        InstallHook()
    end
    -- 模块在世界加载后被手动启用时，同样延迟启动扫描
    C_Timer.After(10, BeginScan)
end

-- ============================================================
-- OnDisable: 模块禁用（清空选择并刷新还原；hook 回调查 enabled 失效）
-- ============================================================
function module:OnDisable()
    if eventFrame then
        eventFrame:UnregisterAllEvents()
    end
    -- 取消未完成的后台扫描；若扫描中断则丢弃部分结果，重新启用时从头扫描
    if scanTicker then
        scanTicker:Cancel()
        scanTicker = nil
        versionCounts = nil
        scanTotal = 0
        scanUnversioned = 0
        unmatchedCategories = nil
    end
    scanning = false
    scanState = nil
    SetVersion(nil)
end