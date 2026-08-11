----------------------------------------------------------------------
-- CaiseTip / Modules / MythicScore
-- 大秘境分数
----------------------------------------------------------------------

local P = select(2, ...)
local L = P.L

local ipairs = ipairs
local strformat = string.format
local tostring = tostring

local GetDungeonScoreRarityColor = C_ChallengeMode.GetDungeonScoreRarityColor
local GetKeystoneLevelRarityColor = C_ChallengeMode.GetKeystoneLevelRarityColor
local GetMapUIInfo = C_ChallengeMode.GetMapUIInfo
local GetPlayerMythicPlusRatingSummary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary
local GetSpecificDungeonOverallScoreRarityColor = C_ChallengeMode.GetSpecificDungeonOverallScoreRarityColor
local IsChallengeModeActive = C_ChallengeMode.IsChallengeModeActive
local UnitIsPlayer = UnitIsPlayer

local DUNGEON_SCORE_LEADER = DUNGEON_SCORE_LEADER

local Colors = P.Colors


-- 颜色函数(根据层数和是否超时返回颜色)
local function GetColorForLevel(level, overTime)
    if level == 0 then
        return Colors.White  -- 0层，白色
    elseif overTime then
        return Colors.LightGray   -- 超时层数，灰色
    elseif level >= 15 then
        return Colors.Golden   -- 15层及以上，金色
    elseif level >= 12 then
        return Colors.Pink     -- 12-14层，粉色
    elseif level >= 10 then
        return Colors.ItemLegendary   -- 10-11层，橙色
    elseif level >= 9 then
        return Colors.ItemEpic    -- 9层，紫色
    elseif level >= 7 then
        return Colors.ItemSuperior   -- 7-8层，蓝色
    else
        return Colors.ItemGood    -- 1-6层，绿色
    end
end

local function GetColoredScore(score, colorFunc)
    local color = colorFunc(score)
    return color:WrapTextInColorCode(tostring(score))
end

local function GetKeystoneLevelText(level)
    local color = GetKeystoneLevelRarityColor(level)
    return strformat("<%s>", color:WrapTextInColorCode(tostring(level)))
end

local function AddDungeonScoreLine(tooltip, run)
    if not run.challengeModeID or not run.mapScore or run.mapScore == 0 then return end

    local dungeonName = GetMapUIInfo(run.challengeModeID)
    if not dungeonName then return end

    local level = run.bestRunLevel
    local overTime = not run.finishedSuccess

    local color = GetColorForLevel(level, overTime)
    local scoreText = color:WrapTextInColorCode(tostring(run.mapScore))
    local scoreTextlevel = color:WrapTextInColorCode("<"..level..">")
    if level > 0 then
        scoreText = strformat("%s %s", scoreText, scoreTextlevel)
    end

    tooltip:AddDoubleLine(dungeonName, scoreText)
end

local function IsModifierDown(mod)
    if mod == "CTRL" then return IsControlKeyDown() end
    if mod == "ALT" then return IsAltKeyDown() end
    if mod == "SHIFT" then return IsShiftKeyDown() end
    return false
end

local function ShouldShowDungeonDetail()
    local mode = P.db.mythicDungeonMode
    if mode == "ALWAYS" then
        return true
    elseif mode == "MODIFIER" then
        return IsModifierDown(P.db.mythicDungeonModifier)
    end
    return false
end

function P.ShowMythicScore(self, unit)
    if not P.db.showMythicScore then return end
    if not UnitIsPlayer(unit) then return end

    -- 在大秘境中跳过史诗分数获取，避免可能的报错
    if IsChallengeModeActive() then
        return
    end

    local summary = GetPlayerMythicPlusRatingSummary(unit)
    if not summary or not summary.currentSeasonScore or summary.currentSeasonScore == 0 then return end

    local score = summary.currentSeasonScore
    local scoreText = GetColoredScore(score, GetDungeonScoreRarityColor)

    local maxLevel = 0
    local maxLevelOverTime = false
    if summary.runs then
        for _, run in ipairs(summary.runs) do
            if run.finishedSuccess and run.bestRunLevel and run.bestRunLevel > maxLevel then
                maxLevel = run.bestRunLevel
                maxLevelOverTime = not run.finishedSuccess
            end
        end
    end

    local text = strformat(DUNGEON_SCORE_LEADER, scoreText)
    --[[if maxLevel > 0 then
        text = strformat("%s%s", text, GetKeystoneLevelText(maxLevel))
    end]]
    if maxLevel > 0 then
        -- 使用自定义颜色显示最高层数
        local levelColor = GetColorForLevel(maxLevel, maxLevelOverTime)
        text = strformat("%s <%s>", text, levelColor:WrapTextInColorCode(tostring(maxLevel)))
    end

    self:AddLine(text)

    if summary.runs and ShouldShowDungeonDetail() then
        for _, run in ipairs(summary.runs) do
            AddDungeonScoreLine(self, run)
        end
    end
end

