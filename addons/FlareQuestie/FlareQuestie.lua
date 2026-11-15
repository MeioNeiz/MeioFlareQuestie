-- FlareQuestie: FlareUI's quest tracker (the look) fed with Questie's database (the data).
--
-- FlareUI's tracker reads only Blizzard's quest API, which on Forever knows little about
-- where things are. Questie knows every spawn, item and turn-in NPC. Patch 52 gives
-- FlareUI's tracker optional hook points (OT.Local*) that this addon fills; patch 53
-- exposes its spacing for compact mode. Without the patches only the resize grip and
-- the tooltip lines work.

FlareQuestieDB = FlareQuestieDB or {}

local DB_VERSION = 1
local db
local OT -- FlareUI.ObjectiveTracker, set at PLAYER_LOGIN

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffd4a35aFlareQuestie|r: " .. msg)
end

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

-- spawn, areaId, name, distance (yards) of where to go next: the nearest unfinished
-- objective, or the turn-in once the quest is complete
local function Nearest(questID)
    local quest = QuestOf(questID)
    local DU = Module("DistanceUtils")
    if not (quest and DU and DU.GetNearestSpawnForQuest) then return nil end
    local ok, spawn, zone, name, dist = pcall(DU.GetNearestSpawnForQuest, quest)
    if not ok or not spawn or not dist or dist >= NO_DATA then return nil end
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
-- Tooltips: the nearest objective / turn-in under FlareUI's own quest tooltip
--------------------------------------------------
local hookedLines = {}
local lastLine, lastCount

local function AddQuestieLines(line)
    local questID = line.questID
    if not questID or not GameTooltip:IsOwned(line) then return end
    -- FlareUI keeps the tooltip while the mouse moves within one quest: add once per build
    if lastLine == line and lastCount == GameTooltip:NumLines() then return end
    local _, zone, name, dist = Nearest(questID)
    if not name then return end
    local label = C_QuestLog.IsComplete(questID) and "Turn in" or "Nearest"
    local where = ZoneName(zone)
    local right = dist < OTHER_PLACE and ("%d yd"):format(dist) or (where or "")
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine(label .. ": |cffffffff" .. name .. "|r", right,
        0.8, 0.6, 0.34, 0.7, 0.7, 0.7)
    if where and dist < OTHER_PLACE then GameTooltip:AddLine(where, 0.6, 0.6, 0.6) end
    if OT.LocalHooks then
        GameTooltip:AddLine("Alt-click: show on map", 0.5, 0.5, 0.5)
    end
    GameTooltip:Show()
    lastLine, lastCount = line, GameTooltip:NumLines()
end

local function HookLines()
    local holder = _G.FlareUI_ObjectiveTracker
    if not holder then return end
    for _, child in ipairs({ holder:GetChildren() }) do
        local content = child:IsObjectType("ScrollFrame") and child:GetScrollChild()
        if content then
            for _, line in ipairs({ content:GetChildren() }) do
                if not hookedLines[line] and line:IsObjectType("Button") and line.text then
                    hookedLines[line] = true
                    line:HookScript("OnEnter", AddQuestieLines)
                end
            end
        end
    end
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
local FONT_SIZES = { small = { 11, 10, 9 }, default = { 13, 12, 11 } }
local function SetFontSizes(which)
    local tracker, sizes = TrackerDb(), FONT_SIZES[which]
    if not (tracker and sizes) then return false end
    for i, key in ipairs({ "headerFont", "titleFont", "objectiveFont" }) do
        if type(tracker[key]) == "table" then tracker[key].size = sizes[i] end
    end
    if OT and OT.initialized then
        if OT.ApplyLook then OT:ApplyLook() end
        OT:Render()
    end
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

local function InitDB()
    db = FlareQuestieDB
    if (db.dbVersion or 0) < 1 then
        -- before settings had defaults, compact was on unless turned off: keep that for
        -- anyone who already used it; new installs start with FlareUI's own spacing
        if db.fontsSet or db.followSet then db.compact = db.compact ~= false end
        db.compact = db.compact or false
        db.fontsSet, db.followSet = nil, nil
    end
    db.dbVersion = DB_VERSION
end

