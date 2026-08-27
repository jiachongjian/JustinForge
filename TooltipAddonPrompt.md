# 独立鼠标提示插件开发提示词

> 本文档提炼自 **ElvUI / ElvUI_Libraries / ElvUI_Options / ElvUI_WindTools** 四个插件的鼠标提示（Tooltip）相关源码，可直接作为开发一个「独立鼠标提示增强插件」的需求与实现提示词使用。所有实现要点均标注了参考源码位置，开发时可对照查阅。

## 使用说明

将本文档整体作为系统/需求提示词，并在开头补一句任务指令，例如：
「按照本文档开发一个魔兽世界 12.0 正式服的独立鼠标提示增强插件，纯 Lua 实现，无第三方依赖（或按需内嵌指定库），按第九节分期路线逐期交付。」

---

## 一、项目目标

开发一个不依赖 ElvUI 的独立鼠标提示增强插件，覆盖以下能力域：

1. **单位提示重写**：姓名/公会/等级/专精/职责/服务器/AFK-DND 等行的染色与重排。
2. **目标的目标**：目标单位、团队内仇恨该单位的人员列表。
3. **生命条**：提示框内嵌血条的位置/文本/着色定制。
4. **观察信息**：目标装等、专精、套装件数。
5. **大秘境**：评分（按稀有度染色）、最佳通关、钥石信息、各本成绩。
6. **进度信息**：团本各难度进度、赛季特殊成就。
7. **物品提示**：品质边框染色、物品/法术/货币/玩具等 ID、背包/银行/堆叠计数、卖价行自绘。
8. **标题图标**：物品/法术/成就/坐骑/货币等行首图标、阵营图标、宠物图标。
9. **行为控制**：锚点/光标跟随/背包锚定、按场景可见性、战斗修饰键、淡出、透明度。
10. **外观**：字体字号分组设置、自定义阵营（声望）颜色、皮肤。
11. **扩展**：预创建队伍组成（LFG）、任务怪进度权重、已知物品染色、隐藏制造者署名。

硬性要求：

- 兼容魔兽世界正式服 12.0.7+（TOC `## Interface: 120007`）。
- 全文遵守第 2.3 节 **Secret Value 防护规范**，任何单位 API 返回值不得直接做布尔/比较/算术运算。
- 所有功能可独立开关，设置热切换（除注明需重载的项）。
- 与 ElvUI 共存时检测其 Tooltip 模块并提示用户二选一，避免双重改写。

---

## 二、技术基线与硬性约束

### 2.1 挂钩 Tooltip 的正确方式（12.0 正式服）

**禁止**对 `GameTooltip:HookScript("OnTooltipSetUnit")` 等老脚本挂钩作为主手段，统一使用 `TooltipDataProcessor`：

```lua
-- 四类内容 PostCall（ElvUI 注册于 Tooltip.lua L1261-1264）
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit,  OnUnit)
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item,  OnItem)
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, OnSpell)
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Macro, OnMacro)

-- 行级 PreCall：可拦截/吞掉原生行（return true 阻止默认绘制）
-- ElvUI 用它自绘卖价行（Tooltip.lua L1266-1268）
TooltipDataProcessor.AddLinePreCall(Enum.TooltipDataLineType.SellPrice, OnSellPrice)
```

配套要点：

- PostCall 回调签名为 `func(tooltip, data)`；`data.id`、`data.guid`、`data.lines` 可直接用；需要完整数据时调 `tooltip:GetTooltipData()`。
- 取物品用 `TooltipUtil.GetDisplayedItem(tooltip)`（Retail）；取单位封装一个 `GetDisplayedUnit(tt)`：`select(2, tt:GetUnit())`，取不到时回退 `GetMouseFocus():GetAttribute("unit")`。
- 物品回调需自行过滤框体：只处理 `GameTooltip`/`ShoppingTooltip1`/`ShoppingTooltip2`（以及需要时 `ItemRefTooltip`）。
- 每次内容改写后 `tt:Show()` 触发布局刷新。
- 行清空/重建时务必重置自维护标志：`tt:HookScript("OnTooltipCleared", ...)`（WindTools 借此重置 `tt.windInspectLoaded`；ElvUI 在此清除 `tt.ItemLevelShown`、恢复品质边框色）。

### 2.2 光标/世界提示事件

- `WORLD_CURSOR_TOOLTIP_UPDATE`（Retail）：世界光标提示（鱼漂等）刷新；`state == 0` 时按设置 `tt:FadeOut()` 或 `tt:Hide()`（ElvUI Tooltip.lua L1191-1203）。
- `MODIFIER_STATE_CHANGED`：修饰键按下/松开，用于 ID 显示、观察信息按需刷新（L965）。
- `INSPECT_READY`：观察数据就绪（装等/进度功能的核心事件）。
- `INSPECT_ACHIEVEMENT_READY`：成就对比数据就绪（进度功能）。

### 2.3 Secret Value 防护规范（12.0 必须遵守）

