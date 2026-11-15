--===========================================================================
-- EzWoW - Smart Fishing
-- Modules/FishingLog.lua : the full catch log and what happened while fishing
--===========================================================================
-- Kept only in this account's saved data (never shared), for the last
-- KEEP_DAYS days (older lines are dropped at login and while new ones come in):
--   catchLog : every catch, oldest first, one short line each
--              "time,itemID,count,mapID,x,y,subzone" (x, y: 0-1 on the map;
--              subzone: index into logSubs, 0 = none).
--   logSubs  : the subzone names the catch lines point to
--   eventLog : while fishing (a fishing session is running): fights (time,
--              length, lowest health, the enemies seen targeting this
--              character, death), deaths outside a fight, whispers, and
--              chat lines with this character's name or family name. Oldest
--              first, the newest EVENT_MAX kept.
-- The game's combat log can't be read by addons on this client: enemies are
-- the ones with a name plate (or targeted) that target this character.
local ADDON, ns = ...
local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall
local format, floor = string.format, math.floor

local FishingLog = ns.FishingLog or {}
ns.FishingLog = FishingLog

local KEEP_DAYS = 3
local KEEP_SECONDS = KEEP_DAYS * 86400
local PRUNE_SLACK = 3600     -- seconds: old lines are dropped in batches, not one by one
local EVENT_MAX = 5000
local MSG_MAX = 400          -- characters of a chat line kept
local FOES_MAX = 5
FishingLog.KEEP_DAYS = KEEP_DAYS

local function isSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function readable(v)
    return v ~= nil and not isSecret(v)
end

-----------------------------------------------------------------------------
-- Catches
-----------------------------------------------------------------------------
local subIndex

local function subID(name)
    local db = ns.db
    if type(name) ~= "string" or name == "" or not db then return 0 end
    if not subIndex then
        subIndex = {}
        for i, n in ipairs(db.logSubs) do subIndex[n] = i end
    end
    local id = subIndex[name]
    if not id then
        id = #db.logSubs + 1
        db.logSubs[id] = name
        subIndex[name] = id
    end
    return id
end

function FishingLog.AddCatch(t, itemID, count, mapID, x, y, sub)
    local db = ns.db
    if not (db and type(db.catchLog) == "table") or type(itemID) ~= "number" then return end
    if FishingLog.Prune then FishingLog.Prune() end
    db.catchLog[#db.catchLog + 1] = format("%d,%d,%d,%d,%.3f,%.3f,%d", tonumber(t) or time(), itemID,
        tonumber(count) or 1, tonumber(mapID) or 0, tonumber(x) or 0, tonumber(y) or 0, subID(sub))
end

-- one catch line -> { t, id, q, m, x, y, sub }
function FishingLog.ParseCatch(line)
    if type(line) ~= "string" then return nil end
    local t, id, q, m, x, y, s = line:match("^(%d+),(%d+),(%d+),(%d+),([%d%.%-]+),([%d%.%-]+),(%d+)$")
    if not t then return nil end
    local sub = ns.db and ns.db.logSubs and ns.db.logSubs[tonumber(s)]
    return { t = tonumber(t), id = tonumber(id), q = tonumber(q), m = tonumber(m), x = tonumber(x), y = tonumber(y), sub = sub }
end

function FishingLog.CatchTime(line)
    return type(line) == "string" and tonumber(line:match("^(%d+),")) or 0
end

