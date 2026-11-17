--===========================================================================
-- EzWoW - Smart Fishing
-- UI/MapPins.lua : WorldMap Fishing Spot Pin Mixin & Canvas Data Provider
--===========================================================================
local ADDON, ns = ...
-- every EzWoW mark on the maps can be turned off at once, and the marks only
-- the shared records make apart (Libs/EzWoWShare MapMarksOn / SharedMarksOn)
local function ezMapOn(sharedOnly)
    local share = _G.EzWoW_Share
    local fn = type(share) == "table" and share[sharedOnly and "SharedMarksOn" or "MapMarksOn"]
    if type(fn) ~= "function" then return true end
    local ok, on = pcall(fn)
    return not ok or on ~= false
end
local type, pairs, ipairs, tonumber, tostring, select, pcall = type, pairs, ipairs, tonumber, tostring, select, pcall
-- frames on the open map are made without a parent and put in afterwards (Libs/EzWoWGamePad: MakeFrame)
local CreateFrame = (ns.GamePad and ns.GamePad.MakeFrame) or CreateFrame

-- With the gamepad UI on, the pins are made outside the map's pin pools: the map runs the
-- mouse code of the pins near its gamepad cursor itself, and addon code there taints its
-- gamepad steps (Libs/EzWoWGamePad: AcquireMapPin / RemoveMapPins)
local function acquirePin(map, template, ...)
    local pad = ns.GamePad
    if pad and pad.AcquireMapPin then return pad.AcquireMapPin(map, template, ...) end
    return map:AcquirePin(template, ...)
end
local function removePins(map, template)
    local pad = ns.GamePad
    if pad and pad.RemoveMapPins then return pad.RemoveMapPins(map, template) end
    map:RemoveAllPinsByTemplate(template)
end

local WorldMapPinProvider = ns.WorldMapPinProvider or {}
ns.WorldMapPinProvider = WorldMapPinProvider
local L = ns.L
local StyleService = ns.Style

local TEMPLATE = "EzWoW_SmartFishingPinTemplate"
local MAX_TOOLTIP_FISH = 8

local RING = {
    own    = { 0.07, 0.08, 0.10, 0.95 },
    shared = { 0.80, 0.62, 0.25, 0.95 },
    pool   = { 0.30, 0.58, 1.00, 1 },
    zone   = { 0.27, 0.78, 0.88, 0.95 },
    water  = { 0.20, 0.55, 0.75, 0.9 },
}
local SIZE = { own = 20, shared = 18, pool = 18, zone = 26, water = 20 }

-- One mark of all EzWoW map marks is in front: the last one the mouse was on
-- (above every other mark, its label too). It stays in front after the mouse
-- leaves, until another mark is hovered; the one before goes back to its place.
-- Kept in a table all EzWoW addons share (EzWoWMapPinFront).
local function mapPinFront()
    local f = _G.EzWoWMapPinFront
    if type(f) == "table" and (tonumber(f.v) or 0) >= 2 then return f end
    f = { v = 2 }
    local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6,
        FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
    function f.Restore(pin)
        if not pin then return end
        if pin.ezBaseLevel ~= nil then
            if pin.ezBaseStrata then pcall(pin.SetFrameStrata, pin, pin.ezBaseStrata) end
            -- a level its addon gave it since (the marks were drawn again) stays
            if pin:GetFrameLevel() == pin.ezFrontLevel then pcall(pin.SetFrameLevel, pin, pin.ezBaseLevel) end
        end
        pin.ezBaseLevel, pin.ezBaseStrata, pin.ezFrontLevel = nil, nil, nil
        if f.pin == pin then f.pin = nil end
    end
    function f.Raise(pin)
        if not pin then return end
        if f.pin == pin then
            if pin:GetFrameLevel() == pin.ezFrontLevel then return end
            -- drawn again at its own level since it came to the front: raised from there
            pin.ezBaseLevel = pin:GetFrameLevel()
        else
            if f.pin then f.Restore(f.pin) end
            pin.ezBaseLevel, pin.ezBaseStrata = pin:GetFrameLevel(), pin:GetFrameStrata()
            f.pin = pin
        end
        -- the marks of the quest addons sit in HIGH: at least that layer
        if (STRATA[pin.ezBaseStrata] or 0) < STRATA.HIGH then pcall(pin.SetFrameStrata, pin, "HIGH") end
        local parent = pin:GetParent()
        pcall(pin.SetFrameLevel, pin, ((parent and parent:GetFrameLevel()) or 0) + 1200)
        pin.ezFrontLevel = pin:GetFrameLevel()
    end
    _G.EzWoWMapPinFront = f
    return f