12.0 起大量 API 返回值可能是 **secret**（保密值），对其做布尔判断/比较/算术/作表键/`table.concat` 会直接抛错。规则如下：

1. **判定函数只有一个**：全局 `issecretvalue(v)`（全小写）。大写写法 `IsSecretValue` 不存在，自写包装会误判。
2. **先判 secret 再判真假**：`if issecretvalue(v) then return end` 必须在任何 `if v` / `not v` / `v and ...` 之前。`if v and issecretvalue(v)` 这种写法本身就先触发了布尔判断，是错误的。
3. **secret 布尔**：`UnitIsPlayer/UnitIsUnit/UnitIsAFK/UnitIsDND/UnitIsConnected/UnitExists` 返回值可能是 secret boolean。封装 `SafeBool(v)`：secret → nil，否则返回 v；之后用 `== true` / `== false` 显式比较。
4. **禁区**：比较、算术、表键、`table.concat`、作为 Unit API 参数。**允许**：`string.format`、`..` 拼接、`SetText/SetFormattedText` 显示。
5. **逐点过滤**：所有进入字符串处理/缓存键的值先过滤。ElvUI Tooltip.lua 的过滤点可作清单参考（L202/222/240/245/290-291/301/361/373/481/514/546/543/567/571/650/681/687/929/993/1012）。
6. **特殊技巧**：
   - 单位染色在 secret 场景改用 `C_ClassColor_GetClassColor(unitFileName)`（ElvUI L516）。
   - `tt:GetWidth()` 在挂有 MoneyFrame/对比提示时可能返回 secret，取值前过滤（L929 注释）。
   - hook 会传递 secret 的原生方法（如 FontString `SetText`）前，先「内化」：备份原方法为 `frame.__SetText`，hook 内改写完用备份写回，避免递归与污染（WindTools `F.InternalizeMethod/F.CallMethod`，Core/Functions/Core.lua L556/583）。
   - NaN 防护：`tostring(v) == tostring(0/0)` 判定后给默认值（WindTools `F.IsNaN/F.Or`）。

### 2.4 其他硬约束

- 所有 `OnEnter`/内容回调第一行：`if tt:IsForbidden() then return end`。
- 安全/受限框体（战斗中锁定的单位框）上挂提示时，锚点降级为 `ANCHOR_CURSOR`，不要把 GameTooltip 用固定锚点挂到受限框体（oUF auras.lua 注释：会继承限制导致定位/钳制异常）。
- 观察类功能（装等/进度）战斗中默认禁用。
- 字体污染防护：凡对 GameTooltip 行 FontString 做 `SetFont`，先记录原字体（RememberFont），在 `OnTooltipCleared` + `OnHide` 恢复；折叠行用 `SetText("")` + 字号缩 1，不得留残字（FontString 跨提示复用，不恢复会污染后续 NPC 提示）。

---

## 三、插件架构设计

### 3.1 目录结构建议

```
JustinTooltip/
  JustinTooltip.toc          -- ## Interface: 120007；SavedVariables: JustinTooltipDB
  Core/
    Init.lua                 -- 命名空间、DB 初始化、模块注册表
    Secret.lua               -- issecretvalue 封装、SafeBool、InternalizeMethod
    TooltipUtil.lua          -- GetDisplayedUnit/Item、行查找、ID 提取、扫描 tooltip
    ScanTooltip.lua          -- CreateFrame("GameTooltip","JT_ScanTooltip",...) 隐藏扫描框
    Settings.lua             -- 系统 Settings API 面板（逐控件 pcall 隔离注册）
  Modules/
    UnitInfo.lua  TargetInfo.lua  HealthBar.lua  Inspect.lua
    MythicPlus.lua  Keystone.lua  Progression.lua  TierSet.lua
    ItemInfo.lua  Ids.lua  TitleIcons.lua  SellPrice.lua
    Anchor.lua  Visibility.lua  Appearance.lua
    GroupInfo.lua  ObjectiveProgress.lua  MiscTweaks.lua
  Locales/zhCN.lua
```

### 3.2 子模块回调框架（借鉴 WindTools Core.lua）

不要让每个功能各自 hook Tooltip，统一一套注入框架：

- `JT:AddUnitInfoCallback(priority, func, opts)`：注册单位提示注入器。`opts.modifier` 指定修饰键（NONE/SHIFT/CTRL/ALT/组合如 `CTRL_SHIFT`）；`opts.clear` 注册清理回调，`OnTooltipCleared` 时统一执行。
- 主流程 `JT:OnTooltipSetUnit(tt, data, triedTimes)`：
  1. `IsForbidden`/仅 GameTooltip/可见性检查 → `GetDisplayedUnit` → secret 过滤；
  2. 先跑无修饰键回调（签名 `func(tt, unit, guid)`）；
  3. 修饰键回调依赖装等先行显示的（如套装件数要追加在装等行），等装等标志位就绪后再跑：未就绪用 `C_Timer.After(0.33, 重试)`，最多 4 次（WindTools InspectInfo 机制）；
  4. 修饰键判定集中一处：`IsModKeyDown(db.modifier)`，支持组合键。