-- patches 52 and 53, as FlareUI's tracker has them now (a FlareUI update removes them)
local function MissingPatches()
    local missing = {}
    if not OT.LocalHooks then missing[#missing + 1] = "52 (Questie data)" end
    if not OT.Constants then missing[#missing + 1] = "53 (compact spacing)" end
    return missing
end

local function PatchAdvice(missing)
    return ("FlareUI isn't patched (%s), so most features are off. Run mods.ps1 from the"
        .. " FlareQuestie download (see its README), then restart WoW."):format(
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

local function Setup()
    OT = FlareUI and FlareUI.ObjectiveTracker
    if not OT then
        Print("FlareUI's quest tracker not found; nothing to do.")
        return false
    end
    OT.LocalDistance = LocalDistance
    OT.LocalQuestItem = LocalQuestItem
    OT.LocalCompleteText = LocalCompleteText
    OT.LocalShowOnMap = LocalShowOnMap
    hooksecurefunc(OT, "Render", function()
        HookLines()
        if grip then PlaceGrip() else CreateGrip() end
    end)
    hooksecurefunc(OT, "UpdateItemCooldowns", UpdateLocalCooldowns)
    WarnMissingPatches()
    return true
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "FlareQuestie" then return end
        InitDB()
        ApplyCompact()
    elseif event == "PLAYER_LOGIN" then
        if not Setup() then return end
        self:RegisterEvent("BAG_UPDATE_DELAYED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Questie builds its quest data a few seconds after loading in: draw again then
        for _, delay in ipairs({ 3, 8, 20 }) do
            C_Timer.After(delay, function()
                itemSignature = ItemSignature()
                Redraw()
            end)
        end
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
    local missing = MissingPatches()
    if #missing > 0 then Print(PatchAdvice(missing)) end
    if not QuestieLoader then Print("Questie isn't loaded: no Questie data.") return end
    local logged, located, items = 0, 0, 0
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID and info.questID > 0 then
            logged = logged + 1
            if Nearest(info.questID) then located = located + 1 end
            if LocalQuestItem(info.questID) then items = items + 1 end
        end
    end
    Print(("%d quests in the log: Questie locates %d, has a usable item for %d."):format(
        logged, located, items))
    local tracker = TrackerDb()
    if tracker and not (tracker.sortByDistance and not tracker.zoneFirst) then
        Print("Tip: FlareUI Settings > Quest Tracker > Sort: Distance orders quests by the"
            .. " nearest objective.")
    end
    local questie = Questie and Questie.db and Questie.db.profile
    if questie and not questie.trackerFollowSuperTracking then
        Print("Tip: Questie's option Tracker > Follow Blizzard Super Tracking makes its map"
            .. " follow the quest you focus (Ctrl-click) in FlareUI's tracker.")
    end
end

local function Help()
    Print("/flarequestie: status and tips")
    Print("/flarequestie compact on|off: tighter tracker spacing (now "
        .. (db.compact and "on" or "off") .. ")")
    Print("/flarequestie fonts small|default: tracker fonts 11/10/9 or FlareUI's 13/12/11")
    Print("/flarequestie size reset: FlareUI's default tracker width and height")
end

SLASH_FLAREQUESTIE1 = "/flarequestie"
SlashCmdList.FLAREQUESTIE = function(msg)
    if not OT then Print("FlareUI's quest tracker not found.") return end
    local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
    if cmd == "" then
        Status()
    elseif cmd == "compact" and (arg == "on" or arg == "off") then
        db.compact = arg == "on"
        if not OT.Constants then
            Print("Compact spacing needs FlareUI patch 53 (see /flarequestie).")
        else
            Print("Compact spacing " .. arg .. ". /reload to apply.")
        end
    elseif cmd == "fonts" and FONT_SIZES[arg] then
        if SetFontSizes(arg) then
            Print("Tracker fonts: " .. arg .. ".")
        else
            Print("FlareUI's tracker settings not found.")
        end
    elseif cmd == "size" and arg == "reset" then
        local tracker = TrackerDb()
        if tracker then tracker.width, tracker.maxHeight = nil, nil; OT:Render() end
        Print("Tracker size back to FlareUI's default.")
    else
        Help()
    end
end
