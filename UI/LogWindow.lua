--===========================================================================
-- EzWoW - Smart Fishing
-- UI/LogWindow.lua : the log window (HUD "Log" button, /ezsf log)
--===========================================================================
-- Every catch, and the fights, deaths, whispers and chat lines with this
-- character's name noted while fishing (Modules/FishingLog.lua). Newest first,
-- PAGE lines a page, by kind: all / fish / fights / chat.
local ADDON, ns = ...
local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall

local LogWindow = ns.LogWindow or {}
ns.LogWindow = LogWindow
local L = ns.L
local StyleService = ns.Style

local PAGE = 100
local W, H, PAD = 360, 500, 14

local FILTERS = {
    { key = "all", label = "전체" },
    { key = "fish", label = "물고기" },
    { key = "fight", label = "전투" },
    { key = "chat", label = "채팅" },
}

local ICON_FIGHT = "Interface\\Icons\\Ability_DualWield"
local ICON_DEAD = "Interface\\Icons\\Ability_Rogue_FeignDeath"
local ICON_WHISPER = "Interface\\Icons\\INV_Letter_15"
local ICON_CHAT = "Interface\\Icons\\INV_Misc_Note_01"

-- the game's own words for the chat types
local CHANNEL_WORD = { SAY = "SAY", YELL = "YELL", WHISPER = "WHISPER", PARTY = "PARTY", RAID = "RAID",
    INSTANCE = "INSTANCE_CHAT", GUILD = "GUILD", OFFICER = "OFFICER", EMOTE = "EMOTE", TEXT_EMOTE = "EMOTE" }
local CHAT_COLOR_KEY = { INSTANCE = "INSTANCE_CHAT" }

local windowFrame

local function dayText(t)
    local day = date("%Y%m%d", t)
    if day == date("%Y%m%d") then return L["오늘"] end
    if day == date("%Y%m%d", time() - 86400) then return L["어제"] end
    if date("%Y", t) ~= date("%Y") then return date("%Y/%m/%d", t) end
    return date("%m/%d", t)
end

local function fullTime(t)
    return date("%Y/%m/%d %H:%M:%S", t or 0)
end

local function channelLabel(e)
    if e.ch == "CHANNEL" and type(e.cn) == "string" and e.cn ~= "" then return e.cn end
    local word = CHANNEL_WORD[e.ch] and _G[CHANNEL_WORD[e.ch]]
    return type(word) == "string" and word ~= "" and word or tostring(e.ch or "?")
end

local function chatColor(e)
    local info = ChatTypeInfo and ChatTypeInfo[CHAT_COLOR_KEY[e.ch] or e.ch]
    if type(info) == "table" and type(info.r) == "number" then
        return string.format("|cff%02x%02x%02x", info.r * 255, info.g * 255, info.b * 255)
    end
    return "|cffeeeff2"
end

local function onFishClick(d)
    if d.mapID and d.mapID ~= 0 then ns:ShowFishOnMap(d.itemID, d.mapID) end
end

local function catchRow(c)
    local place = ns:MapName(c.m)
    if c.sub then place = place .. " · " .. c.sub end
    return {
        itemID = c.id, mapID = c.m, icon = ns:ItemIcon(c.id),
        title = ns:ItemName(c.id) .. ((c.q or 1) > 1 and ("  |cff8c94a3x" .. c.q .. "|r") or ""),
        sub = place, right = date("%H:%M", c.t), right2 = dayText(c.t),
        hint = (c.m ~= 0) and L["클릭: 지도에서 이 물고기 지점 보기"] or nil,
        onClick = onFishClick,
    }
end

