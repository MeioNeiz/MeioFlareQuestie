-- MeioFlareQuestie: FlareUI's quest tracker (the look) fed with Questie's database (the data).
--
-- FlareUI's tracker reads only Blizzard's quest API, which on Forever knows little about
-- where things are. Questie knows every spawn, item and turn-in NPC. Patch 52 gives
-- FlareUI's tracker optional hook points (OT.Local*) that this addon fills; patch 53
-- exposes its spacing for compact mode. Without the patches only the resize grip, the
-- distances and the tooltip lines work.

MeioFlareQuestieDB = MeioFlareQuestieDB or {}

local DB_VERSION = 2
local db
local OT -- FlareUI.ObjectiveTracker, set at PLAYER_LOGIN
local category -- Settings panel

local PREFIX = "|cffb090ffMeioFlareQuestie:|r "
local GOLD, ON, OFF, HINT = "|cffffd100", "|cff80ff80", "|cffff8080", "|cff999999"

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

local function OnOff(v) return v and (ON .. "on|r") or (OFF .. "off|r") end
local function Cmd(text) return GOLD .. text .. "|r" end

-- DistanceUtils' "nothing found", and what it adds for a spot on another continent
local NO_DATA = 999999999
local OTHER_PLACE = 500000

--------------------------------------------------
-- Questie access (lazy and guarded: Questie loads its database after login)
--------------------------------------------------
local modules = {}
local function Module(name)
    local m = modules[name]
    if m then return m end
    if not (QuestieLoader and QuestieLoader.ImportModule) then return nil end
    local ok, mod = pcall(QuestieLoader.ImportModule, QuestieLoader, name)
    if ok and type(mod) == "table" then modules[name] = mod return mod end
end

-- Questie's own quest object for a quest in the log (objectives with spawn lists), or nil
local function QuestOf(questID)
    local AQ = Module("ActiveQuests")
    local acceptance = AQ and AQ.Get and AQ.Get(questID)
    return acceptance and acceptance.quest or nil
end

-- FlareUI's distance sort, the distances on the lines and the tooltip all ask within a
-- second: one spawn search per quest per second
local NEAREST_TTL = 1
local nearestCache = {}

-- spawn, areaId, name, distance (yards) of where to go next: the nearest unfinished
-- objective, or the turn-in once the quest is complete
local function Nearest(questID)
    local now = GetTime()
    local hit = nearestCache[questID]
    if hit and now - hit.t < NEAREST_TTL then return hit[1], hit[2], hit[3], hit[4] end
    local spawn, zone, name, dist
    local quest = QuestOf(questID)
    local DU = Module("DistanceUtils")
    if quest and DU and DU.GetNearestSpawnForQuest then
        local ok, s, z, n, d = pcall(DU.GetNearestSpawnForQuest, quest)
        if ok and s and d and d < NO_DATA then spawn, zone, name, dist = s, z, n, d end
    end
    nearestCache[questID] = { spawn, zone, name, dist, t = now }
    return spawn, zone, name, dist
end

local function ZoneName(areaID)
    local TU = Module("TrackerUtils")
    if not (areaID and TU and TU.GetZoneNameByID) then return nil end
    local ok, name = pcall(TU.GetZoneNameByID, TU, areaID)
    return ok and name or nil
end

local function PlayerAreaID()
    local ZDB = Module("ZoneDB")
    local mapID = C_Map.GetBestMapForUnit("player")
    if not (ZDB and mapID) then return nil end
    local ok, areaID = pcall(ZDB.GetAreaIdByUiMapId, ZDB, mapID)
    return ok and areaID or nil
end

-- HereBeDragons' angles run anticlockwise from north, as GetPlayerFacing's do
local COMPASS = { "N", "NW", "W", "SW", "S", "SE", "E", "NE" }
local function Compass(spawn, areaID)
    local HBD, ZDB = Module("HBD"), Module("ZoneDB")
    if not (HBD and ZDB and spawn and spawn[1] and spawn[1] >= 0) then return nil end
    local ok, angle = pcall(function()
        local px, py, pi = HBD:GetPlayerWorldPosition()
        local mapID = ZDB:GetUiMapIdByAreaId(areaID)
        local x, y, i = HBD:GetWorldCoordinatesFromZone(spawn[1] / 100, spawn[2] / 100, mapID)
        if not (px and x) or pi ~= i then return nil end
        return (HBD:GetWorldVector(i, px, py, x, y))
    end)
    if not (ok and angle) then return nil end
    return COMPASS[math.floor((angle + math.pi / 8) / (math.pi / 4)) % 8 + 1]
end

local function Yards(dist)
    if dist >= OTHER_PLACE then return nil end
    if dist < 1000 then return ("%d yd"):format(dist) end
    return ("%.1fk yd"):format(dist / 1000)
end

--------------------------------------------------
-- Hook providers (called by FlareUI through patch 52)
--------------------------------------------------
local function LocalDistance(questID)
    local _, _, _, dist = Nearest(questID)
    if not dist then return nil end
    -- FlareUI compares squared yards (C_QuestLog.GetDistanceSqToQuest)
    return dist * dist