- 模块加载回调（xpcall 隔离）+ Profile 更新回调分开注册。
- 事件统一分发：`JT:AddEventCallback(event, func)`。

### 3.3 数据存储

- `SavedVariables: JustinTooltipDB`，结构 `DB.profile.<module>.*`；设置面板默认值表与第五节一致。
- 需要「重载生效」的项（总开关类）单独放 `DB.global` 并在设置变更时弹重载提示。

## 四、功能需求与实现要点

> 格式：功能 → 描述 / 实现要点 / 参考源码（`ET` = ElvUI Tooltip.lua，`WT` = WindTools）。

### 4.1 单位提示·行重写（ET Tooltip.lua L190-505，WT UnitInfo.lua）

| 功能 | 实现要点 | 参考 |
|---|---|---|
| 姓名行职业染色 | 取 `GameTooltipTextLeft1` 原文 → 去色码 → `UnitIsPlayer` 且非 `UnitPlayerControlled` 时用 `select(2,UnitClass)` 查 `RAID_CLASS_COLORS` 重写 | ET L251-273 |
| 玩家头衔 | 开：`UnitPVPName` 取带头衔名；关：纯 `UnitName` | ET L240/L250 |
| 服务器名 | `alwaysShowRealm` 或按住 Shift 时拼 `name-realm`；否则 `UnitRealmRelationship` 拼 `FOREIGN_SERVER_LABEL`（(*)）/ `INTERACTIVE_SERVER_LABEL`（合服）；支持「同服隐藏服务器名」 | ET L245-260 |
| 公会行+会阶 | `GetGuildInfo(unit)` → 行2若有 text 则改行2否则 `AddLine`；会阶开关 `guildRanks`；纯文本 `find` 替换，勿用 `^<.*>$` 模式（12.0 公会行可能无尖括号）；建议格式 `|cff1eff00公会|r~|cff1eff00会阶|r` | ET L277-298 |
| 等级行 | 按 `LEVEL1/LEVEL2` 文本模式定位行；`UnitEffectiveLevel`/`UnitLevel`；`GetCreatureDifficultyColor`（宠物用 `GetRelativeDifficultyColor`）；`UnitClassification` 拼 elite/rare/worldboss/rareelite 标签；支持隐藏「等级」字样、数字黄色 | ET L313-324；WT UnitInfo.lua |
| 专精行 | 找到专精文本行按职业色重写；或剥离「专精 职业」行的专精文本插到种族后、折叠原行 | ET L341-351 |
| 职责 | `UnitGroupRolesAssigned` → `AddDoubleLine(ROLE, ...)` | ET L366-382 |
| 性别 | `UnitSex` 映射本地化名后 `AddLine` | ET L353-364 |
| AFK/DND/离线 | 追加到姓名行：`<离开>`/`<忙碌>`/`<离线>`（布尔先 SafeBool） | ET L384-389 |
| PVP/阵营行清理 | 从第 4 行起扫描，删 `PVP`/`FACTION_ALLIANCE`/`FACTION_HORDE` 行（除非 allowTag*）；折叠行必须 `SetText("")`+字号缩1 | ET RemoveTrashLines；WT Core L87 无参 hook |
| 种族/专精图标 | 行首插 atlas：`PlayerRaceIconFormat`、`SpecIconFormat`（WT `W.Media.Icons`） | WT UnitInfo.lua |
| 玩家标记 | 玩家时在种族/职业文本后加 `(PLAYER)` | ET L332 |

### 4.2 目标的目标 与 Targeted By（ET L421-505）

- **目标的目标**：单位提示内显示 `>>目标名<<`（自己时显示 `>>你<<`）。开关 `targetInfo`（Retail 默认 true）。取 `unit.."target"` 的姓名/职业色（secret 场景用 `C_ClassColor_GetClassColor`）。
- **Targeted By**（团队内正在以该单位为目标的人）：开关默认 false；扫描队伍成员 `%starget` 与目标单位比对（`UnitIsUnit` 需 SafeBool 过滤），逐个染色 `AddLine`。注意 ElvUI 此功能仅限非 Retail，移植到正式服需自行验证 secret 限制。

### 4.3 生命条（ET L578-599/L1253；WT HealthBar.lua）

- 对象：`GameTooltipStatusBar`（ElvUI 皮肤在 Game/Mainline/Skins/Tooltip.lua L12-13 处理纹理/底框）。
- 文本：开关 `healthBar.text`；文本为「当前/最大」（`AbbreviateNumbers` 短格式可选）或 `UnitHealthPercent(unit, true, ScaleTo100)` 百分比；`SetStatusBarColor` 按单位/反应着色。
- 位置 `healthBar.statusPosition`：TOP/BOTTOM/DISABLED；实现于 `GameTooltip_SetDefaultAnchor` hook 中重锚血条（L1226-1229）；禁用时 `SetAlpha(0)` 防 `Reset` 复位残留（L597-599）。
- 数据源 hook：Retail 挂 `GameTooltipStatusBar.UpdateUnitHealth`（L578-581），旧版用 `OnValueChanged`。
- 高度/字体独立设置（WT 另有血条 Y 偏移微调，血量约 700 万时偏移 -3）。