local function eventRow(e)
    local t = e.t or 0
    local row = { right = date("%H:%M", t), right2 = dayText(t) }
    if e.k == "fight" then
        local title = L["전투 %s"]:format(ns:FormatDuration(e.d or 0))
        if e.died then title = title .. "  |cffff6060" .. L["사망"] .. "|r" end
        local parts = { e.foes and L["상대: %s"]:format(e.foes) or L["상대를 알 수 없음"] }
        if e.hp then parts[#parts + 1] = L["생명력 최저 %d%%"]:format(e.hp) end
        row.icon, row.title, row.sub = ICON_FIGHT, title, table.concat(parts, " · ")
        row.tip = { title }
        for _, part in ipairs(parts) do row.tip[#row.tip + 1] = part end
        row.tip[#row.tip + 1] = fullTime(t)
    elseif e.k == "dead" then
        row.icon, row.title, row.sub = ICON_DEAD, "|cffff6060" .. L["사망"] .. "|r", L["전투 밖에서 죽었어요"]
        row.tip = { L["사망"], fullTime(t) }
    else
        local head = chatColor(e) .. "[" .. channelLabel(e) .. "]|r " .. tostring(e.from or "?")
        row.icon = (e.ch == "WHISPER") and ICON_WHISPER or ICON_CHAT
        row.title, row.sub = head, tostring(e.msg or "")
        row.tip = { head, tostring(e.msg or ""), fullTime(t) }
    end
    return row
end

local function matches(e, filter)
    if type(e) ~= "table" then return false end
    if filter == "fight" then return e.k == "fight" or e.k == "dead" end
    if filter == "chat" then return e.k == "chat" end
    return true
end

-- rows of one page and how many lines the kind has in all
function LogWindow.Collect(filter, page)
    local db = ns.db or {}
    local catches = type(db.catchLog) == "table" and db.catchLog or {}
    local events = type(db.eventLog) == "table" and db.eventLog or {}
    local FL = ns.FishingLog
    local rows, total = {}, 0
    local skip = (page - 1) * PAGE
    if filter == "fish" then
        total = #catches
        local i = #catches - skip
        while i >= 1 and #rows < PAGE do
            local c = FL.ParseCatch(catches[i])
            if c then rows[#rows + 1] = catchRow(c) end
            i = i - 1
        end
    elseif filter == "fight" or filter == "chat" then
        for i = #events, 1, -1 do
            local e = events[i]
            if matches(e, filter) then
                total = total + 1
                if total > skip and #rows < PAGE then rows[#rows + 1] = eventRow(e) end
            end
        end
    else
        -- both logs are in time order: walk them back together
        total = #catches + #events
        local ci, ei, n = #catches, #events, 0
        local ct = ci > 0 and FL.CatchTime(catches[ci]) or 0
        while (ci > 0 or ei > 0) and #rows < PAGE do
            local e = ei > 0 and events[ei] or nil
            local et = type(e) == "table" and (e.t or 0) or 0
            n = n + 1
            if ci > 0 and (ei == 0 or ct >= et) then
                if n > skip then
                    local c = FL.ParseCatch(catches[ci])
                    if c then rows[#rows + 1] = catchRow(c) end
                end
                ci = ci - 1
                ct = ci > 0 and FL.CatchTime(catches[ci]) or 0
            else
                if n > skip and type(e) == "table" then rows[#rows + 1] = eventRow(e) end
                ei = ei - 1
            end
        end
    end
    return rows, total
end

local function counts()
    local db = ns.db or {}
    local fights, chats = 0, 0
    for _, e in ipairs(type(db.eventLog) == "table" and db.eventLog or {}) do
        if type(e) == "table" then
            if e.k == "chat" then chats = chats + 1 else fights = fights + 1 end
        end
    end
    local fish = type(db.catchLog) == "table" and #db.catchLog or 0
    return fish, fights, chats
end

local function bigNumber(n)
    if type(BreakUpLargeNumbers) == "function" then
        local ok, text = pcall(BreakUpLargeNumbers, n)
        if ok and type(text) == "string" then return text end
    end
    return tostring(n)
end

local function smallButton(parent, text, onClick)
    local b = StyleService:Button(parent, text, onClick)
    b:SetHeight(22)
    return b
end

function LogWindow.Build()
    local f = CreateFrame("Frame", "EzWoW_SmartFishingLogWindow", UIParent, "BackdropTemplate")
    StyleService:Panel(f)
    f:SetSize(W, H)
    local pos = ns.db and ns.db.logPos
    if type(pos) == "table" and pos[1] then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint("CENTER")
    end
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        if ns.db then ns.db.logPos = { point, relativePoint, x, y } end
    end)
    tinsert(UISpecialFrames, "EzWoW_SmartFishingLogWindow")

    f.logo = f:CreateTexture(nil, "ARTWORK")
    f.logo:SetSize(26, 26)
    f.logo:SetPoint("TOPLEFT", PAD, -PAD)
    f.logo:SetTexture(StyleService.ICON)
    StyleService:Round(f, f.logo)

    f.title = StyleService:Text(f, 14)
    f.title:SetPoint("TOPLEFT", f.logo, "TOPRIGHT", 10, -1)
    f.counts = StyleService:Text(f, 10, StyleService.muted)
    f.counts:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)

    local close = CreateFrame("Button", nil, f)
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", -8, -8)
    close.t = StyleService:Text(close, 16, StyleService.muted)
    close.t:SetPoint("CENTER")
    close.t:SetText("×")
    close:SetScript("OnEnter", function(self) self.t:SetTextColor(unpack(StyleService.text)) end)
    close:SetScript("OnLeave", function(self) self.t:SetTextColor(unpack(StyleService.muted)) end)
    close:SetScript("OnClick", function() f:Hide() end)

    f.filter, f.page = "all", 1
    f.filters = {}
    for index, item in ipairs(FILTERS) do
        local b = smallButton(f, L[item.label], function()
            f.filter, f.page = item.key, 1
            f.list:SetVerticalScroll(0)
            f:Refresh()
        end)
        b.key, b.label = item.key, item.label
        f.filters[index] = b
    end

    local line = StyleService:Line(f)
    line:SetPoint("TOPLEFT", 0, -88)
    line:SetPoint("TOPRIGHT", 0, -88)

    f.list = StyleService:List(f)
    f.list:SetPoint("TOPLEFT", PAD - 6, -94)
    f.list:SetPoint("BOTTOMRIGHT", -PAD + 6, 42)

    local function turn(delta)
        f.page = math.max(1, f.page + delta)
        f.list:SetVerticalScroll(0)
        f:Refresh()
    end
    f.prev = smallButton(f, "<", function() turn(-1) end)
    f.prev:SetPoint("BOTTOMLEFT", PAD, PAD)
    f.pageText = StyleService:Text(f, 11, StyleService.muted)
    f.pageText:SetPoint("LEFT", f.prev, "RIGHT", 8, 0)
    f.next = smallButton(f, ">", function() turn(1) end)
    f.next:SetPoint("LEFT", f.pageText, "RIGHT", 8, 0)
    f.newest = smallButton(f, "", function() f.page = 1; f.list:SetVerticalScroll(0); f:Refresh() end)
    f.newest:SetPoint("BOTTOMRIGHT", -PAD, PAD)

    function f:Refresh()
        self.title:SetText(L["낚시 기록"])
        local fish, fights, chats = counts()
        self.counts:SetText(L["물고기 %s · 전투 %d · 채팅 %d"]:format(bigNumber(fish), fights, chats)
            .. "  |cff8c94a3(" .. L["최근 %d일"]:format(ns.FishingLog and ns.FishingLog.KEEP_DAYS or 3) .. ")|r")
        local x = PAD
        for _, b in ipairs(self.filters) do
            b:SetLabel(L[b.label])
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", x, -56)
            x = x + b:GetWidth() + 6
            b.t:SetTextColor(unpack(b.key == self.filter and StyleService.accent or StyleService.text))
        end
        local rows, total = LogWindow.Collect(self.filter, self.page)
        local pages = math.max(1, math.ceil(total / PAGE))
        if self.page > pages then
            self.page = pages
            rows, total = LogWindow.Collect(self.filter, self.page)
        end
        if self.filter == "chat" then
            self.list:SetEmptyText(L["낚시하는 동안 주 이름이나 보조 이름이 나온 채팅과\n귓속말이 여기에 남아요."])
        elseif self.filter == "fight" then
            self.list:SetEmptyText(L["낚시하는 동안 일어난 전투가 여기에 남아요."])
        else
            self.list:SetEmptyText(L["아직 기록이 없어요.\n물고기를 낚으면 시간과 위치가 남아요."])
        end
        self.list:SetData(rows)
        self.pageText:SetText(L["%d / %d쪽"]:format(self.page, pages))
        self.prev:SetEnabled(self.page > 1)
        self.prev:SetAlpha(self.page > 1 and 1 or 0.4)
        self.next:SetEnabled(self.page < pages)
        self.next:SetAlpha(self.page < pages and 1 or 0.4)
        self.newest:SetLabel(L["최신"])
        self.newest:SetShown(self.page > 1)
    end

    f:SetScript("OnShow", function(self) self:Refresh() end)
    f:Hide()
    return f
end

function ns:ToggleLogWindow()
    windowFrame = windowFrame or LogWindow.Build()
    windowFrame:SetShown(not windowFrame:IsShown())
end

local pending = false
local function refreshSoon()
    if not windowFrame or not windowFrame:IsShown() or pending then return end
    pending = true
    C_Timer.After(0.2, function()
        pending = false
        if windowFrame and windowFrame:IsShown() then windowFrame:Refresh() end
    end)
end
ns:SubscribeAddonEvent("AM_LOG_CHANGED", refreshSoon)
ns:SubscribeAddonEvent("AM_DATA_CHANGED", refreshSoon)
ns:SubscribeAddonEvent("AM_SETTINGS_CHANGED", refreshSoon)
ns:SubscribeAddonEvent("GET_ITEM_INFO_RECEIVED", refreshSoon)
-- (C_Item.RequestLoadItemDataByID answers only with ITEM_DATA_LOAD_RESULT on this client, 2026-11-22)
ns:SubscribeAddonEvent("ITEM_DATA_LOAD_RESULT", refreshSoon)
