--===========================================================================
-- EzWoW - Smart Fishing
-- Modules/FishingCast.lua : Double-Right-Click Secure Casting, Lure & Bobber Soft-Target
--===========================================================================
local ADDON, ns = ...
local type, pairs, ipairs, tonumber, tostring, select, pcall = type, pairs, ipairs, tonumber, tostring, select, pcall

local DoubleClickCastEngine = ns.DoubleClickCastEngine or {}
local L = ns.L
ns.DoubleClickCastEngine = DoubleClickCastEngine

local FISHING_IDS = { 131474, 7620, 7731, 7732, 18248 }
local FISHING_SET = {}
for _, entityID in ipairs(FISHING_IDS) do FISHING_SET[entityID] = true end

-- skill = fishing skill needed to use the lure
local LURES = {
    { id = 6533, bonus = 100, skill = 100 },
    { id = 6532, bonus = 75, skill = 100 },
    { id = 7307, bonus = 75, skill = 100 },
    { id = 6811, bonus = 50, skill = 50 },
    { id = 6530, bonus = 50, skill = 50 },
    { id = 6529, bonus = 25, skill = 1 },
}

local ownerFrame = CreateFrame("Frame", "EzWoW_SmartFishingBindingOwner")
local castButton = CreateFrame("Button", "EzWoW_SmartFishingCastButton", UIParent, "SecureActionButtonTemplate")
castButton:SetAttribute("type", "macro")
castButton:Hide()