### 4.4 观察装等与套装件数（ET L601-772；WT TierSet.lua）

- 开关 `inspectDataEnable`（默认 true，战斗中禁用）。缓存：`inspectGUIDCache[guid] = {time, itemLevel, specColor, specName}`，**120 秒**有效。
- 触发：`NotifyInspect(unit)` → 等 `INSPECT_READY` 事件 → `GetSpecInfo` → 渲染 → `ClearInspectPlayer` + 检查同单位新目标再次触发（L709-713）。
- 装等计算：自己 `GetAverageItemLevel()`；他人扫 17 个装备槽（跳过战袍槽 4）：`E:GetGearSlotInfo(unit, slot)` 内部用 **E.ScanTooltip**（`CreateFrame("GameTooltip","ElvUI_ScanTooltip",nil,"GameTooltipTemplate")` → `SetOwner(WorldFrame,"ANCHOR_NONE")` → `SetInventoryItem(unit,slot)` → `GetTooltipData` → 匹配 `RETRIEVING_ITEM_INFO` 判断数据未就绪）→ 未就绪置 `tooSoon` 隔 0.05s 重试。**双持武器特例**（L740-760）：主手品质 6（传说）或 `INVTYPE_2HWEAPON/RANGEDWEAPON`（非魔杖）→ `max(main,off)*2`，否则 `main+off`；总装等 `total/16`。
- 显示：`AddDoubleLine("Item Level:", ilvl)` + 专精名职业色；`tt.ItemLevelShown` 标志防重复；随后 `tt:Show()`。
- **套装件数**（WT TierSet）：在装等行右侧追加染色 ` (n/5)`；单位回调里读 C_Item 物品链接比对套装 itemID 表，品质 7 时 `select(16,...)` 兜底；依赖装等先行 → 用 3.2 的重试框架。

### 4.5 大秘境信息（ET L508-534；WT MythicPlus.lua / Keystone.lua）

- API：`C_PlayerInfo.GetPlayerMythicPlusRatingSummary(unit)` → `currentSeasonScore`、`runs`。
- 显示三件套（各自开关）：总分 `dungeonScore`（颜色 `dungeonScoreColor`：`HEIRLOOM`/`CLEAN`/`C_ChallengeMode.GetDungeonScoreRarityColor`）；最佳通关 `mythicBestRun`（`runs` 里 `finishedSuccess` 的最大 `bestRunLevel`，附 `mythicText` 后缀）；钥石（仅自己背包有钥匙时显示）。
- WT 增强版（hook `ET.AddMythicInfo` 整体重写）：
  - 每本地图缩写（`W.MythicPlusMapData[challengeModeID].abbr`）+ 32px 副本图标（`C_ChallengeMode.GetMapUIInfo` 第 4 返回值）；
  - 最佳行显示 `限时/超时 + 层数 + (+1/+2/+3)`：升级数由各计时阈值 `timers` 比对得出；染色表 `W.MythicPlusRunColor`（OverTime/OnTime/OneChest/TwoChest/ThreeChest）；
  - 最高分者用「赛季最佳 + 绿色星星」替换首行；
  - 60 秒 guid 缓存；文本先 `SafeText` 处理。
- 钥石行（WT Keystone）：格式 `名字 (层数)`，来源 `W.Modules.KeystoneInfo:UnitData(unit)` 的 `challengeMapID/level`，副本名 `C_ChallengeMode.GetMapUIInfo` 转 UTF8 大写；自己可直接用暴雪 API，他人钥石需插件通信获取（可选实现）。

### 4.6 团本进度与赛季成就（WT Progression.lua，可选高级功能）

- 缓存 `progCache[guid] = {info, displayName, updateTime}`，120 秒；事件 `INSPECT_ACHIEVEMENT_READY`。
- 流程：`UnitPopupButtons.INSPECT` 就位 → `LoadAddOn("Blizzard_AchievementUI")` → 关掉其对比显示 → `SetAchievementComparisonUnit(unit)` → 事件回调里清 `AchievementFrameComparison` → `GetStatistic/GetComparisonStatistic` 拉数 → 渲染 → `ClearAchievementComparisonUnit`。
- 内容数据结构 `WT.ProgressionData`（按副本/类别）：
  - 团本：每本 `{en=, abbreviation=, achievements={lfg/normal/heroic/mythic={成就ID...}}}` → 按难度显示 `kills/总数 难度名`；
  - 特殊成就（大秘境赛季）：`achievements` 逐个 `GetAchievementComparisonInfo`，完成则显示「成就名 (YYYY-MM-DD)」；
  - 大秘境各本：`mapIDs` 或 `achievementID`，可选 `markHighestScore` 最高分标星、`showNoRecord` 无记录显示灰色「无记录」。
