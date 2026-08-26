-- ============================================================
-- JustinForge Locale: 简体中文本地化 (zhCN.lua)
-- ============================================================
-- 职责：定义所有用户可见字符串的中文翻译，挂载到 ns.L 表
-- 模块注册时通过 ns.L["key"] 引用名称和描述
-- 新增模块时在此处添加对应的 _Name 和 _Desc 字符串
-- 当前仅支持简体中文（zhCN），如需扩展可新增 enUS.lua / zhTW.lua
-- ============================================================

local addonName, ns = ...

-- 初始化本地化表（若已被前序文件创建则复用，避免覆盖）
ns.L = ns.L or {}

local L = ns.L

-- 插件整体标题和描述（用于设置面板分类名称）
L["AddonTitle"] = "BigAddon"
L["AddonDesc"] = "一系列独立的实用功能，可单独启用或禁用。"

-- ---- 设置面板分组标题 ----
-- 多模块分组的标题（单模块分组直接使用模块名，无需在此定义）
L["Category_General"] = "通用功能"

-- ---- 异常提示字符串 ----
-- 由 Core 中的 pcall 保护逻辑调用（Module.lua / Config.lua / Init.lua）
-- 注意：Core\Init.lua 与 Core\Util.lua 加载早于本文件，但这些字符串仅在
-- 运行时（ADDON_LOADED 之后）被引用，此时本地化表已就绪
L["Error_ModuleEnable"] = "模块「%s」启用时发生异常：%s"
L["Error_ModuleDisable"] = "模块「%s」禁用时发生异常：%s"
L["Error_ConfigInit"] = "设置面板初始化失败：%s"
L["Error_ConfigNoAPI"] = "设置面板初始化失败：游戏设置接口（Settings API）不可用，请检查客户端版本兼容性。"
L["Error_ConfigModule"] = "设置面板注册「%s」的设置项时发生异常：%s"
L["Error_OptionCallback"] = "设置项「%s」回调执行时发生异常：%s"
L["Error_Init"] = "插件初始化过程中发生异常：%s"
L["Error_FinderHook"] = "公会查找器增强刷新时发生异常：%s"

-- ---- 模块字符串 ----
-- 每个模块需要两个字符串：
--   _Name  模块名称（显示在设置面板的 Checkbox 标签）
--   _Desc  模块描述（显示在 Checkbox 下方，说明功能作用）

-- 模块1：自动脱下传送装备
L["TeleportUnequip_Name"] = "自动脱下传送装备"
L["TeleportUnequip_Desc"] = "传送后自动脱下身上的传送装备（公会披风、肯瑞托戒指等），换回传送前的装备。"
L["TeleportUnequip_Tooltip"] = "传送后自动脱下身上的传送装备，换回传送前的装备。\n\n支持的传送装备：\n\n披风槽（公会披风）：\n- 协同披风（暴风城/奥格瑞玛, 2h）\n- 协和披风（暴风城/奥格瑞玛, 4h）\n- 协作披风（暴风城/奥格瑞玛, 8h）\n\n手指槽（戒指）：\n- 肯瑞托戒指（达拉然·晶歌森林, 30min）\n- 肯瑞托强化指环（达拉然·破碎群岛, 30min）\n- 搏击俱乐部戒指（1h）\n- 魔导大师的紫罗兰印戒（卡拉赞, 4h）\n- 指挥官的战斗玺戒 / 船长的指挥玺戒（达萨罗/伯拉勒斯, 30min）"
L["TeleportUnequip_Restored"] = "已自动换回传送前的装备：%s"
L["TeleportUnequip_NoPrevious"] = "检测到仍穿着传送装备 %s，但没有可还原的装备记录。"
L["TeleportUnequip_ItemMissing"] = "检测到仍穿着传送装备 %s，但原装备 %s 不在背包中，无法自动换回。"