-- The binding clicks the button on key down and again on key up. Listen to
-- only one of the two (the one the game's "cast on key down" option picks),
-- so one key press casts once and puts the lure on only once.
local clickDirectionPending
function DoubleClickCastEngine.refreshClickDirection()
    if InCombatLockdown() then
        clickDirectionPending = true
        return
    end
    clickDirectionPending = nil
    local isCallOk, useKeyDown = false, nil
    if C_CVar and C_CVar.GetCVarBool then
        isCallOk, useKeyDown = pcall(C_CVar.GetCVarBool, "ActionButtonUseKeyDown")
    end
    castButton:RegisterForClicks((isCallOk and useKeyDown) and "AnyDown" or "AnyUp")
end
DoubleClickCastEngine.refreshClickDirection()

local mode           
local channeling = false
-- while the player moves the key is given back to the game (so Space jumps);
-- a cast can't start while moving anyway
local moving = false

function DoubleClickCastEngine.resolveFishingSpellName()
    for _, entityID in ipairs(FISHING_IDS) do
        if IsPlayerSpell(entityID) then
            return C_Spell.GetSpellName(entityID)
        end
    end
    return C_Spell.GetSpellName(7620)
end

function DoubleClickCastEngine.hasFishingSpell(spellID)
    spellID = ns.CoerceSafeNumber(spellID)
    if spellID and FISHING_SET[spellID] then return true end
    local displayName = spellID and C_Spell.GetSpellName(spellID)
    return displayName ~= nil and displayName == DoubleClickCastEngine.resolveFishingSpellName()
end

ns.IsFishingSpell = DoubleClickCastEngine.hasFishingSpell

function ns:FishingSkill()
    if not GetProfessions then return nil end
    local isCallOk, _, _, _, fishing = pcall(GetProfessions)
    if not isCallOk or not fishing then return nil end
    local ok2, _, _, rank, maxRank, _, _, _, modifier = pcall(GetProfessionInfo, fishing)
    if not ok2 or not rank then return nil end
    return rank, maxRank, modifier or 0
end

function ns:LureRemaining()
    local containsMain, expiration = GetWeaponEnchantInfo()
    if containsMain and expiration then return expiration / 1000 end
end

function DoubleClickCastEngine.hasPole(itemID)
    if not itemID then return false end
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
    
    return (classID == 2 and subClassID == 20) or (classID == 19 and subClassID == 10)
end

function DoubleClickCastEngine.containsPole()
    return DoubleClickCastEngine.hasPole(GetInventoryItemID("player", 16)) or DoubleClickCastEngine.hasPole(GetInventoryItemID("player", 28))
end

function ns:HasPole() return DoubleClickCastEngine.containsPole() end

-- Only lures the player can actually use: the client's own check first,
-- then the skill table (in case the item is not cached yet).
function DoubleClickCastEngine.canUseLure(lure)
    if C_Item.IsUsableItem then
        local isCallOk, usable = pcall(C_Item.IsUsableItem, lure.id)
        if isCallOk and usable == false then return false end
    end
    local rank = ns:FishingSkill()
    if rank and lure.skill and rank < lure.skill then return false end
    return true
end

function DoubleClickCastEngine.resolveBestLure()
    for _, lure in ipairs(LURES) do
        if C_Item.GetItemCount(lure.id) > 0 and DoubleClickCastEngine.canUseLure(lure) then return lure end
    end
end

function DoubleClickCastEngine.needsLure()
    if not ns.settings.autoLure then return false end
    local containsMainHandEnchant = GetWeaponEnchantInfo()
    if containsMainHandEnchant then return false end
    return DoubleClickCastEngine.resolveBestLure() ~= nil
end

-- Clams caught while fishing are opened as soon as the catch is in the bags
-- (out of combat, with no cast, loot window or trade window open), and what
-- they hold goes into the bags without the loot window. Only clams fishing
-- brought in this session are opened (not ones kept from elsewhere). If the
-- game does not let the addon open them, the next press of the one-button
-- key opens one before casting.
local CLAMS = { 5523, 5524, 7973 }
local CLAM_SET = {}
for _, itemID in ipairs(CLAMS) do CLAM_SET[itemID] = true end
-- everything the three clams can hold: clam meat and pearls
local CLAM_CONTENTS = { [5503] = true, [5504] = true, [7974] = true, [5498] = true, [5500] = true, [7971] = true, [13926] = true }
-- meat plus a pearl at most
local CLAM_FREE_SLOTS = 2
-- with one of these open, using a bag item would sell, store, mail or trade it
local ITEM_MOVING_FRAMES = { "MerchantFrame", "BankFrame", "MailFrame", "TradeFrame", "AuctionHouseFrame", "AuctionFrame", "GuildBankFrame" }

local clamOpenTimer = false
local directClamAt = -10
local clamBagsFullTold = false
-- clams fishing brought in, by item ID (one less each time one is opened)
local caughtClams = {}
local clamLootCounted, clamOpenCounted = false, false
local lastClamOffered
-- trade-type windows open now, from their open and close events
local tradeWindows = {}

function DoubleClickCastEngine.freeBagSlots()
    if not (C_Container and C_Container.GetContainerNumFreeSlots) then return 0 end
    local free = 0
    for bag = 0, 4 do
        local isCallOk, slots, bagFamily = pcall(C_Container.GetContainerNumFreeSlots, bag)
        slots, bagFamily = ns.CoerceSafeNumber(slots), ns.CoerceSafeNumber(bagFamily)
        if isCallOk and slots and (bagFamily == nil or bagFamily == 0) then free = free + slots end
    end
    return free
end

-- bag, slot and item ID of the first clam in the bags
function DoubleClickCastEngine.findClam()
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then return nil end
    for bag = 0, 4 do
        local _, numSlots = pcall(C_Container.GetContainerNumSlots, bag)
        for slot = 1, ns.CoerceSafeNumber(numSlots) or 0 do
            local isCallOk, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
            local itemID = isCallOk and type(info) == "table" and ns.CoerceSafeNumber(info.itemID)
            if itemID and CLAM_SET[itemID] and (caughtClams[itemID] or 0) > 0 then
                local locked = ns.IsReadableValue(info.isLocked) and info.isLocked == true
                if not locked then return bag, slot, itemID end
            end
        end
    end
    return nil
end

-- a clam to open now (option on and room for what it holds), or nil
function DoubleClickCastEngine.resolveClam()
    if not (ns.settings and ns.settings.autoClam) then return nil end
    local bag, slot, itemID = DoubleClickCastEngine.findClam()
    if not bag then return nil end
    if DoubleClickCastEngine.freeBagSlots() < CLAM_FREE_SLOTS then
        if not clamBagsFullTold then
            clamBagsFullTold = true
            ns:Print(L["가방 빈칸이 2칸보다 적어서 조개를 열지 않았어요."])
        end
        return nil
    end
    clamBagsFullTold = false
    lastClamOffered = itemID
    return bag, slot, itemID
end

-- the interaction types whose windows take a used bag item (sell, store, mail, trade)
local TRADE_INTERACTIONS = { "Merchant", "Banker", "MailInfo", "Auctioneer", "GuildBanker", "TradePartner" }

function DoubleClickCastEngine.itemWindowOpen()
    if next(tradeWindows) then return true end
    for _, frameName in ipairs(ITEM_MOVING_FRAMES) do
        local frame = _G[frameName]
        if type(frame) == "table" and frame.IsShown and frame:IsShown() then return true end
    end
    -- a window of another look (the game's own state, whatever frame shows it)
    local pim = C_PlayerInteractionManager
    local types = Enum and Enum.PlayerInteractionType
    if pim and type(pim.IsInteractingWithNpcOfType) == "function" and types then
        for _, name in ipairs(TRADE_INTERACTIONS) do
            local kind = types[name]
            if kind then
                local ok, open = pcall(pim.IsInteractingWithNpcOfType, kind)
                if ok and issecretvalue and issecretvalue(open) then return true end
                if ok and open == true then return true end
            end
        end
    end
    return false
end

-- the game refused the addon opening a clam on this build: the key opens them
function DoubleClickCastEngine.directClamBlocked()
    return ns.db ~= nil and ns.db.clamOpenBlocked ~= nil and ns.db.clamOpenBlocked == (select(2, GetBuildInfo()))
end

function DoubleClickCastEngine.openClamNow()
    clamOpenTimer = false
    if not (ns.settings and ns.settings.autoClam) or not ns.db or DoubleClickCastEngine.directClamBlocked() then return end
    if not (C_Container and C_Container.UseContainerItem) then return end
    if InCombatLockdown() or channeling or not DoubleClickCastEngine.containsPole() then return end
    local castName = ns.UnwrapSafeValue(UnitCastingInfo, "player")
    local channelName = ns.UnwrapSafeValue(UnitChannelInfo, "player")
    if type(castName) ~= "nil" or type(channelName) ~= "nil" then return end
    if ns.UnwrapSafeValue(SpellIsTargeting) == true or ns.UnwrapSafeValue(CursorHasItem) == true then return end
    if (ns.CoerceSafeNumber(ns.UnwrapSafeValue(GetNumLootItems)) or 0) > 0 then return end
    if DoubleClickCastEngine.itemWindowOpen() then return end
    -- one clam at a time: the next one after this one's loot is in the bags
    local waited = GetTime() - directClamAt
    if waited < 1 then
        DoubleClickCastEngine.scheduleClamOpen(1.05 - waited)
        return
    end
    local bag, slot = DoubleClickCastEngine.resolveClam()
    if not bag then return end
    directClamAt = GetTime()
    pcall(C_Container.UseContainerItem, bag, slot)
end

function DoubleClickCastEngine.scheduleClamOpen(delay)
    if clamOpenTimer or not (ns.settings and ns.settings.autoClam) then return end
    clamOpenTimer = true
    C_Timer.After(delay or 0.3, DoubleClickCastEngine.openClamNow)
end

-- loot from a clam: it comes from a clam item, or is all clam meat and pearls
-- (second value: the clam's item ID when the loot tells it)
function DoubleClickCastEngine.isClamLoot()
    local fishingLoot = ns.UnwrapSafeValue(IsFishingLoot)
    if ns.IsReadableValue(fishingLoot) and fishingLoot then return false end
    local numItems = ns.CoerceSafeNumber(ns.UnwrapSafeValue(GetNumLootItems)) or 0
    if numItems == 0 then return false end
    local fromClam, onlyContents, clamID = false, true, nil
    for slot = 1, numItems do
        local guid = ns.CoerceSafeString(ns.UnwrapSafeValue(GetLootSourceInfo, slot))
        if guid and guid:match("^Item%-") and C_Item.GetItemIDByGUID then
            local sourceID = ns.CoerceSafeNumber(ns.UnwrapSafeValue(C_Item.GetItemIDByGUID, guid))
            if sourceID and CLAM_SET[sourceID] then fromClam, clamID = true, sourceID end
        end
        local link = ns.CoerceSafeString(ns.UnwrapSafeValue(GetLootSlotLink, slot))
        local itemID = link and ns.CoerceSafeNumber(ns.UnwrapSafeValue(C_Item.GetItemInfoInstant, link))
        if not (itemID and CLAM_CONTENTS[itemID]) then onlyContents = false end
    end
    return fromClam or (onlyContents and DoubleClickCastEngine.containsPole()), clamID
end

function DoubleClickCastEngine.assembleMacro()
    if DoubleClickCastEngine.needsLure() then
        local lure = DoubleClickCastEngine.resolveBestLure()
        return "/use item:" .. lure.id .. "\n/use 16"
    end
    -- only when the game does not let the addon open them itself (otherwise a
    -- press right after a catch casts as usual)
    if DoubleClickCastEngine.directClamBlocked() and not DoubleClickCastEngine.itemWindowOpen() then
        local clamBag, _, clamID = DoubleClickCastEngine.resolveClam()
        if clamBag then return "/use item:" .. clamID end
    end
    local displayName = DoubleClickCastEngine.resolveFishingSpellName()
    if displayName then return "/cast " .. displayName end
    return ""
end

function DoubleClickCastEngine.assignMode(newMode)
    if InCombatLockdown() then return end
    if newMode == mode then return end
    ClearOverrideBindings(ownerFrame)
    local lookupKey = ns.settings and ns.settings.key or "SPACE"
    if newMode == "cast" then
        SetOverrideBindingClick(ownerFrame, true, lookupKey, "EzWoW_SmartFishingCastButton", "LeftButton")
    elseif newMode == "interact" then
        SetOverrideBinding(ownerFrame, true, lookupKey, "INTERACTTARGET")
    elseif newMode == "mouseover" then
        
        SetOverrideBinding(ownerFrame, true, lookupKey, "INTERACTMOUSEOVER")
    end
    mode = newMode
end

-- the fishing bobber (game object ID)
local BOBBER_OBJECT_ID = 35591

-- The game object ID of a "GameObject-0-...-35591-..." GUID, or nil.
-- Only the object ID field is read: the server and spawn fields around it
-- may be obfuscated.
function DoubleClickCastEngine.resolveGameObjectID(guid)
    guid = ns.CoerceSafeString(guid)
    if not guid then return nil end
    return tonumber(guid:match("^GameObject%-[^-]*%-[^-]*%-[^-]*%-[^-]*%-(%d+)%-"))
end

-- softTargetGUID: the new soft interact target from the change event;
-- without it the current soft interact unit is read.
function DoubleClickCastEngine.resolveBobberTargeted(softTargetGUID)
    local guid = softTargetGUID
    if guid == nil then guid = ns.UnwrapSafeValue(UnitGUID, "softinteract") end
    return DoubleClickCastEngine.resolveGameObjectID(guid) == BOBBER_OBJECT_ID
end

ns.bobberFound = nil

function DoubleClickCastEngine.refreshWithSoftTarget(softTargetGUID)
    if not ns.settings or InCombatLockdown() then return end
    if not ns.settings.oneButton or not DoubleClickCastEngine.containsPole() then
        DoubleClickCastEngine.assignMode(nil)
        return
    end
    if channeling then
        ns.bobberFound = DoubleClickCastEngine.resolveBobberTargeted(softTargetGUID)
        DoubleClickCastEngine.assignMode(ns.bobberFound and "interact" or "mouseover")
    elseif moving then
        ns.bobberFound = nil
        DoubleClickCastEngine.assignMode(nil)
    else
        ns.bobberFound = nil
        castButton:SetAttribute("macrotext", DoubleClickCastEngine.assembleMacro())
        DoubleClickCastEngine.assignMode("cast")
    end
end

-- event handlers pass their own arguments, so they never reach the GUID slot
function DoubleClickCastEngine.refreshActiveView()
    DoubleClickCastEngine.refreshWithSoftTarget(nil)
end
ns.RefreshFishing = DoubleClickCastEngine.refreshActiveView

function DoubleClickCastEngine.assignCVarSafe(displayName, value)
    pcall(function()
        if GetCVar(displayName) ~= nil and GetCVar(displayName) ~= tostring(value) then SetCVar(displayName, value) end
    end)
end

-- The bobber CVars are only changed while a fishing pole is equipped.
-- The values from just before the pole went on are saved (so a crash or
-- disconnect with the pole in hand can still restore them) and put back
-- when the pole comes off, the option is turned off, or on logout.
local SOFT_INTERACT_CVARS = {
    { name = "SoftTargetInteract", value = 3, option = "setSoftInteract" },
    { name = "SoftTargetInteractRange", value = 30, option = "expandInteract" },
    { name = "SoftTargetInteractArc", value = 2, option = "expandInteract" },
    { name = "SoftTargetInteractRangeIsHard", value = 0, option = "expandInteract" },
}
local cvarsFallback = {}
function DoubleClickCastEngine.cvarsBeforePole()
    if not ns.db then return cvarsFallback end
    ns.db.cvarsBeforePole = type(ns.db.cvarsBeforePole) == "table" and ns.db.cvarsBeforePole or {}
    return ns.db.cvarsBeforePole
end

-- no chat lines in the first seconds after login or /reload (they crowd the login chat): a note then
-- waits (2026-11-22 dev check: the interact note went out right after login)
local LOGIN_QUIET = 25
local loadedAt = GetTime and GetTime() or 0
local function afterLogin(fn)
    local wait = LOGIN_QUIET - ((GetTime and GetTime() or 0) - loadedAt)
    if wait > 0 and C_Timer and C_Timer.After then C_Timer.After(wait, fn) else fn() end
end

function DoubleClickCastEngine.commitSoftInteract(forceRestore)
    if InCombatLockdown() and not forceRestore then
        DoubleClickCastEngine.softInteractPending = true
        return
    end
    DoubleClickCastEngine.softInteractPending = nil
    local cvarsBeforePole = DoubleClickCastEngine.cvarsBeforePole()
    local active = not forceRestore and ns.settings and ns.settings.setSoftInteract and DoubleClickCastEngine.containsPole()
    local applied, restored = false, false
    for _, cv in ipairs(SOFT_INTERACT_CVARS) do
        local wanted = active and ns.settings[cv.option]
        local okRead, current = pcall(GetCVar, cv.name)
        if okRead and current ~= nil then
            if wanted then
                if cvarsBeforePole[cv.name] == nil then cvarsBeforePole[cv.name] = current end
                if current ~= tostring(cv.value) then applied = true end
                DoubleClickCastEngine.assignCVarSafe(cv.name, cv.value)
            elseif cvarsBeforePole[cv.name] ~= nil then
                if current ~= cvarsBeforePole[cv.name] then restored = true end
                DoubleClickCastEngine.assignCVarSafe(cv.name, cvarsBeforePole[cv.name])
                cvarsBeforePole[cv.name] = nil
            end
        end
    end
    if forceRestore then return end
    -- tell the player once per change (and once after login if still widened, e.g. after a disconnect)
    local widened = next(cvarsBeforePole) ~= nil
    if widened and (applied or not DoubleClickCastEngine.softInteractAnnounced) then
        DoubleClickCastEngine.softInteractAnnounced = true
        afterLogin(function()
            -- (still widened: the pole may be off again by then)
            if next(DoubleClickCastEngine.cvarsBeforePole()) == nil then return end
            -- joins the pole swap's line (Modules/GearManager.lua)
            if ns.SwapNote then
                ns.SwapNote(L["상호작용 설정을 낚시용으로 바꿈"], nil, true)
            elseif not (ns.settings and ns.settings.swapMessages == false) then
                ns:Print(L["낚싯대를 착용해서 찌를 잘 인식하도록 상호작용 설정을 바꿨어요. 낚시를 마치면 원래대로 돌아갑니다."])
            end
        end)
    elseif restored then
        DoubleClickCastEngine.softInteractAnnounced = nil
        if not (ns.settings and ns.settings.swapMessages == false) then
            afterLogin(function() ns:Print(L["상호작용 설정을 낚싯대 착용 전 값으로 되돌렸어요."]) end)
        end
    end
end

ns:SubscribeAddonEvent("PLAYER_EQUIPMENT_CHANGED", function(slot)
    if slot == 16 or slot == 28 or slot == nil then DoubleClickCastEngine.commitSoftInteract() end
end)
-- CVars set here are what the client saves, so the player's own values are what persist
ns:SubscribeAddonEvent("PLAYER_LOGOUT", function() DoubleClickCastEngine.commitSoftInteract(true) end)

ns:SubscribeAddonEvent("AM_DB_READY", function()
    ns:SubscribeAddonEvent("PLAYER_ENTERING_WORLD", function()
        DoubleClickCastEngine.commitSoftInteract()
        DoubleClickCastEngine.refreshActiveView()
    end)
end)

ns:SubscribeAddonEvent("AM_SETTINGS_CHANGED", function(lookupKey)
    if lookupKey == "setSoftInteract" or lookupKey == "expandInteract" then DoubleClickCastEngine.commitSoftInteract() end
    if lookupKey == "key" then
        DoubleClickCastEngine.assignMode(nil) 
    end
    DoubleClickCastEngine.refreshActiveView()
end)

ns:SubscribeAddonEvent("PLAYER_EQUIPMENT_CHANGED", DoubleClickCastEngine.refreshActiveView)
ns:SubscribeAddonEvent("BAG_UPDATE_DELAYED", DoubleClickCastEngine.refreshActiveView)
ns:SubscribeAddonEvent("UNIT_INVENTORY_CHANGED", function(unit) if unit == "player" then DoubleClickCastEngine.refreshActiveView() end end)
ns:SubscribeAddonEvent("CVAR_UPDATE", function(cvarName)
    cvarName = ns.CoerceSafeString(cvarName)
    if cvarName and cvarName:lower() == "actionbuttonusekeydown" then DoubleClickCastEngine.refreshClickDirection() end
end)
ns:SubscribeAddonEvent("PLAYER_REGEN_ENABLED", function()
    if clickDirectionPending then DoubleClickCastEngine.refreshClickDirection() end
    if DoubleClickCastEngine.softInteractPending then DoubleClickCastEngine.commitSoftInteract() end
    DoubleClickCastEngine.refreshActiveView()
end)

ns:SubscribeAddonEvent("PLAYER_REGEN_DISABLED", function()
    ClearOverrideBindings(ownerFrame)
    mode = nil
end)

ns:SubscribeAddonEvent("PLAYER_STARTED_MOVING", function()
    moving = true
    DoubleClickCastEngine.refreshActiveView()
end)
ns:SubscribeAddonEvent("PLAYER_STOPPED_MOVING", function()
    moving = false
    DoubleClickCastEngine.refreshActiveView()
end)

function DoubleClickCastEngine.refreshBobber(softTargetGUID)
    local before = ns.bobberFound
    DoubleClickCastEngine.refreshWithSoftTarget(softTargetGUID)
    if before ~= ns.bobberFound then ns:PublishAddonEvent("AM_BOBBER_CHANGED") end
end

-- The soft interact target changing (the bobber landing in reach, or the
-- target moving off it) is the trigger. Second argument: the new target GUID.
local softInteractFrame = CreateFrame("Frame")
local softInteractEventOk = pcall(softInteractFrame.RegisterEvent, softInteractFrame, "PLAYER_SOFT_INTERACT_CHANGED")
softInteractFrame:SetScript("OnEvent", function(_, _, _, newTargetGUID)
    if not channeling then return end
    DoubleClickCastEngine.refreshBobber(newTargetGUID)
end)

-- Fallback for a client without that event: look at the soft target a few times a second.
local watcher = CreateFrame("Frame")
local elapsedAcc = 0
watcher:Hide()
watcher:SetScript("OnUpdate", function(self, dt)
    elapsedAcc = elapsedAcc + dt
    if elapsedAcc < 0.15 then return end
    elapsedAcc = 0
    if not channeling then self:Hide() return end
    DoubleClickCastEngine.refreshBobber(nil)
end)

ns:SubscribeAddonEvent("UNIT_SPELLCAST_CHANNEL_START", function(unit, _, spellID)
    if ns.CoerceSafeString(unit) ~= "player" or not DoubleClickCastEngine.hasFishingSpell(spellID) then return end
    channeling = true
    DoubleClickCastEngine.refreshActiveView()
    if not softInteractEventOk then
        elapsedAcc = 0
        watcher:Show()
    end
    ns:PublishAddonEvent("AM_BOBBER_CHANGED")
end)

ns:SubscribeAddonEvent("UNIT_SPELLCAST_CHANNEL_STOP", function(unit, _, spellID)
    if ns.CoerceSafeString(unit) ~= "player" or not channeling then return end
    channeling = false
    DoubleClickCastEngine.refreshActiveView()
    ns:PublishAddonEvent("AM_BOBBER_CHANGED")
end)

-- clams: open after each catch, after combat or a cast, and when a trade-type window closes
local function queueClam() DoubleClickCastEngine.scheduleClamOpen() end
for _, eventName in ipairs({ "BAG_UPDATE_DELAYED", "LOOT_CLOSED", "PLAYER_REGEN_ENABLED", "PLAYER_EQUIPMENT_CHANGED" }) do
    ns:SubscribeAddonEvent(eventName, queueClam)
end
local TRADE_CLOSE = { MERCHANT_CLOSED = "merchant", BANKFRAME_CLOSED = "bank", MAIL_CLOSED = "mail", TRADE_CLOSED = "trade",
    AUCTION_HOUSE_CLOSED = "auction", GUILDBANKFRAME_CLOSED = "guildbank" }
for eventName, key in pairs(TRADE_CLOSE) do
    ns:SubscribeAddonEvent(eventName, function()
        tradeWindows[key] = nil
        queueClam()
    end)
end
ns:SubscribeAddonEvent("PLAYER_ENTERING_WORLD", function() wipe(tradeWindows) end)
ns:SubscribeAddonEvent("UNIT_SPELLCAST_CHANNEL_STOP", function(unit)
    if ns.CoerceSafeString(unit) == "player" then queueClam() end
end)
ns:SubscribeAddonEvent("AM_SETTINGS_CHANGED", function(lookupKey)
    if lookupKey == "autoClam" then queueClam() end
end)
-- a trade-type window opening: the one-button key must not use a clam there
local TRADE_OPEN = { MERCHANT_SHOW = "merchant", BANKFRAME_OPENED = "bank", MAIL_SHOW = "mail", TRADE_SHOW = "trade",
    AUCTION_HOUSE_SHOW = "auction", GUILDBANKFRAME_OPENED = "guildbank" }
for eventName, key in pairs(TRADE_OPEN) do
    ns:SubscribeAddonEvent(eventName, function()
        tradeWindows[key] = true
        DoubleClickCastEngine.refreshActiveView()
        C_Timer.After(0.1, DoubleClickCastEngine.refreshActiveView)
    end)
end

-- clams in fishing loot are counted: those are the ones opened
ns:SubscribeAddonEvent("LOOT_READY", function()
    if clamLootCounted then return end
    local fishingLoot = ns.UnwrapSafeValue(IsFishingLoot)
    if not (ns.IsReadableValue(fishingLoot) and fishingLoot) then return end
    clamLootCounted = true
    for slot = 1, (ns.CoerceSafeNumber(ns.UnwrapSafeValue(GetNumLootItems)) or 0) do
        local link = ns.CoerceSafeString(ns.UnwrapSafeValue(GetLootSlotLink, slot))
        local itemID = link and ns.CoerceSafeNumber(ns.UnwrapSafeValue(C_Item.GetItemInfoInstant, link))
        if itemID and CLAM_SET[itemID] then
            local _, _, quantity = ns.UnwrapSafeValue(GetLootSlotInfo, slot)
            caughtClams[itemID] = (caughtClams[itemID] or 0) + (ns.CoerceSafeNumber(quantity) or 1)
        end
    end
end)
ns:SubscribeAddonEvent("LOOT_CLOSED", function() clamLootCounted, clamOpenCounted = false, false end)

-- what a clam holds goes straight into the bags (and that clam is counted as opened)
ns:SubscribeAddonEvent("LOOT_READY", function(isAutoLoot)
    if not (ns.settings and ns.settings.autoClam) then return end
    local isClam, clamID = DoubleClickCastEngine.isClamLoot()
    if not isClam then return end
    if not clamOpenCounted then
        clamOpenCounted = true
        local id = clamID or lastClamOffered
        if id and (caughtClams[id] or 0) > 0 then caughtClams[id] = caughtClams[id] - 1 end
    end
    if isAutoLoot then return end
    for slot = (ns.CoerceSafeNumber(ns.UnwrapSafeValue(GetNumLootItems)) or 0), 1, -1 do
        LootSlot(slot)
    end
end)

-- the game refusing the addon opening a clam: stop trying on this build
local clamBlockFrame = CreateFrame("Frame")
pcall(clamBlockFrame.RegisterEvent, clamBlockFrame, "ADDON_ACTION_BLOCKED")
pcall(clamBlockFrame.RegisterEvent, clamBlockFrame, "ADDON_ACTION_FORBIDDEN")
clamBlockFrame:SetScript("OnEvent", function(_, _, addonName)
    if ns.CoerceSafeString(addonName) ~= ADDON or GetTime() - directClamAt > 0.5 or not ns.db then return end
    if DoubleClickCastEngine.directClamBlocked() then return end
    ns.db.clamOpenBlocked = (select(2, GetBuildInfo()))
    ns:Print(L["게임이 조개를 저절로 열지 못하게 해서, 원버튼 키를 누를 때마다 하나씩 엽니다."])
end)