- 设置：`disableInCombat`（默认 true）、`header`（NONE/TEXT/TEXTURE，`GROWING_UPWARD` 贴顶纹理）。

### 4.7 物品提示（ET L889-930/L1199-1240；WT Item 模块）

| 功能 | 实现要点 |
|---|---|
| 品质边框染色 `itemQuality` | `C_Item.GetItemQualityByID(link)` → `GetColorDataForItemQuality` → `tt.NineSlice:SetBackdropBorderColor(r,g,b)`；`OnTooltipCleared` 恢复原色（L1201-1207） |
| 物品计数 `itemCount` | `C_Item.GetItemCount(link)`；银行= `(link, true, nil, includeReagents, includeWarband)` 减背包数；堆叠=`C_Item.GetItemInfo` 第 8 返回值；均 `> 0` 才显示；`modifierCount` 修饰键门控（L1015-1034） |
| 卖价行自绘 | `TooltipDataProcessor.AddLinePreCall(SellPrice)`：抑制原生行后 `C_CurrencyInfo.GetCoinTextureString(price, 13)` 自绘；`moneyLines=true`+非 Shift 时连对比提示的卖价行也隐藏；`moneyHide` 控制对比提示 `SetCompareItem` 的显示；`moneyAlpha/moneyColor` |
| 最大卖价范围 `maxPrice` | 当前档位=铜值，`MINIMUM`=档位下限，`MAXIMUM`=档位上限（L1056-1062） |
| 已知物品染色 | WT Item/AlreadyKnown：收藏品 API 判定已学宠物/坐骑/玩具/图纸 → 提示行着色；失败时 `C_TooltipInfo.GetHyperlink` 扫 `COLLECTED/ITEM_SPELL_KNOWN` 文本兜底 |
| 额外物品提示 | WT `extraItemTooltips`：`azeriteEssence`（艾泽里特精华提示，需 ACE3+C_LibStub）、`flightstones`（飞珑石来源/每周上限）、`respecMastery`（可重置精通提示） |

### 4.8 ID 显示体系（ET L939-1135）

- 总开关 `spellID` + 修饰键 `modifierID`（SHOW/HIDE/SHIFT/CTRL/ALT，默认 SHOW）；格式 `|cFFCA3C3C%s:|r %s`（左键右值）。
- 覆盖对象（逐一 `AddLine`）：法术（Spell/Macro PostCall，L1091-1101）、物品（含 `EmbeddedItemTooltip` 内嵌提示）、玩具（L1020-1030）、货币（L1037-1048）、宠物（L1103-1112）、任务（L1119-1135）、`ItemRefTooltip`。
- 光环 ID：走 CVar `tooltipShowAuraSpellIDs`（系统自带光环 ID 显示）；`MODIFIER_STATE_CHANGED` 里按 `modifierAuraIDs` 临时改 CVar 再复原（L965）。
- ID 提取：物品 `C_Item.GetItemInfo`；法术 `select(2, TooltipUtil.GetDisplayedSpell/tt:GetSpell())`。

### 4.9 标题图标（WT Icons.lua）

- 行首图标：对 7 个提示框（GameTooltip/ItemRef/Shopping1/2/Embedded/QuickKeybind/RareTooltip）hook 行渲染，按内容类型取图标 `SetIconString` 后 `row:SetText(icon.." "..text)`：
  - 成就 `select(10, GetAchievementInfo)`、物品/装备方案 `C_Item.GetItemIconByID`、法术 `C_Spell.GetSpellTexture`、玩具 `C_ToyBox.GetToyInfo` 第 3 参、坐骑 `C_MountJournal.GetMountInfoByID` 第 3 参、货币 `C_CurrencyInfo.GetCurrencyInfo`、宏 `GetMacroInfo`。
- 阵营图标：玩家（非 secret 判定后）在提示右上角放 35×35 `factionIcon`（`Interface\TargetingFrame\UI-PVP-Alliance/Horde`）；非玩家须在 UnitIsPlayer 返回前 `Hide` 防残留。
- 宠物图标/ID：`C_PetJournal.GetPetInfoBySpeciesID`，质量枚举转着色品质。

### 4.10 杂项 Tweaks（WT MiscTweaks.lua 等，按需选用）