end

EzWoW_SmartFishingPinMixin = CreateFromMixins(MapCanvasPinMixin)

function EzWoW_SmartFishingPinMixin:OnLoad()
    
    if self.Label then return end
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:SetScalingLimits(1, 1.0, 1.3)
    StyleService:Round(self, self.Ring)
    StyleService:Round(self, self.Icon)

    self.Label = self:CreateFontString(nil, "OVERLAY")
    self.Label:SetFont(StyleService.font, 11, "OUTLINE")
    self.Label:SetPoint("TOP", self, "BOTTOM", 0, -1)
end

function EzWoW_SmartFishingPinMixin:RingColor(highlight)
    local themeColor = highlight and StyleService.accent or RING[self.entry.kind or "own"]
    self.Ring:SetColorTexture(themeColor[1], themeColor[2], themeColor[3], themeColor[4] or 1)
end

function EzWoW_SmartFishingPinMixin:OnAcquired(entry)
    self.entry = entry
    -- a pin used again for another mark starts at its own level
    mapPinFront().Restore(self)
    local kind = entry.kind or "own"
    local filter = ns.settings.filterFish
    local iconID
    self:SetAlpha(1)
    self.Label:Hide()

    if kind == "pool" then
        iconID = entry.poolType.fish
        self:SetAlpha(0.9)
    elseif kind == "zone" then
        iconID = filter
        self.Label:SetText(string.format("%.0f%%", entry.pct))
        self.Label:SetTextColor(unpack(StyleService.accent))
        self.Label:Show()
    elseif kind == "water" then
        iconID = entry.id
        self:SetAlpha(0.9)
        self.Label:SetText(string.format("%.0f%%", entry.pct))
        self.Label:SetTextColor(unpack(StyleService.accent))
        self.Label:Show()
    else
        local spot = entry.spot
        if filter then
            iconID = filter
            local rate = (spot.fish[filter] or 0) / math.max(1, ns:GetTotalCatchesAtSpot(spot))
            self:SetAlpha(0.55 + 0.45 * rate) 
        else
            iconID = ns:GetTopCaughtFishList(spot)
        end
    end

    self.Icon:SetTexture(iconID and ns:ItemIcon(iconID) or StyleService.ICON_INNER)
    -- this pin stands for others too close to show apart: "+N" (hover shows them)
    local members = entry.members
    if type(members) == "table" and #members > 0 then
        if self.Label:IsShown() then
            self.Label:SetText((self.Label:GetText() or "") .. " +" .. #members)
        else
            self.Label:SetText("+" .. #members)
            self.Label:SetTextColor(unpack(StyleService.muted))
            self.Label:Show()
        end
    end
    
    -- the label under the pin ("55%", "+3") takes the mouse too
    if self.SetHitRectInsets then
        if self.Label:IsShown() then
            local extra = math.max(0, (self.Label:GetStringWidth() or 0) - SIZE[kind] * (ns.settings.pinScale or 1)) / 2
            self:SetHitRectInsets(-extra, -extra, 0, -13)
        else
            self:SetHitRectInsets(0, 0, 0, 0)
        end
    end
    local inset = (kind == "pool") and 3 or 2
    self.Icon:ClearAllPoints()
    self.Icon:SetPoint("TOPLEFT", inset, -inset)
    self.Icon:SetPoint("BOTTOMRIGHT", -inset, inset)
    local size = SIZE[kind] * (ns.settings.pinScale or 1)
    if entry.child and kind ~= "zone" then size = size * 0.7 end
    self:SetSize(size, size)
    self:RingColor(false)
    self:SetPosition(entry.x, entry.y)
end

function WorldMapPinProvider.addFishLines(fish, total, filter)
    for index, recordEntry in ipairs(ns:GetSortedFishBreakdown(fish)) do
        if index > MAX_TOOLTIP_FISH then break end
        local left = "|T" .. ns:ItemIcon(recordEntry.id) .. ":14:14:0:0:64:64:5:59:5:59|t " .. ns:ItemName(recordEntry.id)
        local pct = string.format("%.0f%%", recordEntry.count / total * 100)
        if recordEntry.id == filter then
            GameTooltip:AddDoubleLine(left, pct, 1, 1, 1, StyleService.accent[1], StyleService.accent[2], StyleService.accent[3])
        else
            GameTooltip:AddDoubleLine(left, pct, 1, 1, 1, 0.7, 0.72, 0.76)
        end
    end
end


function EzWoW_SmartFishingPinMixin:OnMouseEnter()
    local entry = self.entry
    if not entry then return end
    -- the hovered mark (and its label) comes to the front of every map mark and stays there
    mapPinFront().Raise(self)
    self:RingColor(true)
    local kind = entry.kind or "own"
    local filter = ns.settings.filterFish
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

    if kind == "zone" then
        GameTooltip:AddLine(ns:MapName(entry.mapID), 1, 1, 1)
        GameTooltip:AddLine(string.format(L["%s 예상 확률 %.1f%%"], ns:ItemName(filter), entry.pct), unpack(StyleService.muted))
        if entry.skill then
            GameTooltip:AddLine(L["권장 숙련 %d"]:format(entry.skill), unpack(StyleService.muted))
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["클릭하면 이 지역 지도로 이동"], unpack(StyleService.muted))
    elseif kind == "water" then
        GameTooltip:AddLine(entry.place or ns:MapName(entry.mapID), 1, 1, 1)
        if filter then
            GameTooltip:AddLine(string.format(L["%s 예상 확률 %.1f%%"], ns:ItemName(filter), entry.pct), unpack(StyleService.muted))
        else
            local list = {}
            for id, p in pairs(entry.fish or {}) do list[#list + 1] = { id = id, p = p } end
            table.sort(list, function(a, b) return a.p > b.p end)
            for index = 1, math.min(MAX_TOOLTIP_FISH, #list) do
                local row = list[index]
                if row.p < 0.5 then break end
                local left = "|T" .. ns:ItemIcon(row.id) .. ":14:14:0:0:64:64:5:59:5:59|t " .. ns:ItemName(row.id)
                GameTooltip:AddDoubleLine(left, string.format("%.0f%%", row.p), 1, 1, 1, 0.7, 0.72, 0.76)
            end
        end
        if entry.skill then
            GameTooltip:AddLine(L["권장 숙련 %d"]:format(entry.skill), unpack(StyleService.muted))
        end
        if not filter then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(L["클릭: 지도에서 이 물고기 지점 보기"], unpack(StyleService.muted))
        end
    elseif kind == "pool" then
        GameTooltip:AddLine(ns:PoolLabel(entry.poolType), 1, 1, 1)
        GameTooltip:AddLine(L["물고기 떼가 나타나는 자리 (기본 데이터)"], unpack(StyleService.muted))
        if entry.child then GameTooltip:AddLine(ns:MapName(entry.mapID), unpack(StyleService.muted)) end
    else
        local spot = entry.spot
        local titleStr = spot.sub
        if entry.child then
            titleStr = ns:MapName(entry.mapID) .. (spot.sub and (" · " .. spot.sub) or "")
        end
        GameTooltip:AddLine(titleStr or L["낚시 지점"], 1, 1, 1)
        if kind == "shared" then
            GameTooltip:AddLine(string.format(L["다른 플레이어 기록 · %d번 낚음"], spot.n), StyleService.accent[1], StyleService.accent[2], StyleService.accent[3])
        else
            GameTooltip:AddLine(string.format(L["내 기록 · %d번 낚음"], spot.n), unpack(StyleService.muted))
        end
        GameTooltip:AddLine(" ")
        WorldMapPinProvider.addFishLines(spot.fish, ns:GetTotalCatchesAtSpot(spot), filter)
        if entry.child then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(L["클릭하면 이 지역 지도로 이동"], unpack(StyleService.muted))
        end
    end
    
    if type(entry.members) == "table" and #entry.members > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["이 근처 %d곳 더 (지도에 작은 점으로 표시)"]:format(#entry.members), unpack(StyleService.muted))
    end
    GameTooltip:AddDoubleLine(" ", "EzWoW - Smart Fishing", 0, 0, 0, 0.5, 0.5, 0.5)
    GameTooltip:Show()
    if _G.EzWoWTooltipTagSizer and _G.EzWoWTooltipTagSizer.Refit then pcall(_G.EzWoWTooltipTagSizer.Refit, GameTooltip) end
    pcall(WorldMapPinProvider.showMembers, self)
end

function EzWoW_SmartFishingPinMixin:OnMouseLeave()
    self:RingColor(false)
    GameTooltip:Hide()
    WorldMapPinProvider.hideMembers()
end

function EzWoW_SmartFishingPinMixin:SetPassThroughButtons(...)
    if InCombatLockdown() then return end
    getmetatable(self).__index.SetPassThroughButtons(self, ...)
end

-- the mouse propagation setters are protected in combat the same way
function EzWoW_SmartFishingPinMixin:SetPropagateMouseClicks(...)
    if InCombatLockdown() then return end
    getmetatable(self).__index.SetPropagateMouseClicks(self, ...)
end

function EzWoW_SmartFishingPinMixin:SetPropagateMouseMotion(...)
    if InCombatLockdown() then return end
    getmetatable(self).__index.SetPropagateMouseMotion(self, ...)
end

function EzWoW_SmartFishingPinMixin:OnMouseClickAction(button)
    if button ~= "LeftButton" or not self.entry then return end
    if self.entry.kind == "water" then
        -- the spot's most likely fish: show only that fish
        if not ns.settings.filterFish and self.entry.id then ns:SetFishFilter(self.entry.id) end
        return
    end
    if self.entry.child then
        ns:GoToMap(self.entry.mapID)
    end
end

-- Our map layer runs from post-hooks on the map instead of being registered
-- as a map data provider: a provider runs inside the map's own update loop,
-- and the game's pins made after it in that loop are then blocked in combat
-- (SetPassThroughButtons). The layer keeps the provider method names.
local function attachMapLayer(map, layer)
    layer.owningMap = map
    layer.GetMap = function() return map end
    local function run(method, ...)
        local fn = layer[method]
        if type(fn) == "function" then fn(layer, ...) end
    end
    hooksecurefunc(map, "OnMapChanged", function() run("OnMapChanged") end)
    for _, method in ipairs({ "OnCanvasScaleChanged", "OnCanvasSizeChanged", "SetGlobalAlpha" }) do
        if type(map[method]) == "function" then
            local target = method == "SetGlobalAlpha" and "OnGlobalAlphaChanged" or method
            hooksecurefunc(map, method, function() run(target) end)
        end
    end
    map:HookScript("OnShow", function() run("OnShow"); run("RefreshAllData", true) end)
    map:HookScript("OnHide", function() run("OnHide") end)
end

local MapDataProvider = CreateFromMixins(MapCanvasDataProviderMixin)

function MapDataProvider:RemoveAllData()
    WorldMapPinProvider.hideMembers()
    removePins(self:GetMap(), TEMPLATE)
end

function WorldMapPinProvider.collectSpots(mapID, source, kind, filter, out)
    for _, entry in ipairs(ns:CollectSpots(mapID, source)) do
        if not filter or entry.spot.fish[filter] then
            entry.kind = kind
            out[#out + 1] = entry
        end
    end
end

-- Pins of one kind closer than THIN_PX of that kind (on screen, at the map's
-- zoom) are thinned out: the strongest one is shown and keeps the others in
-- .members (its "+N" label; hovering it shows them as small dots). Water spots
-- with the same chance (the same fishing table) are merged up to SAME_WATER_PX
-- apart. Then a pin that overlaps a pin of a more important kind (own > shared
-- > pool > water) joins that one (CROSS_PX). Zooming in shows them apart again.
local THIN_PX = { water = 34, pool = 28, shared = 28, own = 28 }
local SAME_WATER_PX = 80
local CROSS_PX = 24
local function pinWeight(entry)
    if entry.kind == "water" then return tonumber(entry.pct) or 0 end
    if entry.spot then return tonumber(entry.spot.n) or 0 end
    return 0
end

-- map units (0..1) per screen pixel across and down, or nil before the map is laid out
local function pixelSize(map)
    local canvas = map.GetCanvas and map:GetCanvas()
    local cw, ch = canvas and canvas:GetWidth() or 0, canvas and canvas:GetHeight() or 0
    local scale = map.GetCanvasScale and map:GetCanvasScale() or 1
    if not (cw > 0 and ch > 0 and scale and scale > 0) then return nil end
    return 1 / (cw * scale), 1 / (ch * scale)
end

local function within(a, b, ux, uy, px)
    local dx, dy = (a.x - b.x) / (ux * px), (a.y - b.y) / (uy * px)
    return dx * dx + dy * dy < 1
end

local function sameChance(a, b)
    return a.kind == "water" and b.kind == "water" and a.pct and b.pct
        and math.floor(a.pct + 0.5) == math.floor(b.pct + 0.5)
end

function WorldMapPinProvider.thin(map, list)
    for i, entry in ipairs(list) do
        entry.members = nil
        entry.order = i
    end
    local ux, uy = pixelSize(map)
    if not ux or #list < 2 then return list end
    local scaleBy = ns.settings.pinScale or 1
    table.sort(list, function(a, b)
        local wa, wb = pinWeight(a), pinWeight(b)
        if wa ~= wb then return wa > wb end
        return a.order < b.order
    end)
    local shown = {}
    for _, entry in ipairs(list) do
        local px = (THIN_PX[entry.kind] or 28) * scaleBy
        local host
        for _, kept in ipairs(shown) do
            if within(entry, kept, ux, uy, px)
                or (sameChance(entry, kept) and within(entry, kept, ux, uy, SAME_WATER_PX * scaleBy)) then
                host = kept
                break
            end
        end
        if host then
            host.members = host.members or {}
            host.members[#host.members + 1] = entry
        else
            shown[#shown + 1] = entry
        end
    end
    return shown
end

-- pins of several kinds, each list thinned: a pin that overlaps a pin of a
-- kind placed before it (the lists come most important first) joins that pin,
-- with its own members. Returns the kept lists in the same order.
function WorldMapPinProvider.thinAcross(map, lists)
    local ux, uy = pixelSize(map)
    local placed, kept = {}, {}
    local px = CROSS_PX * (ns.settings.pinScale or 1)
    for i, list in ipairs(lists) do
        local out = {}
        for _, entry in ipairs(WorldMapPinProvider.thin(map, list)) do
            local host
            if ux then
                for _, other in ipairs(placed) do
                    if within(entry, other, ux, uy, px) then host = other break end
                end
            end
            if host then
                host.members = host.members or {}
                host.members[#host.members + 1] = entry
                for _, m in ipairs(entry.members or {}) do host.members[#host.members + 1] = m end
                entry.members = nil
            else
                out[#out + 1] = entry
                placed[#placed + 1] = entry
            end
        end
        kept[i] = out
    end
    return kept
end

-- the hovered pin's others: small round dots on the map canvas (no mouse)
local memberLayer, memberDots = nil, {}

function WorldMapPinProvider.hideMembers()
    if memberLayer then memberLayer:Hide() end
end

local function memberIcon(entry)
    local kind = entry.kind or "own"
    local id
    if kind == "pool" then
        id = entry.poolType and entry.poolType.fish
    elseif kind == "water" then
        id = entry.id
    elseif entry.spot then
        id = ns.settings.filterFish or ns:GetTopCaughtFishList(entry.spot)
    end
    return id and ns:ItemIcon(id) or StyleService.ICON_INNER
end

function WorldMapPinProvider.showMembers(pin)
    local entry = pin and pin.entry
    local members = entry and entry.members
    local map = MapDataProvider:GetMap()
    if type(members) ~= "table" or #members == 0 or not map then return end
    local canvas = map.GetCanvas and map:GetCanvas()
    if not canvas then return end
    if not memberLayer then
        memberLayer = CreateFrame("Frame", nil, canvas)
        memberLayer:SetAllPoints(canvas)
        memberLayer:EnableMouse(false)
    end
    memberLayer:SetFrameStrata(pin:GetFrameStrata())
    memberLayer:SetFrameLevel(math.max(1, pin:GetFrameLevel() - 1))
    local cw, ch = canvas:GetWidth(), canvas:GetHeight()
    local scale = map.GetCanvasScale and map:GetCanvasScale() or 1
    -- the same size on screen at any zoom (the layer grows with the canvas)
    local size = 11 * (ns.settings.pinScale or 1) / math.max(0.1, scale or 1)
    local ring = RING[entry.kind or "own"] or RING.own
    for i, other in ipairs(members) do
        local dot = memberDots[i]
        if not dot then
            dot = CreateFrame("Frame", nil, memberLayer)
            dot:EnableMouse(false)
            dot.ring = dot:CreateTexture(nil, "BACKGROUND")
            dot.ring:SetAllPoints()
            dot.icon = dot:CreateTexture(nil, "ARTWORK")
            dot.icon:SetPoint("TOPLEFT", 1, -1)
            dot.icon:SetPoint("BOTTOMRIGHT", -1, 1)
            StyleService:Round(dot, dot.ring)
            StyleService:Round(dot, dot.icon)
            memberDots[i] = dot
        end
        dot:SetSize(size, size)
        dot:ClearAllPoints()
        dot:SetPoint("CENTER", memberLayer, "TOPLEFT", other.x * cw, -other.y * ch)
        dot.ring:SetColorTexture(ring[1], ring[2], ring[3], ring[4] or 1)
        dot.icon:SetTexture(memberIcon(other))
        dot:Show()
    end
    for i = #members + 1, #memberDots do memberDots[i]:Hide() end
    memberLayer:Show()
end

-- zooming: thinned out again for the new scale (once the zoom settles). The map
-- calls this on every frame in some states (the gamepad cursor on the map): only
-- a real change of the canvas counts, or the refresh would wait for ever.
local rethinToken = 0
local function canvasKey()
    local map = WorldMapFrame
    local canvasFrame = map and map.GetCanvas and map:GetCanvas()
    local scale = map and map.GetCanvasScale and map:GetCanvasScale()
    if not (canvasFrame and scale) then return nil end
    return string.format("%.3f:%.1f:%.1f", scale, canvasFrame:GetWidth() or 0, canvasFrame:GetHeight() or 0)
end
function MapDataProvider:OnCanvasScaleChanged()
    local key = canvasKey()
    if key and key == self.canvasKey then return end
    self.canvasKey = key
    rethinToken = rethinToken + 1
    local token = rethinToken
    if not (C_Timer and C_Timer.After) then return end
    C_Timer.After(0.3, function()
        if token == rethinToken and WorldMapFrame and WorldMapFrame:IsShown() and MapDataProvider:GetMap() then
            MapDataProvider:RefreshAllData()
        end
    end)
end
MapDataProvider.OnCanvasSizeChanged = MapDataProvider.OnCanvasScaleChanged

function MapDataProvider:RefreshAllData()
    self:RemoveAllData()
    local set = ns.settings
    if not set or not set.showPins or not ezMapOn() then return end
    local map = self:GetMap()
    local mapID = map:GetMapID()
    local filter = set.filterFish

    if filter and set.showExpected then
        for _, zoneRef in ipairs(ns:ZonesForFish(filter)) do
            local rowEntry = ns:GetChildZoneBoundaryRect(zoneRef.mapID, mapID)
            if rowEntry and zoneRef.pct >= 0.5 then
                local zdVal = ns.Data.zones[zoneRef.mapID]
                acquirePin(map, TEMPLATE, {
                    kind = "zone", mapID = zoneRef.mapID, child = true, pct = zoneRef.pct, skill = zoneRef.s or (zdVal and zdVal.s),
                    x = (rowEntry[1] + rowEntry[2]) / 2, y = (rowEntry[3] + rowEntry[4]) / 2,
                })
            end
        end
    end

    -- a zone map: the water where each fishing table applies (the chosen fish, or
    -- the most likely fish of every spot)
    local water, pools, shared, own = {}, {}, {}, {}
    if set.showExpected and ns.WaterSpotsOnMap then
        for _, spot in ipairs(ns:WaterSpotsOnMap(mapID, filter)) do
            spot.kind, spot.mapID, spot.skill = "water", mapID, spot.s
            water[#water + 1] = spot
        end
    end
    if set.showPools then
        for _, entry in ipairs(ns:PoolsOnMap(mapID, filter)) do pools[#pools + 1] = entry end
    end
    if set.showShared and ns.db.shared and ezMapOn(true) then
        WorldMapPinProvider.collectSpots(mapID, ns.db.shared, "shared", filter, shared)
    end
    WorldMapPinProvider.collectSpots(mapID, ns.db.spots, "own", filter, own)
    -- thinned most important first; placed in the other order (own spots on top)
    local kept = WorldMapPinProvider.thinAcross(map, { own, shared, pools, water })
    for i = #kept, 1, -1 do
        for _, entry in ipairs(kept[i]) do
            acquirePin(map, TEMPLATE, entry)
        end
    end
end

function ns:RefreshPins()
    if MapDataProvider:GetMap() and WorldMapFrame:IsShown() then
        MapDataProvider:RefreshAllData()
    end
end

ns:SubscribeAddonEvent("AM_DB_READY", function()
    if MapDataProvider.owningMap then return end
    attachMapLayer(WorldMapFrame, MapDataProvider)
    ns:RefreshPins()
end)
ns:SubscribeAddonEvent("AM_DATA_CHANGED", function() ns:RefreshPins() end)
local PIN_KEYS = { showPins = true, filterFish = true, pinScale = true, showPools = true, showShared = true, showExpected = true }
ns:SubscribeAddonEvent("AM_SETTINGS_CHANGED", function(key)
    if PIN_KEYS[key] then ns:RefreshPins() end
end)

_G.EzWoW_SmartFishingPinMixin = EzWoW_SmartFishingPinMixin

-- the EzWoW map marks turned on or off (Libs/EzWoWShare settings window)
do
    local share = _G.EzWoW_Share
    if type(share) == "table" and type(share.RegisterCallback) == "function" then
        share.RegisterCallback("EzWoW-SmartFishing-Marks", function(kinds)
            if type(kinds) ~= "table" or not kinds.mapMarks then return end
            if ns.RefreshPins then pcall(ns.RefreshPins, ns) end
        end)
    end
end