-- 模块2：地图窗口居中
L["MapCenter_Name"] = "地图窗口居中"
L["MapCenter_Desc"] = "每次打开地图窗口时，自动将窗口定位到屏幕居中展示。"

-- 模块3：商人窗口扩展
L["MerchantExpand_Name"] = "商人窗口扩展"
L["MerchantExpand_Desc"] = "将商人窗口加宽为固定的 4 列布局（每列 5 行，高度不变），并重新排列修理、出售垃圾、翻页按钮与货币栏。禁用后需重载界面以完全复原锚点。"

-- 模块5：德鲁伊自动取消旅行形态
L["DruidFlightForm_Name"] = "德鲁伊自动取消旅行形态"
L["DruidFlightForm_Desc"] = "在旅行形态下进入可飞行区域时，自动取消变形，重新施放旅行形态即可切换为飞行形态。"

-- 模块6：隐藏学习/遗忘消息
L["ChatHideLearn_Name"] = "隐藏学习/遗忘消息"
L["ChatHideLearn_Desc"] = "在聊天窗口中隐藏系统消息，如「你学会了……」和「你遗忘了……」。"

-- 模块7：宏界面增强
L["MacroEnhance_Name"] = "宏界面增强"
L["MacroEnhance_Desc"] = "加高宏界面（每页 6 列 × 5 行共 30 个宏、编辑框更高，宽度不变）。"

-- 模块8：聊天频道条
L["ChatChannelBar_Name"] = "聊天频道条"
L["ChatChannelBar_Desc"] = "在屏幕上显示一排简约文字频道按钮（说/喊/队/副/团/世/骰/确/倒），左键点击切换到对应聊天频道或执行指令；右键点击「世」可加入/退出大脚世界频道。通过下方坐标滑条调整位置（屏幕中心为原点）。"
L["ChatChannelBar_PosX"] = "快捷栏水平位置 (X)"
L["ChatChannelBar_PosY"] = "快捷栏垂直位置 (Y)"
L["ChatChannelBar_ButtonSize"] = "文字大小"
L["ChatChannelBar_Spacing"] = "按钮间距"
L["ChatChannelBar_NoChannel"] = "未加入大脚世界频道，可右键点击「世」按钮加入: "
L["ChatChannelBar_Joined"] = "已加入频道: 大脚世界频道"
L["ChatChannelBar_Left"] = "已退出频道: 大脚世界频道"
L["ChatChannelBar_CmdFailed"] = "指令执行失败: "
L["ChatChannelBar_OpenFailed"] = "聊天框打开失败: "

-- 模块9：人物属性面板
L["CharacterStats_Name"] = "人物属性面板"
L["CharacterStats_Desc"] = "在屏幕上常态显示人物属性面板（无边框背景，左上角锚定向右下扩展），依次为：主属性、副属性（暴击/急速/精通/全能）、第三属性（吸血/闪避/加速，非0时显示）、坦克属性（躲闪/招架/格挡，仅坦克专精显示）、移速（实时移动速度百分比，每秒刷新）。每行以「名称  数值」展示，名称与数值同色、间隔两个空格（文字固定细描边）。下方可调整位置（屏幕中心为原点）、字号与行间距。"
L["CharacterStats_PosX"] = "面板水平位置 (X)"
L["CharacterStats_PosY"] = "面板垂直位置 (Y)"
L["CharacterStats_FontSize"] = "字号"
L["CharacterStats_LineSpacing"] = "行间距"
L["CharacterStats_ShowTertiary"] = "显示第三属性（吸血/闪避/加速）"
L["CharacterStats_ShowTank"] = "显示坦克属性"
L["CS_Primary"] = "主属性"
L["CS_Strength"] = "力量"
L["CS_Agility"] = "敏捷"
L["CS_Intellect"] = "智力"
L["CS_Crit"] = "暴击"
L["CS_Haste"] = "急速"
L["CS_Mastery"] = "精通"
L["CS_Versa"] = "全能"
L["CS_Leech"] = "吸血"
L["CS_Avoidance"] = "闪避"
L["CS_Speed"] = "加速"
L["CS_Dodge"] = "躲闪"
L["CS_Parry"] = "招架"
L["CS_Block"] = "格挡"
L["CS_Stagger"] = "醉拳"
L["CS_MoveSpeed"] = "移速"