- **任务怪进度权重** `objectiveProgress`（WT ObjectiveProgress.lua）：单位 PostCall → guid 提 npcID → `LibObjectiveProgress:GetNPCWeightByCurrentQuests` → 命中任务标题行追加 `+ x%`；权重=该 NPC 对当前大秘境/任务进度的贡献百分比（依赖库，可用公共 LibObjectiveProgress-1.0 或砍掉）。
- **隐藏制造者署名**（WT HideCrafter）：物品 PostCall → `TooltipUtil.GetDisplayedItem` → 从第 10 行倒查绿色 `<...>` 制造者行 → 该行及其后 2 行 `SetText("")`。
- **隐藏雷什裹布按钮** `reshiiWrapsUpgrade`（WT）：进战锁定 + `ReshiiWrapsUpgradeFrame` OnShow 时强制隐藏。
- **ElvUI 用户列表**（ET L188/L1142-1158）：`CHAT_MSG_ADDON` 前缀 `ELVUI_VERSIONCHK` 收集 `E.UserList`，提示中标记「ElvUI 用户」——独立插件可改为标记本插件用户（用于钥石/进度互通）。
- `showMount` 为 Mists 专属（`TooltipDataType.Mount`），正式服不做。

### 4.11 预创建队伍组成（WT GroupInfo.lua，可选）

- hook `LFGListUtil_SetSearchEntryTooltip`，在系统提示基础上按 `LFG_LIST_GROUP_DATA_*` 顺序输出「角色职责 → 职业/专精图标」分布。
- 数据源：`C_LFGList.GetSearchResultInfo(id)` → `W.Utilities.LFGPlayerInfo:GetPartyMemberInfo(index, activityID)`（封装 `GetSearchResultPlayerInfo` 过滤 secret/空值，转 `PlayerInfo` 表）；副本/职责上下文 `C_LFGList.GetActivityInfoTable(activityID).displayType`。
- 模板 `template` 设置（默认 `{{classIcon:18}}{{specIcon:18}} {classColorStart}{className}{classColorEnd} {score}`），`title` 开关、`hideBlizzard` 隐藏原生部分；兼容 PremadeGroupsFilter（L103-108）。

### 4.12 锚定与可见性（ET L1137-1258）

- **锚点**：自建可拖动锚点框体（如 `JT_TooltipAnchor`，ElvUI 用 `CreateMover`+`ANCHOR_TOP`）；`SecureHook("GameTooltip_SetDefaultAnchor")`（L1212-1258）内按设置接管：
  - `cursorAnchor`：`SetOwner(parent, "ANCHOR_CURSOR"|"_LEFT"|"_RIGHT", x, y)`，类型下拉三选；
  - 固定锚：相对 `JT_TooltipAnchor` 定位，`xOffset/yOffset`（±200，步长1）；
  - `anchorToBags`：背包打开时改锚到 `ContainerFrameCombinedBags` 或 `ContainerFrame1`（L1233-1252）。
- **场景可见性**（`visibility` 段）：单位框 `unitFrames`、动作条 `actionbars`（检查 `owner` 是否在 `LAB/`LABStance`/PetAction`/NAB/ExtraAB 名单，仅非战斗应用）、背包 `bags`、战斗中 `combatOverride`（取值均 SHOW/HIDE/SHIFT/CTRL/ALT）；战斗中需按修饰键才显示，SHOW 例外。
- **淡出 `fadeOut`**：`WORLD_CURSOR_TOOLTIP_UPDATE` 状态 0 → `tt:FadeOut()`；否则直接 Hide。
- **背景透明度 `colorAlpha`**：自定义背景时应用 alpha；取宽高等几何值注意 secret（见 2.3.6）。

### 4.13 外观（ET L822-863；ElvUI_Options Tooltip.lua）

- `SetTooltipFonts`：分组设置——正文 `GameTooltipText`（`textFontSize` 默认12）、小号 `GameTooltipTextSmall`（`smallTextFontSize` 默认12）、标题 `GameTooltipHeaderText`（`headerFontSize` 默认14）、金币行（`GameTooltipMoneyFrame1*Prefix/SuffixText`+`Gold/Silver/CopperButtonText`）、对比提示 `ShoppingTooltip*`、血条文字独立字号；outline 下拉（NONE/OUTLINE/THICKOUTLINE/MONOCHROME*）。
- **中文字体注意**：Standalone 插件默认字体必须支持 zhCN（ElvUI 的 PT Sans Narrow 无中文），默认值用系统字体路径（如 `Fonts\ARKai_T.ttf`）或 `LSM` 注册的中文字体；内嵌 LSM-3.0 可选。
- 自定义阵营色 `factionColors[1..8]`：按 `FACTION_STANDING_LABEL*`（仇恨~崇拜）可改色，应用于阵营相关文本着色处。
- 皮肤：背景/边框贴图经 LSM（ElvUI 键 `"Blizzard Tooltip"`）；Standalone 用自带 NineSlice 设置即可。

## 五、设置项设计（建议 DB 树 + 默认值）

合并 ElvUI `P.tooltip`（Defaults/Profile.lua L1508-1578）与 WindTools `P.tooltips`/`V.tooltips`（Settings/Profile.lua L1188+、Private.lua L838+）提炼。`profile` 热切换，`global` 需重载。