end

-- link, texture, charges, showWhenComplete: as GetQuestLogSpecialItemInfo answers
local function LocalQuestItem(questID)
    local quest = QuestOf(questID)
    local TU = Module("TrackerUtils")
    if not (quest and TU and TU.GetQuestItemIds) then return nil end
    local complete = C_QuestLog.IsComplete(questID) and 1 or 0
    local ok, items = pcall(TU.GetQuestItemIds, quest, complete)
    local itemID = ok and type(items) == "table" and items[1]
    if not itemID then return nil end
    local texture = C_Item.GetItemIconByID(itemID)
    if not texture then return nil end
    return "item:" .. itemID, texture, C_Item.GetItemCount(itemID), false
end

local function LocalCompleteText(questID)
    if not C_QuestLog.IsComplete(questID) then return nil end
    local _, zone, name = Nearest(questID)
    if not name then return nil end
    local zoneName = zone and zone ~= PlayerAreaID() and ZoneName(zone)
    if zoneName then return ("Return to %s (%s)"):format(name, zoneName) end
    return ("Return to %s"):format(name)
end

local function LocalShowOnMap(questID)
    local TU = Module("TrackerUtils")
    if not (TU and TU.ShowQuestOnMap) then return false end
    local ok, shown = pcall(TU.ShowQuestOnMap, questID)
    return ok and shown and true or false
end

--------------------------------------------------
-- The tracker's pooled lines, and its header
--------------------------------------------------
-- FlareUI's pooled tracker line
---@class FQLine: Button
---@field text FontString
---@field kind string?
---@field questID number?
---@field fqDistance FontString?

---@type table<FQLine, true>
local hookedLines = {}

local function HookLines()
    local holder = _G.FlareUI_ObjectiveTracker
    if not holder then return end
    for _, child in ipairs({ holder:GetChildren() }) do
        local content = child:IsObjectType("ScrollFrame") and child:GetScrollChild()
        if content then
            for _, line in ipairs({ content:GetChildren() }) do
                if line:IsObjectType("Button") and line.text then hookedLines[line] = true end
            end
        end
    end
end

local function Header()
    local holder = _G.FlareUI_ObjectiveTracker
    if not holder then return nil end
    for _, child in ipairs({ holder:GetChildren() }) do
        if child.title and child.zone and child.minimize then return child end
    end
end

--------------------------------------------------
-- Distance at the right of each quest's name; the nearest quest's in white
--------------------------------------------------
local function DistanceLabel(line)
    local label = line.fqDistance
    if label then return label end
    label = line:CreateFontString(nil, "OVERLAY")
    label:SetPoint("RIGHT", line, "RIGHT", 0, 0)
    label:SetJustifyH("RIGHT")
    line.fqDistance = label
    return label
end

local function UpdateDistances()
    local holder = _G.FlareUI_ObjectiveTracker
    local on = db and db.distance and holder and holder:IsVisible()
    local nearest, nearestDist
    for line in pairs(hookedLines) do
        local dist = on and line:IsShown() and line.kind == "title" and line.questID
            and select(4, Nearest(line.questID))
        local text = dist and Yards(dist)
        local label = line.fqDistance
        if text then
            label = DistanceLabel(line)
            local face, size, flags = line.text:GetFont()
            if face then label:SetFont(face, math.max(8, size - 1), flags) end
            label:SetShadowOffset(line.text:GetShadowOffset())
            label:SetShadowColor(line.text:GetShadowColor())
            label:SetText(text)
            -- only beside a name that leaves room on its one line (a wrapped name measures
            -- its full length, so it never fits)
            local room = line:GetWidth() - line.text:GetStringWidth() - label:GetStringWidth()
            if room >= 6 then
                label:Show()
                if not nearestDist or dist < nearestDist then
                    nearest, nearestDist = label, dist
                end
            else
                label:Hide()
            end
        elseif label then
            label:Hide()
        end
    end
    for line in pairs(hookedLines) do
        local label = line.fqDistance
        if label and label:IsShown() then
            local c = label == nearest and 1 or 0.6
            label:SetTextColor(c, c, c)
        end
    end
end

--------------------------------------------------
-- Header count: orange with two free quest log slots or fewer, red when full
--------------------------------------------------
local FREE_WARN = 2

local function MarkLogFull()
    local head = Header()
    local text = head and head.title:GetText()
    if not text then return end
    -- after the colour code, whose hex can end in digits
    local count, max = text:match("|c%x%x%x%x%x%x%x%x(%d+)/(%d+)|r$")
    count, max = tonumber(count), tonumber(max)
    if not (count and max) then return end
    local free = max - count
    local colour = free <= 0 and "|cffff4040" or free <= FREE_WARN and "|cffff9933" or nil
    if colour then
        head.title:SetText((text:gsub("|c%x%x%x%x%x%x%x%x(%d+/%d+)|r$", colour .. "%1|r")))
    end