-- 模块11/14：鼠标提示扩展（合并大秘境信息+团本进度+人物提示增强）
L["TooltipEnhance_Name"] = "鼠标提示扩展"
L["TooltipEnhance_Desc"] = "增强鼠标提示框：姓名按职业染色、隐藏头衔、同服隐藏服务器名、显示<离开><忙碌><离线>状态；公会行显示会阶（公会名~会阶名）；等级行隐藏\"等级\"\"玩家\"并在职业前合并专精；阵营改为右上角徽记；显示M+ 分数/M+ 当前钥匙/物品等级(套装数/5)、各地下城限时成绩、当前赛季团本进度、目标的目标。可调整提示框字号。"
L["TE_FontSize"] = "提示框字号"
L["TE_FontSizeTip"] = "鼠标提示框内所有文字的字号（0 = 暴雪默认）。"
L["TE_MPScore"] = "M+ 分数"
L["TE_Keystone"] = "M+ 当前钥匙"
L["TE_ItemLevel"] = "物品等级"
L["TE_TargetTarget"] = "目标的目标"

-- 模块12：隐藏制造业制造者
L["HideCrafter_Name"] = "隐藏制造业制造者"
L["HideCrafter_Desc"] = "在装备鼠标提示中隐藏制造业装备上的绿色「<制造者名字>」署名行。"

-- 模块13：快速设置焦点目标
L["QuickFocus_Name"] = "快速设置焦点目标"
L["QuickFocus_Desc"] = "按住 Shift 并用右键点击场景中的单位、暴雪默认头像/小队/团队框体，或 EllesmereUI 单位框体/小队/团队框体，将其设为焦点。自动适配 EllesmereUI 的框体来源设置。禁用后自动还原框体属性。不支持姓名板。"

-- 模块16：成就界面默认未完成
L["AchievementIncomplete_Name"] = "成就默认筛选未完成"
L["AchievementIncomplete_Desc"] = "每次打开成就界面时，自动将顶部筛选器重置为「未完成」。打开后仍可手动切换其他筛选。"

-- 模块18：拾取窗口向下堆叠
L["LootStackDirection_Name"] = "拾取窗口向下堆叠"
L["LootStackDirection_Desc"] = "团队装备 Roll 窗口与「你获得了 XXX」类拾取提示（物品/货币/金钱/装备升级），在多个同时出现时由向上堆叠改为向下堆叠：第一个保持原本位置不变，后续新出现的依次向屏幕下方增长。不修改窗口尺寸、布局、动画、倒计时等任何其他行为，禁用后立即恢复原生堆叠。"

-- 模块19：公会查找器增强
L["GuildFinderEnhance_Name"] = "公会查找器增强"
L["GuildFinderEnhance_Desc"] = "增强未加入公会时的「查找公会」界面：打开时自动搜索招募中的公会（可关闭）；补充排序功能（相关度/人数最多/最新招募，暴雪默认对公会搜索隐藏）；鼠标悬停公会卡片时额外显示语言、跨阵营、装等要求、仅满级与招募更新时间。注：12.0 起暴雪已移除公会招募的「活动时间」数据，无法展示。"
L["GFE_AutoSearch"] = "打开查找器时自动搜索"
L["GFE_SortFormat"] = "排序：%s"
L["GFE_SortRelevance"] = "相关度"
L["GFE_SortMembers"] = "人数最多"
L["GFE_SortNewest"] = "最新招募"
L["GFE_TipLanguage"] = "语言: %s"
L["GFE_TipCrossFaction"] = "跨阵营公会"
L["GFE_TipMinIlvl"] = "要求装等: %d"
L["GFE_TipMaxLevelOnly"] = "仅招募满级玩家"
L["GFE_TipUpdatedToday"] = "招募信息: 今天更新"
L["GFE_TipUpdatedDays"] = "招募信息: %d 天前更新"