```lua
DB = {
  global = { enable = true },                          -- [需重载] 总开关
  profile = {
    -- 通用行为
    anchor           = "BOTTOMRIGHT",                  -- 固定锚点 9 方位
    xOffset = 0, yOffset = 0,                          -- ±200
    cursorAnchor     = false,
    cursorAnchorType = "ANCHOR_CURSOR",                -- 另 _LEFT/_RIGHT
    anchorToBags     = false,
    fadeOut          = true,                           -- 世界光标提示淡出
    colorAlpha       = 1,                              -- 0-1 背景透明度
    visibility = {                                       -- 值域 SHOW/HIDE/SHIFT/CTRL/ALT
      unitFrames = "NONE", actionbars = "NONE",
      bags = "NONE", combatOverride = "SHOW" },
    -- 外观
    font = "Fonts\\ARKai_T.ttf", fontOutline = "NONE",
    headerFontSize = 14, textFontSize = 12, smallTextFontSize = 12,
    itemCountFontSize = 12, inspectFontSize = 12,
    factionColors = { [1]={r=.8,g=.3,b=.22}, ... [8]={r=0,g=.6,b=.1} },  -- 仇恨~崇拜 8 档
    -- 单位提示
    playerTitles = true, guildRanks = true, alwaysShowRealm = false,
    role = true, gender = false, faction = false, factionIcon = false,
    raceIcon = true, specIcon = true, levelLine = true, coloredLevel = true,
    targetInfo = true, targetedBy = false,
    allowTagGuild = true, allowTagPVP = false, allowTagLevel = false,  -- PVP/阵营/等级行保留白名单
    -- 生命条
    healthBar = { text = true, height = 7, statusPosition = "BOTTOM",  -- TOP/BOTTOM/DISABLED
                  fontSize = 12, fontOutline = "NONE", shortValue = true },
    -- 观察
    inspectDataEnable = true, itemLevel = true, tierSet = true,
    -- 大秘境 / 进度
    dungeonScore = true, dungeonScoreColor = "HEIRLOOM",               -- CLEAN/RARITY
    mythicBestRun = true, keystone = true,
    progression = { enable = false, disableInCombat = true,
                    header = "NONE",                                   -- NONE/TEXT/TEXTURE
                    markHighestScore = true, showNoRecord = false,
                    raids = {}, specials = {}, dungeon = {} },          -- 逐本开关
    -- 物品
    itemCount = "BAGS",                                -- NONE/BAGS/BANK/STACK
    includeReagents = false, includeWarband = false, modifierCount = true,
    itemQuality = false,                               -- 品质边框染色
    spellID = true, modifierID = "SHOW",               -- ID 显示修饰键
    npcIds = false, petID = true,
    alwaysShowCompareItems = false,
    moneyLines = true, moneyHide = "NONE", moneyAlpha = 1, moneyColor = true,
    moneyCoins = true, moneyForceCoins = false, maxPrice = "GOLD",      -- COPPER/SILVER/GOLD/PLATINUM
    -- 图标
    icons = { achievement = true, item = true, spell = true, toy = true,
              mount = true, currency = true, equipmentSet = true,
              macro = true, pet = true },
    -- 扩展
    groupInfo = { enable = true, title = true, hideBlizzard = true,
                  template = "{{classIcon:18}}{{specIcon:18}} {className}" },
    objectiveProgress = true,
    hideCrafter = true, alreadyKnown = false,
    showUsers = false,                                 -- 显示本插件用户
  }
}
```

设置面板用系统 Settings API（`Settings.RegisterCanvasLayoutCategory` + 逐控件 `pcall` 隔离注册；下拉在 12.0.7 实测不可展开，多选一律用滑条/多个勾选框代替——项目既有经验）。

## 六、工程实践清单（源自 ElvUI_Libraries）

1. **事件驱动刷新**：提示显示中相关状态变化（专精切换/目标切换）→ 若 `tt:IsOwned(来源)` 则重设内容或 Hide（LibActionButton `UpdateFlyout` 模式）。
2. **节流**：每帧 `OnUpdate` 型刷新用 `TOOLTIP_UPDATE_TIME`（默认 0.2s）节流。
3. **三态显示配置**：`show/hide/DOWN`（按下修饰键才显示）模式值得为 ID/计数类复用。
4. **自建扫描/展示提示框**：`CreateFrame("GameTooltip", "JT_xxxTooltip", UIParent, "GameTooltipTemplate")` + `SharedTooltip_SetBackdropStyle` 风格统一；用完 `Hide()`（AceGUI 模式）。扫描用框 `SetOwner(WorldFrame, "ANCHOR_NONE")`。
5. **光环提示兼容**：优先 `tt:SetUnitBuffByAuraInstanceID/SetUnitDebuffByAuraInstanceID`，缺方法时回退按索引 `SetUnitAura`（oUF auras.lua L210-229 模板）。
6. **LSM 可选内嵌**：背景/边框/字体材质经 LibSharedMedia-3.0 注册，键名独立命名空间（如 `"JT Tooltip"`）。

## 七、兼容性