end

--------------------------------------------------
-- Tooltips: the nearest objective / turn-in under FlareUI's own quest tooltip; level,
-- tags and clicks on Shift
--------------------------------------------------
local DIFFICULTY = {
    [0] = "grey, little XP",
    [1] = "green, easy",
    [2] = "yellow, even",
    [3] = "orange, hard",
    [4] = "red, too hard for now",
}

local function AddLevelLines(questID)
    local logIndex = C_QuestLog.GetLogIndexForQuestID(questID)
    local info = logIndex and C_QuestLog.GetInfo(logIndex)
    if not info then return end
    local level = info.difficultyLevel or info.level
    local diff = C_PlayerInfo.GetContentDifficultyQuestForPlayer
        and C_PlayerInfo.GetContentDifficultyQuestForPlayer(questID)
    if level and level > 0 then
        local words = diff and DIFFICULTY[diff]
        local c = diff and GetDifficultyColor and GetDifficultyColor(diff)
        GameTooltip:AddLine(("Level %d%s"):format(level, words and (": " .. words) or ""),
            c and c.r or 1, c and c.g or 1, c and c.b or 1)
    end
    local kinds = {}
    local tag = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(questID)
    if tag and tag.isElite then kinds[#kinds + 1] = "Elite" end
    local tagName = tag and tag.tagName
    if tagName and tagName ~= "" and not (tag.isElite and tagName == "Elite") then
        kinds[#kinds + 1] = tagName
    end
    if (info.suggestedGroup or 0) > 1 then
        kinds[#kinds + 1] = ("group of %d suggested"):format(info.suggestedGroup)
    end
    if #kinds > 0 then GameTooltip:AddLine(table.concat(kinds, ", "), 1, 1, 1) end
end

local function AddQuestieLines()
    local line = GameTooltip:GetOwner() --[[@as FQLine?]]
    if GameTooltip.fqAdded or not (line and hookedLines[line] and line.questID) then return end
    GameTooltip.fqAdded = true
    local questID = line.questID
    local spawn, zone, name, dist = Nearest(questID)
    local shift = IsShiftKeyDown()
    GameTooltip:AddLine(" ")
    if name then
        local label = C_QuestLog.IsComplete(questID) and "Turn in" or "Nearest"
        local where = ZoneName(zone)
        local yards = Yards(dist)
        local right = yards and (yards .. " " .. (Compass(spawn, zone) or "")) or (where or "")
        local n = NORMAL_FONT_COLOR
        GameTooltip:AddDoubleLine(label .. ": |cffffffff" .. name .. "|r", right,
            n.r, n.g, n.b, 1, 1, 1)
        if yards and where and zone ~= PlayerAreaID() then
            GameTooltip:AddLine(where, 0.6, 0.6, 0.6)
        end
    end
    if shift then
        AddLevelLines(questID)
        local clicks = OT.LocalHooks and "Alt-click: map. Ctrl-click: focus. Right-click: menu."
            or "Ctrl-click: focus. Right-click: menu."
        GameTooltip:AddLine(clicks, 0.6, 0.6, 0.6, true)
    elseif not GameTooltip.meioShiftHint then
        GameTooltip.meioShiftHint = true
        GameTooltip:AddLine(HINT .. "Shift: more|r")
    end
    GameTooltip:Show()
end

-- Shift pressed or let go over a quest: FlareUI builds its tooltip only on entering a
-- quest, so leave and enter it again
local function RefreshTooltip()
    local line = GameTooltip:IsShown() and GameTooltip:GetOwner()
    if not (line and hookedLines[line] and line.questID and line:IsMouseOver()) then return end
    local leave, enter = line:GetScript("OnLeave"), line:GetScript("OnEnter")
    if not (leave and enter) then return end
    leave(line)
    -- after FlareUI's own next-frame unhover, which clears the quest it showed
    C_Timer.After(0, function()
        if line:IsMouseOver() and line.questID then enter(line) end
    end)
end

--------------------------------------------------
-- Item buttons from the database: cooldowns, and a redraw when such an item reaches the
-- bags (FlareUI only redraws on bag changes for tracked recipes)
--------------------------------------------------
local function UpdateLocalCooldowns()
    for i = 1, 40 do
        local b = _G["FlareUI_TrackerItem" .. i]
        if not b then break end
        if b:IsShown() and b.localItemID and b.cooldown then
            local start, duration, enable = C_Container.GetItemCooldown(b.localItemID)
            if start then CooldownFrame_Set(b.cooldown, start, duration, enable) end
        end
    end
end

local itemSignature
local function ItemSignature()
    local parts = {}
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID
                and C_QuestLog.GetQuestWatchType(info.questID) ~= nil
                and not GetQuestLogSpecialItemInfo(i) then
            local link = LocalQuestItem(info.questID)
            if link then parts[#parts + 1] = info.questID .. "=" .. link end
        end
    end
    return table.concat(parts, ",")
end

--------------------------------------------------
-- Size: compact spacing (patch 53) and a drag grip
--------------------------------------------------
-- FlareUI's own value after each. FlareUI reads these when it builds its frames at
-- PLAYER_LOGIN, so they are set at ADDON_LOADED.
local COMPACT = {
    HEADER = 20, -- 30: the header band
    HEADER_INSET = 6, -- 8
    PAD = 8, -- 14: text in from the frame's sides
    INDENT = 8, -- 10: objectives under their quest
    LIST_TOP = 3, -- 10
    LIST_BOTTOM = 6, -- 10
    LINE_GAP = 1, -- 2
    QUEST_GAP = 4, -- 9 (Edit Mode's Quest Spacing still overrides it once moved)
    GROUP_GAP = 6, -- 10: before a zone heading
    ZONE_GAP = 2, -- 5: under a zone heading
}
local MIN_WIDTH, MAX_WIDTH = 140, 600
local MIN_LIST, MAX_LIST = 40, 1200

local function ApplyCompact()
    local C = FlareUI and FlareUI.ObjectiveTracker and FlareUI.ObjectiveTracker.Constants
    if not C or not db.compact then return end
    for k, v in pairs(COMPACT) do C[k] = v end
end

local function TrackerDb()
    local profile = FlareUI and FlareUI.db and FlareUI.db.profile
    return profile and profile.objectivetracker
end

-- written into FlareUI's own settings (Settings > Quest Tracker > Fonts shows them and can
-- change them after). FlareUI's defaults: 13 / 12 / 11.
local FONT_KEYS = { "headerFont", "titleFont", "objectiveFont" }
local FONT_SIZES = { small = { 11, 10, 9 }, default = { 13, 12, 11 } }

local function SetFontSizes(which)
    local tracker, sizes = TrackerDb(), FONT_SIZES[which]
    if not (tracker and sizes) then return false end
    for i, key in ipairs(FONT_KEYS) do
        if type(tracker[key]) == "table" then tracker[key].size = sizes[i] end
    end
    if OT and OT.initialized then
        if OT.ApplyLook then OT:ApplyLook() end
        OT:Render()
    end
    return true
end

-- "small", "default" or "custom" (set some other way in FlareUI's settings)
local function FontSizes()
    local tracker = TrackerDb()
    if not tracker then return "default" end
    for name, sizes in pairs(FONT_SIZES) do
        local same = true
        for i, key in ipairs(FONT_KEYS) do
            local font = tracker[key]
            if type(font) ~= "table" or font.size ~= sizes[i] then same = false end
        end
        if same then return name end
    end
    return "custom"
end

local function ResetSize()
    local tracker = TrackerDb()
    if not tracker then return false end
    tracker.width, tracker.maxHeight = nil, nil
    if OT and OT.initialized then OT:Render() end
    return true
end

local function Layout()
    local C = OT and OT.Constants or {}
    return C.HEADER or 30, (C.LIST_TOP or 10) + (C.LIST_BOTTOM or 10)
end

local grip, drag, gripHover

-- the corner opposite the one the tracker is held by: it grows toward the grip
local GRIP_COORDS = {
    BOTTOMRIGHT = { 0, 1, 0, 1 },
    BOTTOMLEFT = { 1, 0, 0, 1 },
    TOPRIGHT = { 0, 1, 1, 0 },
    TOPLEFT = { 1, 0, 1, 0 },
}
local function PlaceGrip()
    local holder = _G.FlareUI_ObjectiveTracker
    if not (grip and holder and OT.Side) then return end
    local right, top = OT:Side()
    local corner = (top and "BOTTOM" or "TOP") .. (right and "LEFT" or "RIGHT")
    grip:ClearAllPoints()
    grip:SetPoint(corner, holder, corner, right and 2 or -2, top and 2 or -2)
    local c = GRIP_COORDS[corner]
    for _, t in ipairs({ grip:GetNormalTexture(), grip:GetHighlightTexture(),
            grip:GetPushedTexture() }) do
        t:SetTexCoord(c[1], c[2], c[3], c[4])
    end
    local header = Layout()
    -- minimized (only the header): nothing to size
    grip:SetShown(holder:IsShown() and holder:GetHeight() > header + 6)
end

local function StopDrag()
    if not drag then return end
    drag = nil
    grip:SetScript("OnUpdate", nil)
    if OT.RequestRender then OT:RequestRender() end
end

local function OnDrag(self, elapsed)
    drag.wait = (drag.wait or 0) - elapsed
    if drag.wait > 0 then return end
    drag.wait = 0.03
    if InCombatLockdown() then StopDrag() return end
    local tracker = TrackerDb()
    if not tracker then StopDrag() return end
    local x, y = GetCursorPosition()
    x, y = x / drag.scale, y / drag.scale
    local dx, dy = x - drag.x, y - drag.y
    local width = drag.w + (drag.right and -dx or dx)
    local list = drag.h + (drag.top and -dy or dy)
    width = math.floor(math.max(MIN_WIDTH, math.min(MAX_WIDTH, width)) + 0.5)
    list = math.floor(math.max(MIN_LIST, math.min(MAX_LIST, list)) + 0.5)
    if width ~= tracker.width or list ~= tracker.maxHeight then
        tracker.width, tracker.maxHeight = width, list
        OT:Render()
    end
end

local function CreateGrip()
    local holder = _G.FlareUI_ObjectiveTracker
    if grip or not holder then return end
    grip = CreateFrame("Button", nil, holder)
    grip:SetSize(14, 14)
    grip:SetFrameLevel(holder:GetFrameLevel() + 20)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetAlpha(0)
    grip:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or InCombatLockdown() then return end
        local header, margins = Layout()
        local scale = holder:GetEffectiveScale()
        local x, y = GetCursorPosition()
        local right, top = OT:Side()
        drag = { x = x / scale, y = y / scale, scale = scale, right = right, top = top,
            w = holder:GetWidth(),
            h = math.max(MIN_LIST, holder:GetHeight() - header - margins) }
        self:SetScript("OnUpdate", OnDrag)
    end)
    grip:SetScript("OnMouseUp", StopDrag)
    grip:SetScript("OnHide", StopDrag)
    grip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:AddLine("Drag to resize the tracker")
        GameTooltip:AddLine("Height is the most it grows to; it scrolls past that.",
            0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", GameTooltip_Hide)
    -- the tracker's quest lines take the mouse, so its own OnEnter/OnLeave can't tell
    C_Timer.NewTicker(0.15, function()
        local over = drag or (holder:IsVisible() and holder:IsMouseOver(4, -4, -4, 4))
        if over ~= gripHover then
            gripHover = over
            grip:SetAlpha(over and 0.9 or 0)
        end
    end)
    PlaceGrip()
end

--------------------------------------------------
-- Setup
--------------------------------------------------
local function Redraw()
    if OT and OT.initialized and OT.RequestRender then OT:RequestRender() end
end

--------------------------------------------------
-- Search: a box in the header lists only the quests that match (patch 55), tracked or
-- not (untracked ones dimmed) and from any zone. Not saved: /reload clears it.
--------------------------------------------------
local searchText -- as typed, or nil
local searchWords -- lowercased words, all must match
local searchButton, searchBox

local function Haystack(info, zone)
    local parts = { info.title or "", zone or "" }
    for _, obj in ipairs(C_QuestLog.GetQuestObjectives(info.questID) or {}) do
        parts[#parts + 1] = obj.text or ""
    end
    -- who to hand it in to, from Questie
    parts[#parts + 1] = LocalCompleteText(info.questID) or ""
    return table.concat(parts, "\n"):lower()
end

local function LocalFilter(info, zone)
    if not searchWords then return nil end
    if not (type(info.questID) == "number" and info.questID > 0) then return false end
    local hay = Haystack(info, zone)
    for _, word in ipairs(searchWords) do
        if not hay:find(word, 1, true) then return false end
    end
    return true
end

local function LocalEmptyText()
    if searchText then return ('No quest in your log matches "%s".'):format(searchText) end
end

local function MatchCount()
    local n, zone = 0, nil
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and info.isHeader then
            zone = info.title
        elseif info and not info.isHidden and LocalFilter(info, zone) then
            n = n + 1
        end
    end
    return n
end

local function PaintSearchButton()
    if not searchButton then return end
    searchButton.active = searchText and true or nil
    searchButton:Paint(searchButton.lit)
end

local function UpdateSearchCount()
    local count = searchBox and searchBox.fqCount
    if not count then return end
    count:SetText(searchText and tostring(MatchCount()) or "")
    searchBox:SetTextInsets(16, count:GetStringWidth() + 22, 0, 0)
end

local function SetSearch(text)
    text = text and text:match("^%s*(.-)%s*$") or ""
    local words = {}
    for word in text:lower():gmatch("%S+") do words[#words + 1] = word end
    if #words == 0 then
        searchText, searchWords = nil, nil
    else
        searchText, searchWords = text, words
    end
    PaintSearchButton()
    Redraw()
end

local function CloseSearch()
    if not searchBox then SetSearch(nil) return end
    searchBox:SetText("") -- OnTextChanged clears the search
    searchBox:ClearFocus()
    searchBox:Hide()
end

local function OpenSearch(focus)
    if not searchBox then return end
    -- minimized there is no list to narrow
    local holder = _G.FlareUI_ObjectiveTracker
    if holder and holder:GetHeight() <= Layout() + 6 then OT:SetMinimized(false) end
    searchBox:Show()
    if focus then searchBox:SetFocus() end
end

local function MagnifierGlyph(n)
    -- a ring with its handle down to the right, in FlareUI's 6 x 8 glyph grid
    return OT.Build.GridGlyph(n, {
        { 1, 1, 3, 1 }, { 1, 5, 3, 1 }, { 0, 2, 1, 3 }, { 4, 2, 1, 3 },
        { 4, 5, 1, 1 }, { 5, 6, 1, 1 },
    })
end

local function CreateSearch(head)
    local C = OT.Constants or {}
    searchButton = OT.CreateBoxButton(head, nil, C.BOX or 12)
    searchButton.glyph = MagnifierGlyph
    searchButton:Layout()
    searchButton:SetScript("OnClick", function()
        if searchBox:IsShown() then CloseSearch() else OpenSearch(true) end
        GameTooltip:Hide()
    end)
    searchButton:SetScript("OnEnter", function(self)
        self:Paint(true)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Search quests")
        if searchText then
            GameTooltip:AddLine(('Showing quests matching "%s"'):format(searchText), 1, 1, 1)
            GameTooltip:AddLine("Click to clear", 0.5, 0.5, 0.5)
        else
            GameTooltip:AddLine("Quest name, zone, objective or who to return to. Every quest"
                .. " in your log that matches shows, tracked or not.", 0.5, 0.5, 0.5, true)
        end
        GameTooltip:Show()
    end)
    searchButton:SetScript("OnLeave", function(self)
        self:Paint(false)
        GameTooltip:Hide()
    end)

    searchBox = CreateFrame("EditBox", nil, head, "SearchBoxTemplate")
    searchBox:SetAutoFocus(false)
    searchBox:SetFrameLevel(head:GetFrameLevel() + 5)
    searchBox:Hide()
    local count = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    count:SetPoint("RIGHT", searchBox, "RIGHT", -20, 0)
    searchBox.fqCount = count
    searchBox:HookScript("OnTextChanged", function(self)
        SetSearch(self:GetText())
    end)
    searchBox:HookScript("OnEscapePressed", CloseSearch)
    searchBox:HookScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if not searchText then CloseSearch() end
    end)
    searchBox:HookScript("OnEditFocusLost", function()
        if not searchText then searchBox:Hide() end
    end)
    searchBox:HookScript("OnShow", function() head.title:SetAlpha(0) end)
    searchBox:HookScript("OnHide", function() head.title:SetAlpha(1) end)
end

-- after FlareUI places its header buttons: the search button left of the leftmost, the
-- box over the title
local function LayoutSearch(head)
    if head ~= Header() or not OT.CreateBoxButton then return end
    if not searchButton then CreateSearch(head) end
    local left = head.lastButton or head.minimize
    for _, b in ipairs({ head.autoTurnIn, head.autoAccept }) do
        if b and b:IsShown() then left = b end
    end
    searchButton:ClearAllPoints()
    searchButton:SetPoint("RIGHT", left, "LEFT", -4, 0)
    local C = OT.Constants or {}
    searchBox:ClearAllPoints()
    searchBox:SetPoint("LEFT", head, "LEFT", (C.PAD or 14) - (C.HEADER_INSET or 8) + 4, 0)
    searchBox:SetPoint("RIGHT", searchButton, "LEFT", -6, 0)
    searchBox:SetHeight(math.min(18, head:GetHeight()))
    PaintSearchButton()
end

local function InitDB()
    db = MeioFlareQuestieDB
    if (db.dbVersion or 0) < 1 then
        -- before settings had defaults, compact was on unless turned off: keep that for
        -- anyone who already used it; new installs start with FlareUI's own spacing
        if db.fontsSet or db.followSet then db.compact = db.compact ~= false end
        db.compact = db.compact or false
        db.fontsSet, db.followSet = nil, nil
    end
    if db.distance == nil then db.distance = true end
    db.dbVersion = DB_VERSION
end

-- patches 52 and 53, as FlareUI's tracker has them now (a FlareUI update removes them)
local function MissingPatches()
    local missing = {}
    if not (OT and OT.LocalHooks) then missing[#missing + 1] = "52 (Questie data)" end
    if not (OT and OT.Constants) then missing[#missing + 1] = "53 (compact spacing)" end
    if not (OT and OT.CreateBoxButton) then missing[#missing + 1] = "55 (search)" end
    return missing
end

local function PatchAdvice(missing)
    return ("FlareUI isn't patched (%s), so most features are off. Run mods.ps1 from the"
        .. " MeioFlareQuestie download (see its README), then restart WoW."):format(
        table.concat(missing, ", "))
end

-- once per FlareUI version: an update is what removes the patches
local function WarnMissingPatches()
    local missing = MissingPatches()
    if #missing == 0 then return end
    local version = C_AddOns.GetAddOnMetadata("FlareUI", "Version") or "?"
    if db.warnedFor == version then return end
    db.warnedFor = version
    Print(PatchAdvice(missing))
end

local function AfterRender()
    HookLines()
    MarkLogFull()
    UpdateDistances()
    UpdateSearchCount()
    if grip then PlaceGrip() else CreateGrip() end
end

local function Setup()
    OT = FlareUI and FlareUI.ObjectiveTracker
    if not OT then return false end
    OT.LocalDistance = LocalDistance
    OT.LocalQuestItem = LocalQuestItem
    OT.LocalCompleteText = LocalCompleteText
    OT.LocalShowOnMap = LocalShowOnMap
    OT.LocalFilter = LocalFilter
    OT.LocalEmptyText = LocalEmptyText
    if OT.Build and OT.Build.LayoutHeader then
        hooksecurefunc(OT.Build, "LayoutHeader", LayoutSearch)
        if OT.initialized then Redraw() end
    end
    hooksecurefunc(OT, "Render", AfterRender)
    hooksecurefunc(OT, "UpdateItemCooldowns", UpdateLocalCooldowns)
    hooksecurefunc(GameTooltip, "Show", AddQuestieLines)
    GameTooltip:HookScript("OnTooltipCleared", function(tt)
        tt.fqAdded, tt.meioShiftHint = nil, nil
    end)
    C_Timer.NewTicker(1, UpdateDistances)
    WarnMissingPatches()
    return true
end

--------------------------------------------------
-- Settings panel (Esc > Options > AddOns > MeioFlareQuestie)
--------------------------------------------------
local function SetDistance(on)
    db.distance = on
    UpdateDistances()
end

local function SetCompact(on)
    db.compact = on
end

local function RegisterSettings()
    if category or not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
    local layout
    category, layout = Settings.RegisterVerticalLayoutCategory("MeioFlareQuestie")
    local function Section(name, tip)
        if layout and CreateSettingsListSectionHeaderInitializer then
            layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(name, tip))
        end
    end
    local note = not QuestieLoader and " (Questie not loaded)"
        or #MissingPatches() > 0 and " (FlareUI patches missing: /flarequestie status)" or ""
    Section("Quest tracker" .. note, "FlareUI's quest tracker, with where to go from"
        .. " Questie's database. Hover a quest for the nearest objective; Shift for more.")

    local distance = Settings.RegisterAddOnSetting(category, "MEIOFLAREQUESTIE_DISTANCE",
        "distance", db, Settings.VarType.Boolean, "Quest distances", true)
    distance:SetValueChangedCallback(function(_, value) SetDistance(value) end)
    Settings.CreateCheckbox(category, distance, "Yards to the quest's nearest objective, or"
        .. " to its turn-in once done, at the right of its name. The nearest quest's is"
        .. " white. Needs Questie.")

    local compact = Settings.RegisterAddOnSetting(category, "MEIOFLAREQUESTIE_COMPACT",
        "compact", db, Settings.VarType.Boolean, "Compact spacing", false)
    compact:SetValueChangedCallback(function(_, value) SetCompact(value) end)
    Settings.CreateCheckbox(category, compact, "Tighter gaps around the tracker's lines and"
        .. " quests, so more fit. Takes effect after /reload.")

    local fonts = Settings.RegisterProxySetting(category, "MEIOFLAREQUESTIE_FONTS",
        Settings.VarType.String, "Text size", "default", FontSizes, function(value)
            if FONT_SIZES[value] then SetFontSizes(value) end
        end)
    Settings.CreateDropdown(category, fonts, function()
        local options = Settings.CreateControlTextContainer()
        options:Add("small", "Small", "Header 11, quest names 10, objectives 9.")
        options:Add("default", "FlareUI default", "Header 13, quest names 12, objectives 11.")
        if FontSizes() == "custom" then
            options:Add("custom", "Custom",
                "Set in FlareUI's settings (Quest Tracker > Fonts).")
        end
        return options:GetData()
    end, "The tracker's text sizes. Writes FlareUI's own font settings, which can fine-tune"
        .. " them (FlareUI Settings > Quest Tracker > Fonts).")

    if CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer("Tracker size", "Reset size",
            function() ResetSize() end, "Back to FlareUI's default width and height. Drag the"
            .. " tracker's bottom corner grip to resize it.", true))
    end
    Settings.RegisterAddOnCategory(category)
end

local function OpenSettings()
    if not category then return false end
    Settings.OpenToCategory(category:GetID())
    return true
end

function MeioFlareQuestie_OnAddonCompartmentClick()
    OpenSettings()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "MeioFlareQuestie" then return end
        InitDB()
        ApplyCompact()
    elseif event == "PLAYER_LOGIN" then
        local ready = Setup()
        local ok, err = pcall(RegisterSettings)
        if not ok then geterrorhandler()(err) end
        if not ready then return end
        self:RegisterEvent("BAG_UPDATE_DELAYED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("MODIFIER_STATE_CHANGED")
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Questie builds its quest data a few seconds after loading in: draw again then
        for _, delay in ipairs({ 3, 8, 20 }) do
            C_Timer.After(delay, function()
                itemSignature = ItemSignature()
                Redraw()
            end)
        end
    elseif event == "MODIFIER_STATE_CHANGED" then
        if arg1 == "LSHIFT" or arg1 == "RSHIFT" then RefreshTooltip() end
    elseif event == "BAG_UPDATE_DELAYED" then
        -- FlareUI moves item buttons after the fight anyway
        if InCombatLockdown() then return end
        local now = ItemSignature()
        if now ~= itemSignature then
            itemSignature = now
            Redraw()
        end
    end
end)

--------------------------------------------------
-- Slash command
--------------------------------------------------
local function Status()
    local tracker = TrackerDb()
    if tracker and tracker.enabled == false then
        Print("FlareUI's quest tracker is off: FlareUI Settings > Quest Tracker turns it on.")
    end
    local missing = MissingPatches()
    if #missing > 0 then Print(PatchAdvice(missing)) end
    if not QuestieLoader then
        Print("Questie isn't loaded, so no distances, quest items or turn-in NPCs."
            .. " The resize grip and settings still work.")
        return
    end
    local logged, located, items = 0, 0, 0
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID and info.questID > 0 then
            logged = logged + 1
            if Nearest(info.questID) then located = located + 1 end
            if LocalQuestItem(info.questID) then items = items + 1 end
        end
    end
    local max = C_QuestLog.GetMaxNumQuestsCanAccept and C_QuestLog.GetMaxNumQuestsCanAccept()
    Print(("%d%s quests in the log: Questie locates %d, has a usable item for %d."):format(
        logged, max and ("/" .. max) or "", located, items))
    if tracker and not (tracker.sortByDistance and not tracker.zoneFirst) then
        Print(HINT .. "Tip: FlareUI Settings > Quest Tracker > Sort: Distance orders quests by"
            .. " the nearest objective.|r")
    end
    local questie = Questie and Questie.db and Questie.db.profile
    if questie and not questie.trackerFollowSuperTracking then
        Print(HINT .. "Tip: Questie's option Tracker > Follow Blizzard Super Tracking makes its"
            .. " map follow the quest you focus (Ctrl-click) in FlareUI's tracker.|r")
    end
end

local function Help()
    local function Line(cmd, what)
        DEFAULT_CHAT_FRAME:AddMessage("  " .. Cmd(cmd) .. " - " .. what)
    end
    Print("Questie's data in FlareUI's quest tracker")
    Line("/flarequestie", "open the settings")
    Line("/flarequestie status", "what Questie finds for your quests, and tips")
    Line("/flarequestie distance on||off", "yards to each quest (now "
        .. OnOff(db.distance) .. ")")
    Line("/flarequestie compact on||off", "tighter tracker spacing, after /reload (now "
        .. OnOff(db.compact) .. ")")
    Line("/flarequestie fonts small||default", "tracker text 11/10/9 or FlareUI's 13/12/11")
    Line("/flarequestie size reset", "FlareUI's default tracker width and height")
    Line("/flarequestie search [text]", "list only the quests that match (no text: clear);"
        .. " also the magnifier in the tracker's header")
    DEFAULT_CHAT_FRAME:AddMessage("  Settings: Esc > Options > AddOns > MeioFlareQuestie ("
        .. Cmd("/flarequestie settings") .. ")")
end

local function NeedTracker()
    if OT then return true end
    Print("FlareUI's quest tracker not found.")
    return false
end

SLASH_MEIOFLAREQUESTIE1 = "/flarequestie"
SlashCmdList.MEIOFLAREQUESTIE = function(msg)
    local search = (msg or ""):match("^%s*[Ss][Ee][Aa][Rr][Cc][Hh]%f[%A](.*)$")
    if search then
        if not (NeedTracker() and searchBox) then
            Print("searching needs FlareUI patch 55 (see " .. Cmd("/flarequestie status") .. ").")
        elseif search:find("%S") then
            OpenSearch(false)
            searchBox:SetText(search:match("^%s*(.-)%s*$"))
        else
            CloseSearch()
        end
        return
    end
    local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
    if cmd == "" or cmd == "settings" or cmd == "options" then
        if not OpenSettings() then Help() end
    elseif cmd == "help" or cmd == "?" then
        Help()
    elseif cmd == "status" then
        Status()
    elseif cmd == "distance" and (arg == "on" or arg == "off") then
        SetDistance(arg == "on")
        Print("quest distances " .. OnOff(db.distance))
    elseif cmd == "compact" and (arg == "on" or arg == "off") then
        SetCompact(arg == "on")
        if not (OT and OT.Constants) then
            Print("compact spacing needs FlareUI patch 53 (see " .. Cmd("/flarequestie status")
                .. ").")
        else
            Print("compact spacing " .. OnOff(db.compact) .. ", after " .. Cmd("/reload"))
        end
    elseif cmd == "fonts" and FONT_SIZES[arg] then
        if not NeedTracker() then return end
        if SetFontSizes(arg) then
            Print("tracker fonts " .. arg)
        else
            Print("FlareUI's tracker settings not found.")
        end
    elseif cmd == "size" and arg == "reset" then
        if not NeedTracker() then return end
        if ResetSize() then Print("tracker size back to FlareUI's default") end
    else
        Print(('unknown command "%s"'):format(msg:match("^%s*(.-)%s*$")))
        Help()
    end
end