-- 模块15：成就对比界面报错修复
L["AchievementUiFix_Name"] = "成就对比报错修复"
L["AchievementUiFix_Desc"] = "修复暴雪成就界面在对比模式下点击「总结」分类时报错的问题。暴雪的 GetCategoryNumAchievements 只接受数字分类ID，却在对比状态条刷新时把字符串 \"summary\" 传入并崩溃；本模块加一层参数守卫将其忽略（数字ID包括-1哨兵原样透传，行为与默认一致）。"

-- 模块17：BigWigs扩展（设置项显示在主设置页最底部分类中）
L["BWE_Name"] = "BigWigs扩展"
L["BWE_Desc"] = "当 BigWigs / LittleWigs 计时条中的技能进入最后 5 秒倒数时，在屏幕中央显示技能图标、法术名称与整数倒计时。仅读取计时条信息，不影响 BigWigs 的任何功能与显示。"
L["BWE_CountDecimals"] = "倒计时小数点"
L["BWE_CountDecimalsTip"] = "倒计时数字保留的小数位数（0 = 整数，1 = 小数点后 1 位，2 = 小数点后 2 位）。"
L["BWE_PosX"] = "水平位置 (X)"
L["BWE_PosY"] = "垂直位置 (Y)"
L["BWE_PosTip"] = "提醒的显示位置（以屏幕中心为原点，左/下为负，右/上为正）。"
-- 样式
L["BWE_Spacing"] = "技能间距"
L["BWE_SpacingTip"] = "同时存在多个技能提醒时，相邻提醒之间的垂直距离（像素）。"
L["BWE_NameFontSize"] = "法术名称文字大小"
L["BWE_NameFontSizeTip"] = "屏幕中央提醒中法术名称的字号。"
L["BWE_CountFontSize"] = "倒计时数字大小"
L["BWE_CountFontSizeTip"] = "屏幕中央提醒中倒计时数字的字号。"
L["BWE_IconSize"] = "图标大小"
L["BWE_IconSizeTip"] = "屏幕中央提醒中技能图标的尺寸（正方形圆角）。"
L["BWE_IconOffsetX"] = "图标横向偏移"
L["BWE_IconOffsetXTip"] = "图标相对法术名称的水平偏移（像素，正值向右靠近名称，负值向左远离，0 = 紧贴名称左侧）。"
L["BWE_IconOffsetY"] = "图标纵向偏移"
L["BWE_IconOffsetYTip"] = "图标相对法术名称的垂直偏移（像素，正值向上，负值向下，0 = 与名称垂直居中）。"
L["BWE_CountOffsetX"] = "倒计时横向偏移"
L["BWE_CountOffsetXTip"] = "倒计时相对法术名称的水平偏移（像素，正值向右远离名称，负值向左靠近，0 = 紧贴名称右侧）。"
-- 预览
L["BWE_Preview"] = "预览提醒效果"
L["BWE_PreviewBtn"] = "预览"
L["BWE_PreviewTip"] = "在设定位置显示一条模拟的技能提醒（图标 + 法术名称 + 5→1 循环倒计时），实时查看当前设置的效果。"
L["BWE_StopPreview"] = "取消预览"
L["BWE_StopPreviewBtn"] = "取消"
L["BWE_StopPreviewTip"] = "移除正在展示的预览提醒。"
L["BWE_PreviewLabel"] = "预览法术"
L["BWE_NoBigWigs"] = "未检测到 BigWigs 插件，BigWigs扩展未生效。"