-- drops the lines older than KEEP_DAYS (both logs are oldest first); force:
-- at once, else only when the oldest line is an hour past the limit
function FishingLog.Prune(force)
    local db = ns.db
    if not db then return end
    local cutoff = time() - KEEP_SECONDS
    local limit = force and cutoff or (cutoff - PRUNE_SLACK)
    local catches = db.catchLog
    if type(catches) == "table" and #catches > 0 and FishingLog.CatchTime(catches[1]) < limit then
        -- the subzone names still used get new numbers
        local keep, subs, newID = {}, {}, {}
        for _, line in ipairs(catches) do
            if FishingLog.CatchTime(line) >= cutoff then
                local head, s = line:match("^(.*),(%d+)$")
                s = tonumber(s)
                if head and s then
                    if s > 0 and type(db.logSubs[s]) == "string" then
                        if not newID[s] then
                            subs[#subs + 1] = db.logSubs[s]
                            newID[s] = #subs
                        end
                        s = newID[s]
                    else
                        s = 0
                    end
                    keep[#keep + 1] = head .. "," .. s
                end
            end
        end
        db.catchLog, db.logSubs = keep, subs
        subIndex = nil
    end
    local events = db.eventLog
    if type(events) == "table" and #events > 0 and (type(events[1]) ~= "table" or (events[1].t or 0) < limit) then
        local keep = {}
        for _, e in ipairs(events) do
            if type(e) == "table" and (e.t or 0) >= cutoff then keep[#keep + 1] = e end
        end
        db.eventLog = keep
    end
end

-----------------------------------------------------------------------------
-- Events
-----------------------------------------------------------------------------
-- kept in time order: a fight is written when it ends but placed where it began
local function addEvent(e)
    local db = ns.db
    if not (db and type(db.eventLog) == "table") then return end
    e.t = e.t or time()
    FishingLog.Prune()
    local log = db.eventLog
    local at = #log + 1
    while at > 1 and type(log[at - 1]) == "table" and (log[at - 1].t or 0) > e.t do at = at - 1 end
    table.insert(log, at, e)
    while #log > EVENT_MAX do table.remove(log, 1) end
    ns:PublishAddonEvent("AM_LOG_CHANGED")
end

local function fishing()
    return ns.db ~= nil and ns:Session() ~= nil
end

local function myNames()
    local ok, first, second = pcall(UnitName, "player")
    if not ok then return nil, nil end
    if not readable(first) or type(first) ~= "string" then first = nil end
    if not readable(second) or type(second) ~= "string" or second == "" then second = nil end
    -- the second value is the family name on this client, a realm name elsewhere
    if second then
        local realm = GetRealmName and GetRealmName()
        if realm and (second == realm or second == realm:gsub("%s+", "")) then second = nil end
    end
    return first, second
end

-----------------------------------------------------------------------------
-- Fights
-----------------------------------------------------------------------------
local fight, fightTicker

local function healthPct()
    local okH, h = pcall(UnitHealth, "player")
    local okM, m = pcall(UnitHealthMax, "player")
    if not (okH and okM) or not readable(h) or not readable(m) or type(h) ~= "number" or type(m) ~= "number" or m <= 0 then
        return nil
    end
    return floor(h / m * 100 + 0.5)
end

local function noteHealth()
    if not fight then return end
    local pct = healthPct()
    if pct and (not fight.hp or pct < fight.hp) then fight.hp = pct end
end

local function yes(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, v = pcall(fn, ...)
    return ok and readable(v) and v and true or false
end

-- an enemy unit that targets this character
local function noteFoe(unit)
    if not fight or #fight.foeList >= FOES_MAX then return end
    if not yes(UnitExists, unit) or not yes(UnitCanAttack, "player", unit) then return end
    if not yes(UnitIsUnit, unit .. "target", "player") then return end
    local ok, name = pcall(UnitName, unit)
    if not ok or type(name) ~= "string" or name == "" or not readable(name) or fight.foes[name] then return end
    fight.foes[name] = true
    fight.foeList[#fight.foeList + 1] = name
end

local function scanFoes()
    if not fight then return end
    noteFoe("target")
    for i = 1, 40 do noteFoe("nameplate" .. i) end
    noteHealth()
end

local function fightStart()
    if fight or not fishing() then return end
    fight = { t = time(), foes = {}, foeList = {} }
    scanFoes()
    if C_Timer and C_Timer.NewTicker then fightTicker = C_Timer.NewTicker(1, function() pcall(scanFoes) end) end
end

local function fightEnd()
    if fightTicker then fightTicker:Cancel() fightTicker = nil end
    if not fight then return end
    local f = fight
    fight = nil
    addEvent({ t = f.t, k = "fight", d = math.max(0, time() - f.t), hp = f.hp,
        foes = #f.foeList > 0 and table.concat(f.foeList, ", ") or nil, died = f.died })
end

-----------------------------------------------------------------------------
-- Chat
-----------------------------------------------------------------------------
local CHAT_EVENTS = {
    CHAT_MSG_SAY = "SAY", CHAT_MSG_YELL = "YELL", CHAT_MSG_WHISPER = "WHISPER",
    CHAT_MSG_PARTY = "PARTY", CHAT_MSG_PARTY_LEADER = "PARTY",
    CHAT_MSG_RAID = "RAID", CHAT_MSG_RAID_LEADER = "RAID", CHAT_MSG_RAID_WARNING = "RAID",
    CHAT_MSG_INSTANCE_CHAT = "INSTANCE", CHAT_MSG_INSTANCE_CHAT_LEADER = "INSTANCE",
    CHAT_MSG_GUILD = "GUILD", CHAT_MSG_OFFICER = "OFFICER", CHAT_MSG_CHANNEL = "CHANNEL",
    CHAT_MSG_EMOTE = "EMOTE", CHAT_MSG_TEXT_EMOTE = "TEXT_EMOTE",
}

-- a name long enough not to match by chance (two letters or more)
local function usableName(name)
    if type(name) ~= "string" then return nil end
    local letters = 0
    for _ in name:gmatch("[%z\1-\127\194-\244][\128-\191]*") do letters = letters + 1 end
    if letters < 2 or #name < 3 then return nil end
    return name:lower()
end

local function onChat(event, msg, sender, _, _, _, _, _, _, channelName, _, _, guid)
    local kind = CHAT_EVENTS[event]
    if not kind or not fishing() then return end
    if not readable(msg) or not readable(sender) or type(msg) ~= "string" or type(sender) ~= "string" then return end
    -- my own lines
    if readable(guid) and type(guid) == "string" and guid == UnitGUID("player") then return end
    local first, family = myNames()
    local shortSender = Ambiguate and Ambiguate(sender, "none") or sender
    if first and (shortSender == first or sender == first) then return end
    if kind == "CHANNEL" and readable(channelName) and type(channelName) == "string" and channelName:find("^EzWoW") then return end
    local lower = msg:lower()
    local hit = kind == "WHISPER"
    if not hit then
        for _, name in ipairs({ usableName(first), usableName(family) }) do
            if name and lower:find(name, 1, true) then hit = true break end
        end
    end
    -- an emote done at this character ("... at you")
    if not hit and kind == "TEXT_EMOTE" and type(_G.YOU) == "string" and _G.YOU ~= "" then
        hit = lower:find(_G.YOU:lower(), 1, true) ~= nil
    end
    if not hit then return end
    if #msg > MSG_MAX then msg = msg:sub(1, MSG_MAX) end
    addEvent({ k = "chat", ch = kind, cn = (kind == "CHANNEL" and readable(channelName) and type(channelName) == "string") and channelName or nil,
        from = shortSender, msg = msg, me = first })
end

-----------------------------------------------------------------------------
-- Events
-----------------------------------------------------------------------------
ns:SubscribeAddonEvent("AM_DB_READY", function()
    local db = ns.db
    db.catchLog = type(db.catchLog) == "table" and db.catchLog or {}
    db.logSubs = type(db.logSubs) == "table" and db.logSubs or {}
    db.eventLog = type(db.eventLog) == "table" and db.eventLog or {}
    subIndex = nil
    -- the first time: the catches kept so far (newest first, 100 at most) start the log
    if not db.catchLogSeeded then
        db.catchLogSeeded = true
        if #db.catchLog == 0 and type(db.recent) == "table" then
            for i = #db.recent, 1, -1 do
                local r = db.recent[i]
                if type(r) == "table" then FishingLog.AddCatch(r.t, r.id, r.q, r.m, r.x, r.y, r.sub) end
            end
        end
    end
    FishingLog.Prune(true)
end)

ns:SubscribeAddonEvent("PLAYER_REGEN_DISABLED", function() pcall(fightStart) end)
ns:SubscribeAddonEvent("PLAYER_REGEN_ENABLED", function() pcall(fightEnd) end)
ns:SubscribeAddonEvent("PLAYER_DEAD", function()
    if fight then
        fight.died = true
    elseif fishing() then
        addEvent({ k = "dead" })
    end
end)
ns:SubscribeAddonEvent("UNIT_HEALTH", function(unit)
    if fight and unit == "player" then pcall(noteHealth) end
end)
for event in pairs(CHAT_EVENTS) do
    ns:SubscribeAddonEvent(event, function(...) pcall(onChat, event, ...) end)
end

-- the whole log is cleared with the other records (settings: clear all)
function FishingLog.Clear()
    local db = ns.db
    if not db then return end
    db.catchLog, db.logSubs, db.eventLog = {}, {}, {}
    subIndex = nil
    ns:PublishAddonEvent("AM_LOG_CHANGED")
end