- **ElvUI 共存**：`C_AddOns.IsAddOnLoaded("ElvUI")` 且其 tooltip 模块启用时，聊天框提示「检测到 ElvUI 提示模块，建议关闭其一」；可读取 `ElvUI[1].private.tooltip.enable` 判断（ElvUI 默认开启，改动需重载）。
- **WindTools 共存**：其 Tooltips 子模块全部需重载（V.tooltips），同样检测提示。
- **LibObjectiveProgress**：任务怪进度功能依赖公共库 `LibObjectiveProgress-1.0`，可选内嵌或功能裁剪。
- **RaiderIO**：本插件不依赖 RaiderIO，全部进度/分数走暴雪官方 API；如需「他人各本最佳」无官方 API 的场景，文档化为限制说明。

## 八、参考源码索引

| 主题 | 文件 |
|---|---|
| 核心提示模块（全部行重写/装等/ID/锚定/字体） | `ElvUI/Game/Shared/Modules/Tooltip/Tooltip.lua`（1310 行） |
| 提示皮肤（血条纹理/底框） | `ElvUI/Game/Mainline/Skins/Tooltip.lua` |
| 默认设置 | `ElvUI/Game/Shared/Defaults/Profile.lua:1508-1578`、`Defaults/Private.lua:193` |
| 设置面板（全部控件/范围/依赖） | `ElvUI_Options/Game/Shared/Tooltip.lua` |
| 观察装等扫描 | `ElvUI/Game/Shared/General/ItemLevel.lua`（`E:GetGearSlotInfo`） |
| 子模块注入框架/修饰键/重试 | `ElvUI_WindTools/Modules/Tooltips/Core.lua` |
| 大秘境详情 | `ElvUI_WindTools/Modules/Tooltips/MythicPlus.lua`（数据 `W.MythicPlusMapData`） |
| 团本/成就进度 | `ElvUI_WindTools/Modules/Tooltips/Progression.lua` |
| 标题图标/阵营图标/宠物 | `ElvUI_WindTools/Modules/Tooltips/Icons.lua` |
| 任务怪进度权重 | `ElvUI_WindTools/Modules/Tooltips/ObjectiveProgress.lua` |
| LFG 队伍组成 | `ElvUI_WindTools/Modules/Tooltips/GroupInfo.lua`（`W.Utilities.LFGPlayerInfo`） |
| 套装件数/钥石/种族专精图标/血条偏移 | `Tooltips/TierSet.lua`、`Keystone.lua`、`UnitInfo.lua`、`HealthBar.lua` |
| secret 防护工具 | `ElvUI_WindTools/Core/Functions/Core.lua`（`F.InternalizeMethod` 等）、`ElvUI/Core/General/API.lua`（`E.IsSecretValue` 族） |
| 提示刷新/受限锚点实践 | `ElvUI_Libraries/Game/Shared/LibActionButton-1.0/LibActionButton-1.0.lua`、`oUF/elements/auras.lua` |
| 已知物品染色/雷什裹布 | `ElvUI_WindTools/Modules/Item/AlreadyKnown.lua`、`Modules/Misc/MiscTweaks.lua` |

## 九、分期实施路线

1. **P0 骨架**：TOC/DB/模块注册表/设置面板骨架；`Secret.lua`（issecretvalue/SafeBool/InternalizeMethod）；锚点框 + `GameTooltip_SetDefaultAnchor` 接管 + 光标跟随 + 偏移；字体三组设置。
2. **P1 单位提示**：姓名/公会/等级/专精/职责/AFK 行重写；PVP/阵营行清理；目标的目标；生命条（位置/文本/高度）。
3. **P2 物品与 ID**：品质边框、itemCount、卖价自绘、spellID/物品ID/玩具/货币/宠物/任务 ID、光环 ID CVar、标题图标、hideCrafter。
4. **P3 观察系**：装等扫描（含 2H 特例、ScanTooltip、120s 缓存）、套装件数、M+ 分数/最佳/钥石。
5. **P4 高级**：Progression（团本/赛季成就/各本成绩）、GroupInfo（LFG 组成）、ObjectiveProgress（进度权重）。
6. **P5 打磨**：可见性规则全场景、淡出、透明度、已知物品染色、用户标记、ElvUI/WindTools 共存检测、全功能 secret 场景回归测试（重点：大秘境中悬停单位/物品）。

## 附：既有 TooltipEnhance 模块衔接

本工作区 JustinForge 插件已有自研 `TooltipEnhance` 模块（游戏内实测可用），已解决以下坑，开发独立插件时可直接迁移其代码：
- 字体污染防护（RememberFont/恢复）、SafeBool 布尔过滤、公会行纯文本 find 替换、大秘境各本成绩无标题行排版、团本进度行格式、阵营徽记镂空纹理与残留防护、单一 fontSize 滑条（0=暴雪默认）。
- 独立插件相当于在此模块基础上，按第四/五节补齐 ElvUI/WindTools 的其余能力并引入 3.2 的回调框架。
