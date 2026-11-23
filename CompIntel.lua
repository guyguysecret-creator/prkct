--[[
    Comp Client - Intel edition (made for Potassium)

    OPPONENT INTEL
      - Intel window: the opponent you're fighting - their HP, block meter, parries and kicks left,
        the moves they use most (with %), what they usually do AFTER each move, how far away they
        are when they use it, and a live list of their last moves with how long ago.
      - Resource tags: a small card over each enemy's head with HP, block, parries and kicks.
      - HP and block are read straight from the game. Parries and kicks only exist on THEIR
        computer, so they are counted from the parry / kick animations you see them play and
        refilled with the game's own timers (an estimate - "~" means estimated).

    INFINITE RESOURCES
      - Infinite Force / Block / Parry / Kicks (the same as Comp Client).

    PERFECT TRADE (natural)
      - A swing lands on your block -> you let go and multi them once. "Natural" mode makes it
        human: it doesn't trade every hit (Trade chance), reacts with a random human delay,
        rarely trades many times in a row, and sometimes answers with a plain swing.

    Ctrl + H hides/shows the panel.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

-- clean up an older copy if you re-execute
local GUI_NAME = "CompIntel_UI"
if getgenv and getgenv().CompIntel_Cleanup then pcall(getgenv().CompIntel_Cleanup) end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local settings = {
    force = false,
    block = false,
    parry = false,
    kick = false,
    -- Perfect trade
    perfectTrade = false,  -- a swing lands on your block -> let go and multi them ONCE right after (a trade)
    tradeNatural = true,   -- human-looking: not every hit, random reaction, no endless streaks
    tradeChance = 65,      -- % of blocked hits that get traded (natural mode)
    tradeReact = 110,      -- ms: average reaction time before the trade starts (natural mode, +-40% random)
    tradeStreak = 2,       -- after this many trades in a row the next one is much less likely (natural mode)
    tradePlain = 20,       -- % of trades answered with a plain swing instead of a multi (natural mode)
    tradeTeamCheck = false, -- ON = never trade with your own team
    tradeKey = "None",     -- key that toggles Perfect trade
    -- Opponent intel
    intel = false,         -- the Intel window
    intelTags = false,     -- resource cards over enemies' heads
    intelRange = 60,       -- studs: tags show this far, auto-target looks this far
    intelTeamCheck = false, -- ON = skip your own team (tags + auto-target)
    intelKey = "None",     -- key that shows/hides the Intel window
    -- [UserId] = true: tradeOnly = the ONLY players Perfect trade answers (none ticked = everyone)
    whitelist = { tradeOnly = {} },
}
-- shared so the block-break hook (installed once per game session) always reads the
-- settings of the copy of this script that's currently running
do
    local env = (getgenv and getgenv()) or _G
    env.CompIntel_Settings = settings
end

local connections = {}
local function track(c) table.insert(connections, c); return c end

------------------------------------------------------------------------
-- Infinite Force
------------------------------------------------------------------------
local DRAIN_ATTR, REGEN_ATTR = "AfflictionForceDrainPerTick", "ForceRegenMultiplier"
local REFILL_PER_TICK, REGEN_MULTIPLIER = 450, 100000
local forceConns = {}

local function forceDisconnect()
    for _, c in ipairs(forceConns) do c:Disconnect() end
    table.clear(forceConns)
end

local function forceApply(char)
    forceDisconnect()
    if not char then return end
    local function enforce(attr, value)
        if char:GetAttribute(attr) ~= value then char:SetAttribute(attr, value) end
    end
    enforce(REGEN_ATTR, REGEN_MULTIPLIER)
    enforce(DRAIN_ATTR, -REFILL_PER_TICK)
    table.insert(forceConns, char:GetAttributeChangedSignal(REGEN_ATTR):Connect(function()
        if settings.force then enforce(REGEN_ATTR, REGEN_MULTIPLIER) end
    end))
    table.insert(forceConns, char:GetAttributeChangedSignal(DRAIN_ATTR):Connect(function()
        if settings.force then enforce(DRAIN_ATTR, -REFILL_PER_TICK) end
    end))
end

local function forceRemove(char)
    forceDisconnect()
    if not char then return end
    if char:GetAttribute(REGEN_ATTR) == REGEN_MULTIPLIER then char:SetAttribute(REGEN_ATTR, nil) end
    if char:GetAttribute(DRAIN_ATTR) == -REFILL_PER_TICK then char:SetAttribute(DRAIN_ATTR, nil) end
end

local function setForce(on)
    settings.force = on
    if on then forceApply(LocalPlayer.Character) else forceRemove(LocalPlayer.Character) end
end

track(LocalPlayer.CharacterAdded:Connect(function(char)
    if settings.force then
        task.wait(1) -- let the game's Character component set up first
        if settings.force then forceApply(char) end
    end
end))

-- Some executors send print() to their OWN console instead of Roblox's F9 console, so
-- everything is also kept in a buffer that the menu shows in a small box under the panel.
local logEntries = {}  -- { who = player name or nil (system line), msg = text }
local logSink -- set once the UI exists
local VERBOSE = false -- set true to get "[CompIntel]" lines in your executor console again
local function pushLog(who, msg)
    if VERBOSE then pcall(print, "[CompIntel]", msg) end
    table.insert(logEntries, { who = who, msg = msg })
    if #logEntries > 120 then table.remove(logEntries, 1) end
    if logSink then pcall(logSink) end
end
local function joinArgs(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end
local function log(...) pushLog(nil, joinArgs(...)) end            -- system line
local function logP(who, ...) pushLog(who, joinArgs(...)) end      -- line about one player

------------------------------------------------------------------------
-- Infinite Block
--   How the game does it (Lightsaber.States.Combat.Blocking):
--     The server puts a NumberValue "Block" on your character and lowers it per hit.
--     Your client's handler then: sets BlocksLeft = Value, PLAYS THE HIT-BLOCK
--     ANIMATION + camera shake, and if BlocksLeft <= 0 fires
--     zap.LightsaberStunFromClient.Fire({ BlockBreak = true, StunType = 2 }).
--
--   MODE "hook" (executor has getgc + hookfunction) - keeps the animation:
--     - leave the Block value alone, so the handler + animation run on every hit
--     - hook LightsaberStunFromClient.Fire and drop only block-break stuns
--     - keep your Lightsaber component's BlocksLeft pinned at 140 (full) every frame,
--       so the meter stays full and each new block reports a full meter to the server
--   MODE "delete" (fallback, e.g. Xeno) - no animation:
--     - delete the Block value on your side so hits never reach the client
------------------------------------------------------------------------
local MAX_BLOCK = 140         -- CombatConstants.BLOCK.MAXIMUM
local STUN_BLOCK_BROKEN = 2   -- CombatConstants.ENUM.STUN_TYPE.BLOCK_BROKEN
local blockMode = nil         -- "hook" or "delete", decided the first time block is turned on
local blockConn, blockHookedChar
local stunHooked = false

-- find zap's LightsaberStunFromClient.Fire and hook it (once per game session)
local function hookBlockBreakStun()
    if stunHooked then return true end
    local env = (getgenv and getgenv()) or _G
    if env.CompIntel_StunHooked then
        stunHooked = true
        return true
    end
    if type(getgc) ~= "function" or type(hookfunction) ~= "function" then return false end

    local fireFn
    local ok, list = pcall(getgc, true)
    if not ok or type(list) ~= "table" then return false end
    -- 1) the zap module's export table: { LightsaberStunFromClient = { Fire = fn }, LightsaberBlock = ... }
    for _, t in ipairs(list) do
        if type(t) == "table" then
            local entry = rawget(t, "LightsaberStunFromClient")
            if type(entry) == "table" and rawget(t, "LightsaberBlock") ~= nil
                and type(rawget(entry, "Fire")) == "function" then
                fireFn = rawget(entry, "Fire")
                break
            end
        end
    end
    -- 2) fallback: the function whose constants include its profiler label
    if not fireFn and debug.getconstants then
        for _, f in ipairs(list) do
            if type(f) == "function" and (not iscclosure or not iscclosure(f)) then
                local okC, consts = pcall(debug.getconstants, f)
                if okC and type(consts) == "table" then
                    for _, c in ipairs(consts) do
                        if c == "LightsaberStunFromClient Fire" then fireFn = f break end
                    end
                end
                if fireFn then break end
            end
        end
    end
    if not fireFn then return false end

    local old
    local okH = pcall(function()
        old = hookfunction(fireFn, function(payload, ...)
            -- read live settings through the global so a re-executed script stays in control
            local s = env.CompIntel_Settings
            if s and s.block and type(payload) == "table"
                and (payload.BlockBreak == true or payload.StunType == STUN_BLOCK_BROKEN) then
                return -- swallow the self-reported block break
            end
            return old(payload, ...)
        end)
    end)
    if okH then
        stunHooked = true
        env.CompIntel_StunHooked = true
    end
    return okH
end

local function isBlockValue(obj)
    return obj.Name == "Block" and obj:IsA("NumberValue")
end

local function killBlockValue(obj)
    task.defer(function() -- deferred: reparenting inside ChildAdded can error
        if settings.block and blockMode == "delete" and obj.Parent then
            pcall(function() obj:Destroy() end)
        end
    end)
end

local function blockDeleteHook(char)
    if blockConn then blockConn:Disconnect(); blockConn = nil end
    blockHookedChar = nil
    if not (settings.block and blockMode == "delete" and char) then return end
    for _, child in ipairs(char:GetChildren()) do
        if isBlockValue(child) then killBlockValue(child) end
    end
    blockConn = char.ChildAdded:Connect(function(child)
        if isBlockValue(child) then killBlockValue(child) end
    end)
    blockHookedChar = char
end

local function setBlock(on)
    settings.block = on
    if on and not blockMode then
        if hookBlockBreakStun() then
            blockMode = "hook"
            log("Infinite Block: hook mode (hit-block animation still plays)")
        else
            blockMode = "delete"
            log("Infinite Block: delete mode (no getgc/hookfunction - hit animation won't play)")
        end
    end
    blockDeleteHook(LocalPlayer.Character) -- only does anything in delete mode
end

track(LocalPlayer.CharacterAdded:Connect(function(char)
    if settings.block then blockDeleteHook(char) end
end))

------------------------------------------------------------------------
-- Infinite Parry + Infinite Kicks  (needs an executor with a REAL getgc)
--   Both counters live on your Lightsaber component (Client.Components.Lightsaber):
--     ParriesLeft (max 5)  -> Parrying state does ParriesLeft -= 1
--     KicksLeft   (max 3)  -> Kicking state does KicksLeft -= 1
--   We find YOUR component in memory (has ParriesLeft + KicksLeft and Local == true)
--   and keep both at max every frame. SetParries/SetKicks refresh the circles on the HUD.
------------------------------------------------------------------------
local MAX_PARRIES, MAX_KICKS = 5, 3
local saberComp
-- (v83) memory scanner state - see gcScan below
local GC = { busy = false, nextAt = 0, wait = 2 }
local warnedNoGC = false

local function isMySaber(t)
    if type(t) ~= "table" then return false end
    if type(rawget(t, "ParriesLeft")) ~= "number" or type(rawget(t, "KicksLeft")) ~= "number" then return false end
    return rawget(t, "Local") == true
end

local function saberStillValid(t)
    if not t then return false end
    local ok, valid = pcall(function()
        local cc = rawget(t, "CharacterComponent")
        return isMySaber(t) and cc ~= nil and cc.Instance == LocalPlayer.Character
    end)
    return ok and valid
end


------------------------------------------------------------------------
-- Force pin (fix for "force randomly stops until I toggle it")
--   Cause: the game's drain loop (Character component) only runs
--     `if not (Force <= 0) then Force -= drain end`
--   so with our negative drain it ADDS force - except when Force is exactly 0.
--   And RechargeForce skips normal regen while the drain attribute exists.
--   So once the bar hit 0 (a move costing more than you had, an enemy
--   affliction draining you, etc.) nothing refilled it until you toggled
--   (toggling clears the attribute -> RechargeForce runs -> bar refills).
--   Fix: with getgc, find YOUR Character component and hold Force at MaxForce
--   directly. The attributes stay on as a backup.
------------------------------------------------------------------------
local charComp

local function isMyCharComp(t)
    if type(t) ~= "table" then return false end
    local ok, valid = pcall(function()
        return type(rawget(t, "Force")) == "number"
            and type(rawget(t, "MaxForce")) == "number"
            and t.Instance == LocalPlayer.Character
            and t.SetForce ~= nil
    end)
    return ok and valid
end

-- (v83) THE FREEZE FIX. Finding your saber / character component means walking the game's whole
-- memory (getgc). That used to run INSIDE a Heartbeat frame, all in one go, every 2s whenever the
-- saber wasn't found (unequipped, dead, respawning, in a menu) - and the 2s were counted from the
-- START of the scan, so on a busy server where one scan took over 2s the next one began on the very
-- next frame: the game never got a frame in between and froze until you rejoined.
-- Now: ONE scan at a time, in its own thread, pausing every few thousand objects so the game keeps
-- running; it looks for both components in the same pass with a cheap check first; the wait is
-- counted from when the scan ENDS and doubles (up to 20s) while nothing is found. Respawning or
-- equipping a tool makes the next scan come quickly again.
local function gcScan(wantS, wantC)
    if GC.busy or os.clock() < GC.nextAt then return end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then GC.nextAt = os.clock() + 1 return end
    GC.busy = true
    task.spawn(function()
        local foundS, foundC
        local okRun, errRun = pcall(function()
            local function check(t)
                if type(t) ~= "table" then return end
                if wantS and not foundS and type(rawget(t, "ParriesLeft")) == "number"
                    and type(rawget(t, "KicksLeft")) == "number" and saberStillValid(t) then
                    foundS = t
                end
                if wantC and not foundC and type(rawget(t, "Force")) == "number"
                    and type(rawget(t, "MaxForce")) == "number" and isMyCharComp(t) then
                    foundC = t
                end
            end
            local function done() return (foundS or not wantS) and (foundC or not wantC) end
            -- filtergc is quick where it exists
            if type(filtergc) == "function" then
                if wantS then
                    local ok, res = pcall(filtergc, "table", { Keys = { "ParriesLeft", "KicksLeft" } })
                    if ok and type(res) == "table" then for _, t in pairs(res) do check(t) if foundS then break end end end
                end
                if wantC and not foundC then
                    local ok, res = pcall(filtergc, "table", { Keys = { "Force", "MaxForce" } })
                    if ok and type(res) == "table" then for _, t in pairs(res) do check(t) if foundC then break end end end
                end
            end
            if done() then return end
            if type(getgc) ~= "function" then
                if not warnedNoGC then warnedNoGC = true; log("no getgc in this executor - parry/kicks can't work") end
                return
            end
            local ok, list = pcall(getgc, true)
            if not ok or type(list) ~= "table" then return end
            local n = 0
            for _, t in ipairs(list) do
                check(t)
                if done() then break end
                n += 1
                if n % 3000 == 0 then task.wait() end -- let the game draw a frame
            end
            list = nil
        end)
        if not okRun then warn("[CompIntel] memory scan error: " .. tostring(errRun)) end
        if foundS and saberStillValid(foundS) and not saberStillValid(saberComp) then
            saberComp = foundS
            log("found your lightsaber component")
        end
        if foundC and isMyCharComp(foundC) and not isMyCharComp(charComp) then
            charComp = foundC
            log("Infinite Force: found your character component (bar is held full)")
        end
        local gotAll = (foundS or not wantS) and (foundC or not wantC)
        GC.wait = gotAll and 2 or math.min(GC.wait * 2, 20)
        GC.nextAt = os.clock() + GC.wait
        GC.busy = false
    end)
end
-- respawn / equip: scan again soon instead of waiting out the long back-off
local function gcSoon()
    GC.wait = 2
    GC.nextAt = math.min(GC.nextAt, os.clock() + 0.5)
end
local function gcWatchChar(char)
    gcSoon()
    track(char.ChildAdded:Connect(function(c) if c:IsA("Tool") then gcSoon() end end))
end
if LocalPlayer.Character then gcWatchChar(LocalPlayer.Character) end
track(LocalPlayer.CharacterAdded:Connect(gcWatchChar))

track(RunService.Heartbeat:Connect(function()
    if not settings.force then return end
    if not isMyCharComp(charComp) then
        charComp = nil
        -- quickest: the saber component points at it (no scan needed)
        local cc = saberComp and rawget(saberComp, "CharacterComponent")
        if isMyCharComp(cc) then
            charComp = cc
            log("Infinite Force: found your character component (bar is held full)")
        else
            gcScan(false, true)
            return
        end
    end
    local maxF = rawget(charComp, "MaxForce")
    if rawget(charComp, "Force") < maxF then
        charComp.Force = maxF
        pcall(function() charComp.SetForce:Fire(1) end)
    end
end))

track(RunService.Heartbeat:Connect(function()
    local pinBlock = settings.block and blockMode == "hook"
    if not (settings.parry or settings.kick or pinBlock or settings.perfectTrade) then return end
    if not saberStillValid(saberComp) then
        saberComp = nil
        -- the component is rebuilt when you equip/respawn; scanned for in the background (see gcScan)
        gcScan(true, settings.force and not isMyCharComp(charComp))
        return
    end
    if settings.parry and rawget(saberComp, "ParriesLeft") < MAX_PARRIES then
        saberComp.ParriesLeft = MAX_PARRIES
        pcall(function() saberComp:SetParries() end)
    end
    if settings.kick and rawget(saberComp, "KicksLeft") < MAX_KICKS then
        saberComp.KicksLeft = MAX_KICKS
        pcall(function() saberComp:SetKicks() end)
    end
    if pinBlock then
        local b = rawget(saberComp, "BlocksLeft")
        if type(b) == "number" and b < MAX_BLOCK then
            saberComp.BlocksLeft = MAX_BLOCK
            pcall(function() saberComp:SetBlock() end)
        end
    end
end))

------------------------------------------------------------------------
-- shared helpers
------------------------------------------------------------------------
local AP = {
    DEBUG = false,       -- (only matters when VERBOSE is on)
    learnedParry = {},   -- custom-form parry animation ids (never treated as swings)
}

-- "same team?": Roblox teams, or the same side ("Alignment", e.g. Jedi / Sith). Neutral never counts.
local function sameTeam(plr)
    local mine = LocalPlayer.Team
    if mine ~= nil and plr.Team == mine then return true end
    local ok, same = pcall(function()
        local a = LocalPlayer.Character and LocalPlayer.Character:GetAttribute("Alignment")
        local b = plr.Character and plr.Character:GetAttribute("Alignment")
        if a == nil or b == nil or a ~= b then return false end
        local s = string.lower(tostring(a))
        return not (s == "" or s:find("neutral") or s:find("grey") or s:find("gray") or s:find("none"))
    end)
    return ok and same == true
end

-- "Trade only": when anyone is ticked, Perfect trade answers ONLY those players (nobody ticked = everyone)
local function tradePicked(plr)
    local wl = settings.whitelist and settings.whitelist.tradeOnly
    return wl == nil or next(wl) == nil or wl[plr.UserId] == true
end

-- live ping (smoothed)
local pingEma = 0.08
track(RunService.Heartbeat:Connect(function(dt)
    local okP, p = pcall(function() return LocalPlayer:GetNetworkPing() end)
    if okP and type(p) == "number" then
        local rate = (p > pingEma) and 8 or 1.5
        pingEma = pingEma + (p - pingEma) * math.min(1, dt * rate)
    end
end))
 ------------------------------------------------------------------------ -- animation ids (from the game's own animation lists) ------------------------------------------------------------------------
-- every swing animation id used by the game's forms (Shared.Modules.SaberModule.Animations)
local ATTACK_IDS = {}
for _, id in ipairs({
    6317098079, 6317098902, 6317099741, 6317100331,                 -- single / double
    6669636003, 6669636402, 6669636848, 6669637298,                 -- dual
    6753355600, 6753356943, 6753357989, 6753358978,                 -- temple guard
    6860766921, 6860768068, 6860769042, 6860769691,                 -- temple guard single
    10443651597, 10443656282, 10443658943, 10443661334,             -- dark honor guard / pyke
    73848906817428, 116587032990420, 70845951518050, 88799039982454, -- pyke
    98442653394978, 6368651662,                                     -- dash attacks
}) do ATTACK_IDS[tostring(id)] = true end

-- the kick uses the "ParryBreak" animation (Client.Components.Lightsaber.States.Combat.Kicking)
local KICK_ID = "13552157283"
local DASH_ID = "6302511048" -- Dash_Animation (force dash, E)
-- FLIPS and rolls: while someone flips, their blade whips around their body - that is not a swing.
local FLIP_IDS = {}
for _, id in ipairs({ 6312272936, 6312274072, 6317093733, 6317094309, 6728895746 }) do FLIP_IDS[tostring(id)] = true end
local DASH_ATK_IDS = { ["98442653394978"] = true, ["6368651662"] = true } -- the real dash-attack animations
local plrFlip = {} -- [player] = { trk, t0 (flip first seen), last (last seen) }
local function findFlipTrack(char)
    local hum = char:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return nil end
    local ok, tracks = pcall(animator.GetPlayingAnimationTracks, animator)
    if not ok or type(tracks) ~= "table" then return nil end
    for _, trk in ipairs(tracks) do
        local okId, id = pcall(function() return string.match(trk.Animation.AnimationId, "%d+") end)
        if okId and id and FLIP_IDS[id] then return trk end
    end
    return nil
end
-- "Parry strictness" (0-100): 0 = parry on almost anything near you, 100 = only clear hits
local function strictLerp(loose, strict)
    local s = math.clamp((settings.parryStrict or 60) / 100, 0, 1)
    return loose + (strict - loose) * s
end

-- The game can SWAP a player's attack/block/parry animation ids at runtime (custom
-- animation packs: Animations.ChangeTempleGuard & co), so a fixed attack-id list misses
-- those players. Fix: every animation id the game ships that is NOT an attack is listed
-- here; any other non-looping animation on a player whose saber is out is treated as a
-- swing too ("unknown" attack) - and the id is printed once so you can see it.
local NON_ATTACK_IDS = {}
for _, id in ipairs({
    6312272936, 6312274072, 6317093733, 6317094309, 6728895746,           -- flips, roll
    6584511045, 7873070812,                                               -- throws
    72741768067322, 89740527877951, 128004514519482, 108843758967999,
    91879086197386, 117020519174436,                                      -- force powers
    13552166958, 13552173835, 13552177816, 13552182822,                   -- skids
    6322860474, 6669642689, 101135636991956, 6753364277, 10443668308,     -- parries
    6297531803, 6322313635, 6322315386,                                   -- stuns
    6291932252, 6291933169, 6292610264, 6292625270, 6292146811, 6292155163,
    6291934524, 6291935220, 6292615823, 6292632003,                       -- equip / sheathe
    6317096682, 6688720735, 6753335745, 6860753522, 10443588041, 109060630722907, -- idles
    6317097513, 6312280575, 6312281206, 6312281779, 6312282511, 6669641262,
    7101397703, 6736233297, 7101402353, 6861038808, 6861088961, 6860799757,
    7101356513, 6753361279, 6860759883, 109369432331476,                  -- blocks
    6302511048, 6302512079, 6382639524, 6392682622,                       -- dashes (movement)
}) do NON_ATTACK_IDS[tostring(id)] = true end
-- block poses + block reactions, and parry animations: seeing one of these playing on a player means
-- they are BLOCKING or PARRYING right now - and in this game nobody can swing while doing either
AP.BLOCK_POSE, AP.PARRY_ANIM = {}, {}
for _, id in ipairs({
    6317097513, 6312280575, 6312281206, 6312281779, 6312282511, 6669641262,
    7101397703, 6736233297, 7101402353, 6861038808, 6861088961, 6860799757,
    7101356513, 6753361279, 6860759883, 109369432331476,
}) do AP.BLOCK_POSE[tostring(id)] = true end
for _, id in ipairs({ 6322860474, 6669642689, 101135636991956, 6753364277, 10443668308 }) do
    AP.PARRY_ANIM[tostring(id)] = true
end
-- returns blockPosePlaying, parryPlaying for a character
function AP.scanGuard(char)
    local hum = char:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return false, false end
    local ok, tracks = pcall(animator.GetPlayingAnimationTracks, animator)
    if not ok or type(tracks) ~= "table" then return false, false end
    local blk, par = false, false
    for _, trk in ipairs(tracks) do
        local okId, id, playing = pcall(function() return string.match(trk.Animation.AnimationId, "%d+"), trk.IsPlaying end)
        if okId and id and playing then
            if AP.BLOCK_POSE[id] then blk = true elseif AP.PARRY_ANIM[id] then par = true end
        end
    end
    return blk, par
end
local loggedUnknown = {}

-- returns track, isKick, isUnknownAnim
local function findAttackTrack(char)
    local hum = char:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return nil end
    local ok, tracks = pcall(animator.GetPlayingAnimationTracks, animator)
    if not ok or type(tracks) ~= "table" then return nil end
    local unknown, attack, dash
    local attackPos = math.huge
    for _, trk in ipairs(tracks) do
        local okId, id = pcall(function() return string.match(trk.Animation.AnimationId, "%d+") end)
        if okId and id then
            -- a KICK wins over everything: the swing animation that was playing a moment
            -- earlier can still be fading out and used to hide the kick from us
            if id == KICK_ID then return trk, true, false end
            if ATTACK_IDS[id] then
                -- fast combos: the old swing is still fading while the next one starts.
                -- Always follow the NEWEST one (smallest TimePosition) so we never flip
                -- back and forth between the two and lose our blade-speed history.
                local okP, pos = pcall(function() return trk.TimePosition end)
                if okP and pos < attackPos then attack, attackPos = trk, pos end
            elseif id == DASH_ID then
                dash = dash or trk
            elseif not unknown and not NON_ATTACK_IDS[id] and not AP.learnedParry[id] then
                local okL, looped, len = pcall(function() return trk.Looped, trk.Length end)
                if okL and not looped and len > 0.2 and len < 4 then unknown = { trk, id } end
            end
        end
    end
    if attack then return attack, false, false end
    -- DASH GUARD (optional): a force-dash toward you is the first half of dash-kicks and
    -- dash-attacks, so it is also a (early) warning for high-ping players
    if dash and settings.dashGuard then return dash, false, false, true end
    if unknown then
        -- only count it if their saber is actually out (blade parts exist) - filters emotes
        local hasBlade = false
        for _, d in ipairs(char:GetDescendants()) do
            if d.Name == "Core" and d.Parent and string.match(d.Parent.Name, "Blade") then hasBlade = true break end
        end
        if hasBlade then
            if AP.DEBUG and not loggedUnknown[unknown[2]] then
                loggedUnknown[unknown[2]] = true
                logP(char.Name, "Auto Parry: treating unrecognised animation " .. unknown[2] .. " from " .. char.Name .. " as a swing (custom attack pack?)")
            end
            return unknown[1], false, true
        end
    end
    return nil
end

local KEY_W, KEY_E = 0x57, 0x45

local KEY_A, KEY_D = 0x41, 0x44

local STUN_ANIM_IDS = { ["6297531803"] = true, ["6322313635"] = true, ["6322315386"] = true }
local function findStunTrack(char)
    local hum = char:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return nil end
    local ok, tracks = pcall(animator.GetPlayingAnimationTracks, animator)
    if not ok or type(tracks) ~= "table" then return nil end
    for _, trk in ipairs(tracks) do
        local okId, id = pcall(function() return string.match(trk.Animation.AnimationId, "%d+") end)
        if okId and id and STUN_ANIM_IDS[id] then return trk end
    end
    return nil
end

-- "who attacked recently": a small tracker (runs only while Stun evade / Parry chase / Auto Parry is on)
-- remembering the last time each nearby player was seen mid-swing, kick or dash.
local lastAtk = {}
do
    local acc = 0
    track(RunService.Heartbeat:Connect(function(dt)
        acc = acc + dt
        if acc < 0.05 then return end
        acc = 0
        if not settings.perfectTrade then return end
        local me = LocalPlayer.Character
        local mh = me and me:FindFirstChild("HumanoidRootPart")
        if not mh then return end
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local ch = plr.Character
                local h = ch and ch:FindFirstChild("HumanoidRootPart")
                if h and (h.Position - mh.Position).Magnitude <= 60 and findAttackTrack(ch) then
                    lastAtk[plr] = os.clock()
                end
            end
        end
    end))
end

local function movementState()
    local sc = saberComp
    if not saberStillValid(sc) then return nil end
    local ok, st = pcall(function() return rawget(sc, "MovementStateMachine"):GetCurrentState() end)
    return ok and st or nil
end

local function groundedMS(ms) return ms == "idle_m" or ms == "running" end

-- the game's own dash input (what pressing E does) - no OS keyboard latency
local function sendDashInput()
    if saberStillValid(saberComp) then
        pcall(function()
            saberComp:ProcessInput(true, { name = "FORCE_DASH", inputState = Enum.UserInputState.Begin })
        end)
    end
end

local function combatStateNow()
    local sc = saberComp
    if not saberStillValid(sc) then return nil end
    local ok, st = pcall(function() return rawget(sc, "CombatStateMachine"):GetCurrentState() end)
    return ok and st or nil
end

-- While a trade runs, the game is told "block released" (and a swing fires),
-- but your real block button is usually still held. The game only re-blocks by itself from some
-- states, so afterwards you could be left with the saber out and no block. This puts the block
-- back the moment it is possible - but ONLY if you are really still holding your block button.
local function userHoldsBlock()
    local held = false
    pcall(function()
        local sc = saberComp
        local b = sc and rawget(sc, "_pcBlockBinding")
        if b == nil then
            held = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
        elseif typeof(b) == "EnumItem" and b.EnumType == Enum.UserInputType then
            held = UserInputService:IsMouseButtonPressed(b)
        elseif typeof(b) == "EnumItem" then
            held = UserInputService:IsKeyDown(b)
        end
        local gp = sc and rawget(sc, "_gpBlockKey")
        if not held and gp ~= nil then
            held = UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, gp)
        end
    end)
    return held
end
local function reblockIfHeld()
    task.spawn(function()
        local t0 = os.clock()
        while os.clock() - t0 < 1.2 do
            if not userHoldsBlock() then return end          -- you let go: nothing to restore
            local cs = combatStateNow()
            if cs == "blocking" or cs == "parrying" or cs == "stunned" then return end
            if cs == "ignited" then
                pcall(function()
                    saberComp:ProcessInput(true, { name = "BLOCK", inputState = Enum.UserInputState.Begin })
                end)
            end
            RunService.Heartbeat:Wait()                      -- (swinging etc.: wait for the swing to end)
        end
    end)
end

------------------------------------------------------------------------
-- OPPONENT INTEL - the data side (the window and the tags are built with the UI further down)
--   Every other player's animations reach your client, so each move they make is seen the moment
--   its animation starts (AnimationPlayed). Each one is named, counted, and logged with the time
--   and their distance to you. We also remember which move came right AFTER each move (within 3s,
--   i.e. the same exchange) - that's their habit / "what they do next".
--
--   RESOURCES
--     HP ........ their Humanoid (exact).
--     Block ..... the server's "Block" value in their character while they block (exact, 0-140);
--                 when they're not blocking it refills like the game does (2.5s wait, then 14/s).
--     Parries ... ESTIMATE. Only their own computer knows the real number, so: each parry animation
--                 = -1; a parry that stuns someone near them gives 1 back (the game's SUCCESS_RETURN);
--                 the game's refill: +1 every 5s after a parry, skipped while blocking. Max 5.
--     Kicks ..... ESTIMATE. Each kick = -1. The game refills kicks only while they block (or have
--                 the saber away): 1s after that starts, then +1 every 2s as long as they stay
--                 that way. Max 3.
--     Respawn = everything back to full.
------------------------------------------------------------------------
local Intel = { data = {}, MAXP = 5, MAXK = 3, MAXB = 140, target = nil, locked = false }
local DASH_MOVE_IDS = { ["6302511048"] = true, ["6302512079"] = true, ["6382639524"] = true, ["6392682622"] = true }
local THROW_IDS = { ["6584511045"] = true, ["7873070812"] = true }
local FORCE_IDS = {}
for _, id in ipairs({ 72741768067322, 89740527877951, 128004514519482, 108843758967999, 91879086197386, 117020519174436 }) do
    FORCE_IDS[tostring(id)] = true
end

function Intel.get(plr)
    local d = Intel.data[plr]
    if not d then
        d = {
            counts = {}, total = 0, log = {}, after = {}, dist = {},
            parries = Intel.MAXP, pNext = nil,
            kicks = Intel.MAXK, kNext = nil,
            block = Intel.MAXB, blocking = false, blockEnd = 0,
            lastMove = nil, lastMoveT = 0, lastActive = 0,
            pendingDash = nil, parryT = nil, stuns = 0, deaths = 0,
            bladeOut = true, bladeCheck = 0,
            -- combos: the chain being built, every finished chain counted, the last one seen
            chain = {}, chainT = 0, combos = {}, lastCombo = nil, lastComboT = 0,
            -- turning: heading last tick, how far they've turned in one direction, the finished turn
            yaw = nil, turnAcc = 0, turnTok = nil, turnT = 0,
        }
        Intel.data[plr] = d
    end
    return d
end

function Intel.distTo(plr)
    local c = plr.Character
    local h = c and c:FindFirstChild("HumanoidRootPart")
    local me = LocalPlayer.Character
    local mh = me and me:FindFirstChild("HumanoidRootPart")
    if not h or not mh then return nil end
    return (h.Position - mh.Position).Magnitude
end

function Intel.record(plr, move, t)
    local d = Intel.get(plr)
    local now = t or os.clock()
    d.counts[move] = (d.counts[move] or 0) + 1
    d.total += 1
    if d.lastMove and now - d.lastMoveT < 3 then
        local a = d.after[d.lastMove] or {}
        d.after[d.lastMove] = a
        a[move] = (a[move] or 0) + 1
    end
    d.lastMove, d.lastMoveT = move, now
    local dist = Intel.distTo(plr)
    if dist then
        local s = d.dist[move] or { sum = 0, n = 0 }
        d.dist[move] = s
        s.sum += dist
        s.n += 1
    end
    table.insert(d.log, 1, { move = move, t = now, dist = dist })
    if #d.log > 30 then table.remove(d.log) end
    d.lastActive = os.clock()

    -- COMBOS: moves less than 1s apart belong to one chain (a longer gap ends it)
    if #d.chain > 0 and now - d.chainT > Intel.COMBO_GAP then Intel.finishChain(d) end
    -- a quick turn right before this move is part of it ("Slight turn left > Swing")
    local turn = Intel.turnName(d.turnAcc)                 -- still turning as the move starts
    if not turn and d.turnTok and now - d.turnT < 0.6 then turn = d.turnTok end -- turned just before
    if turn then
        d.chain[#d.chain + 1] = turn
        d.turnTok, d.turnAcc = nil, 0
    end
    d.chain[#d.chain + 1] = move
    d.chainT = now
    if #d.chain >= 8 then Intel.finishChain(d) end         -- very long strings: cut into pieces
end

Intel.COMBO_GAP = 1.0 -- s between moves that still counts as the same combo
-- how far they turned (degrees, + = left) -> a name, or nil if it's too small to matter
function Intel.turnName(acc)
    local a = math.abs(acc or 0)
    if a < 35 then return nil end
    if a >= 150 then return "Turn around" end
    local side = acc > 0 and "left" or "right"
    if a < 90 then return "Slight turn " .. side end
    return "Turn " .. side
end
-- a chain is done: repeats are squeezed ("Multi x3"), and chains of 2+ moves are counted as a combo
function Intel.finishChain(d)
    local chain = d.chain
    d.chain = {}
    local parts, i = {}, 1
    while i <= #chain do
        local j = i
        while j < #chain and chain[j + 1] == chain[i] do j += 1 end
        parts[#parts + 1] = (j > i) and (chain[i] .. " x" .. (j - i + 1)) or chain[i]
        i = j + 1
    end
    -- a combo needs at least two actions (or one repeated), and a turn alone doesn't count
    local actions = 0
    for _, m in ipairs(chain) do if not string.find(m, "[Tt]urn") then actions += 1 end end
    if actions < 2 then return end
    local key = table.concat(parts, " > ")
    d.combos[key] = (d.combos[key] or 0) + 1
    d.lastCombo, d.lastComboT = key, d.chainT
end

-- someone got stunned: a parry from a player near them in the last second worked -> that player gets 1 back
function Intel.parryReturn(stunnedChar, now)
    local sh = stunnedChar:FindFirstChild("HumanoidRootPart")
    if not sh then return end
    for plr, d in pairs(Intel.data) do
        if d.parryT and now - d.parryT < 1.0 and plr.Character ~= stunnedChar then
            local h = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
            if h and (h.Position - sh.Position).Magnitude < 20 then
                d.parries = math.min(Intel.MAXP, d.parries + 1)
                d.parryT = nil
            end
        end
    end
end

function Intel.onAnim(plr, char, trk)
    local ok, id = pcall(function() return string.match(trk.Animation.AnimationId, "%d+") end)
    if not ok or not id then return end
    local now = os.clock()
    if STUN_ANIM_IDS[id] then
        if plr ~= LocalPlayer then
            local d = Intel.get(plr)
            d.stuns += 1
        end
        Intel.parryReturn(char, now)
        return
    end
    if plr == LocalPlayer then return end
    local d = Intel.get(plr)
    if id == KICK_ID then
        local dashed = d.pendingDash and now - d.pendingDash < 0.7
        d.pendingDash = nil
        Intel.record(plr, dashed and "Dash kick" or "Kick")
        d.kicks = math.max(0, d.kicks - 1)
        d.kNext = nil -- kicking ends any refill in progress
    elseif AP.PARRY_ANIM[id] or AP.learnedParry[id] then
        Intel.record(plr, "Parry")
        d.parries = math.max(0, d.parries - 1)
        d.parryT = now
        if not d.pNext then d.pNext = now + 5 end
    elseif ATTACK_IDS[id] then
        local move
        if DASH_ATK_IDS[id] then
            move = "Dash attack"
        elseif d.pendingDash and now - d.pendingDash < 0.45 then
            move = "Multi"
        else
            move = "Swing"
        end
        d.pendingDash = nil
        Intel.record(plr, move)
    elseif DASH_MOVE_IDS[id] then
        -- a dash is only logged as "Dash" if no swing / kick comes out of it (else it was a multi / dash kick)
        d.pendingDash = now
        task.delay(0.75, function()
            if d.pendingDash == now then
                d.pendingDash = nil
                Intel.record(plr, "Dash", now)
            end
        end)
    elseif FLIP_IDS[id] then
        Intel.record(plr, "Flip / roll")
    elseif THROW_IDS[id] then
        Intel.record(plr, "Saber throw")
    elseif FORCE_IDS[id] then
        Intel.record(plr, "Force power")
    end
end

-- hook every player's animator (and their Block value); re-hooked on every respawn
do
    local function hookChar(plr, char)
        task.spawn(function()
            local hum = char:WaitForChild("Humanoid", 10)
            local animator = hum and hum:WaitForChild("Animator", 10)
            if not animator then return end
            if plr ~= LocalPlayer then
                local d = Intel.get(plr)
                -- respawned: everything back to full
                d.parries, d.kicks, d.block = Intel.MAXP, Intel.MAXK, Intel.MAXB
                d.pNext, d.kNext, d.blocking, d.pendingDash = nil, nil, false, nil
                track(hum.Died:Connect(function() d.deaths += 1 end))
                local function blockOn(v)
                    if not (v.Name == "Block" and v:IsA("NumberValue")) then return end
                    if not d.blocking and os.clock() - d.blockEnd > 0.35 then Intel.record(plr, "Block") end
                    d.blocking = true
                    d.kNext = d.kNext or (os.clock() + 3) -- the game's kick refill: 1s wait + 2s per kick
                end
                for _, v in ipairs(char:GetChildren()) do blockOn(v) end
                track(char.ChildAdded:Connect(blockOn))
                track(char.ChildRemoved:Connect(function(v)
                    if v.Name == "Block" and v:IsA("NumberValue") then
                        d.blocking = false
                        d.blockEnd = os.clock()
                    end
                end))
            end
            -- always counted (even with the window closed), so the numbers are right when you open it
            track(animator.AnimationPlayed:Connect(function(t)
                pcall(Intel.onAnim, plr, char, t)
            end))
        end)
    end
    local function hookPlr(plr)
        if plr.Character then hookChar(plr, plr.Character) end
        track(plr.CharacterAdded:Connect(function(c) hookChar(plr, c) end))
    end
    for _, plr in ipairs(Players:GetPlayers()) do hookPlr(plr) end
    track(Players.PlayerAdded:Connect(hookPlr))
    track(Players.PlayerRemoving:Connect(function(plr)
        Intel.data[plr] = nil
        if Intel.target == plr then Intel.target, Intel.locked = nil, false end
    end))
end

-- refills + live block value, 10 times a second
do
    local acc = 0
    track(RunService.Heartbeat:Connect(function(dt)
        acc += dt
        if acc < 0.1 then return end
        local step = acc
        acc = 0
        local now = os.clock()
        for plr, d in pairs(Intel.data) do
            local char = plr.Character
            if char then
                -- block meter: exact while blocking, refilled like the game when not
                local bv = char:FindFirstChild("Block")
                if bv and bv:IsA("NumberValue") then
                    d.block = math.clamp(bv.Value, 0, Intel.MAXB)
                elseif now - d.blockEnd > 2.5 then
                    d.block = math.min(Intel.MAXB, d.block + 14 * step)
                end
                -- TURNS: follow the way they face. One turn = rotating the same way without stopping;
                -- when they stop (or turn back) the turn is finished and kept for 0.6s - if a move comes
                -- in that time, the turn goes into the combo in front of it
                local hrp = char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local lv = hrp.CFrame.LookVector
                    local yaw = math.deg(math.atan2(-lv.X, -lv.Z)) -- + = turned left
                    if d.yaw then
                        local delta = (yaw - d.yaw + 180) % 360 - 180
                        if math.abs(delta) < 3 or (d.turnAcc ~= 0 and (delta > 0) ~= (d.turnAcc > 0)) then
                            local nm = Intel.turnName(d.turnAcc)
                            if nm then d.turnTok, d.turnT = nm, now end
                            d.turnAcc = (math.abs(delta) < 3) and 0 or delta
                        else
                            d.turnAcc += delta
                        end
                    end
                    d.yaw = yaw
                end
                -- a combo ends when they stop for over a second
                if #d.chain > 0 and now - d.chainT > Intel.COMBO_GAP then Intel.finishChain(d) end
                -- is their saber out? (blade parts) - checked twice a second
                if now - d.bladeCheck > 0.5 then
                    d.bladeCheck = now
                    local out = false
                    for _, x in ipairs(char:GetDescendants()) do
                        if x.Name == "Core" and x.Parent and string.match(x.Parent.Name, "Blade") then out = true break end
                    end
                    if d.bladeOut and not out then d.kNext = d.kNext or (now + 3) end -- saber away = kick refill starts
                    d.bladeOut = out
                end
                -- parries: +1 every 5s after a parry, skipped while blocking
                if d.pNext and now >= d.pNext then
                    if not d.blocking then d.parries = math.min(Intel.MAXP, d.parries + 1) end
                    d.pNext = (d.parries < Intel.MAXP) and (d.pNext + 5) or nil
                end
                -- kicks: +1 every 2s, only while blocking / saber away (the refill stops otherwise)
                if d.kNext and now >= d.kNext then
                    if d.kicks >= Intel.MAXK then
                        d.kNext = nil
                    elseif d.blocking or not d.bladeOut then
                        d.kicks += 1
                        d.kNext = (d.kicks < Intel.MAXK) and (d.kNext + 2) or nil
                    else
                        d.kNext = nil
                    end
                end
            end
        end
    end))
end

-- who to show: a locked player, else the enemy fighting you (closest recent move within 25 studs),
-- else the nearest enemy in range
function Intel.pickTarget()
    if Intel.locked and Intel.target and Intel.target.Parent then return Intel.target end
    Intel.locked = false
    local now = os.clock()
    local best, bestScore
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and not (settings.intelTeamCheck and sameTeam(plr)) then
            local dist = Intel.distTo(plr)
            local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
            if dist and dist <= settings.intelRange and hum and hum.Health > 0 then
                local d = Intel.data[plr]
                local recent = d and (now - d.lastActive) < 6 and dist <= 25
                local score = (recent and 0 or 1000) + dist
                if not best or score < bestScore then best, bestScore = plr, score end
            end
        end
    end
    Intel.target = best
    return best
end

-- every enemy in range, nearest first (used by the < > buttons)
function Intel.candidates()
    local list = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and not (settings.intelTeamCheck and sameTeam(plr)) then
            local dist = Intel.distTo(plr)
            if dist and dist <= settings.intelRange then list[#list + 1] = { plr = plr, dist = dist } end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    local out = {}
    for i, e in ipairs(list) do out[i] = e.plr end
    return out
end

------------------------------------------------------------------------
-- PERFECT TRADE (v75): you're blocking, an opponent's swing LANDS on your block - and the moment it does,
-- you let go of block and answer with ONE multi (W + A + E dash cancelled into a swing) straight at them,
-- then your block goes back up if you're still holding it. That's a trade: you took their hit on your
-- block and gave one back while they're still finishing their swing.
--   "Their swing landed on your block" is read from YOUR side, two ways (whichever comes first):
--     * your block-hit reaction animation starts (the game plays it on every blocked hit)
--     * your "Block" value drops (the server lowers it on every blocked hit)
--   The attacker = whoever close to you is mid-swing / just swung and is facing you.
--   Kicks are ignored. With "Trade only" players ticked, only they are traded with; Trade team check skips teammates.
--   NATURAL mode (default): not every hit is traded (Trade chance), the trade waits a random human reaction
--   time and re-checks you're still blocking and they're still there, long streaks get unlikely, and some
--   trades are a plain swing instead of a multi. No instant snap-turn either: you turn by moving.
------------------------------------------------------------------------
do
    local RESP = {} -- the block-hit reaction animations (fixed for every form)
    for _, id in ipairs({ 6312280575, 6312281206, 6312281779, 6312282511, 6669641262, 7101397703, 6736233297,
        7101402353, 6861038808, 6861088961, 6860799757, 7101356513, 6753361279, 6860759883, 10443668308 }) do
        RESP[tostring(id)] = true
    end
    local tradeBusy, lastTrade = false, 0
    local blockSince, wasBlocking = math.huge, false
    local lastBlockObj, lastBlockVal

    local function flatV(v) return Vector3.new(v.X, 0, v.Z) end

    local function pickAttacker(mh)
        local best, bestScore
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and tradePicked(plr) and not (settings.tradeTeamCheck and sameTeam(plr)) then
                local ch = plr.Character
                local h = ch and ch:FindFirstChild("HumanoidRootPart")
                local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                if h and hum and hum.Health > 0 then
                    local toMe = flatV(mh.Position - h.Position)
                    local d = toMe.Magnitude
                    if d <= 16 then
                        local swinging = findAttackTrack(ch) ~= nil
                        local la = lastAtk[plr]
                        local recent = la ~= nil and os.clock() - la < 0.7
                        if swinging or recent then
                            local lf = flatV(h.CFrame.LookVector)
                            local face = (d > 0.01 and lf.Magnitude > 0.01) and lf.Unit:Dot(toMe.Unit) or 1
                            if d <= 6 or face >= 0.2 then
                                local score = d - (swinging and 5 or 0) - face * 3
                                if not best or score < bestScore then best, bestScore = plr, score end
                            end
                        end
                    end
                end
            end
        end
        return best
    end

    -- delay = human reaction wait before starting (natural mode), plain = answer with a plain swing (no dash)
    local function doTrade(plr, delay, plain)
        if tradeBusy then return end
        tradeBusy, lastTrade = true, os.clock()
        task.spawn(function()
            if delay and delay > 0 then
                task.wait(delay)
                -- still worth it after "reacting"? you're still blocking and they're still close and alive
                local tc = plr.Character
                local th = tc and tc:FindFirstChild("HumanoidRootPart")
                local thum = tc and tc:FindFirstChildOfClass("Humanoid")
                local mh = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                if not settings.perfectTrade or combatStateNow() ~= "blocking" or not th or not mh or not thum
                    or thum.Health <= 0 or flatV(th.Position - mh.Position).Magnitude > 16 then
                    tradeBusy = false
                    return
                end
            end
            local haveKeys = type(keypress) == "function" and type(keyrelease) == "function"
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local moveDir
            local function aim()
                local tc = plr.Character
                local th = tc and tc:FindFirstChild("HumanoidRootPart")
                local mh = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                if not th or not mh then return nil end
                local to = flatV(th.Position - mh.Position)
                if to.Magnitude > 0.3 then moveDir = to.Unit end
                return th, mh
            end
            local function faceThem()
                local th, mh = aim()
                if th and mh then
                    -- natural: no instant snap-turn unless they're well off to the side (you turn by moving)
                    if settings.tradeNatural then
                        local to = flatV(th.Position - mh.Position)
                        local lf = flatV(mh.CFrame.LookVector)
                        if to.Magnitude > 0.1 and lf.Magnitude > 0.1 and lf.Unit:Dot(to.Unit) > 0.5 then return end
                    end
                    pcall(function() mh.CFrame = CFrame.lookAt(mh.Position, Vector3.new(th.Position.X, mh.Position.Y, th.Position.Z)) end)
                end
            end
            local function unblock()
                pcall(function() saberComp:ProcessInput(true, { name = "BLOCK", inputState = Enum.UserInputState.End }) end)
            end
            local function swing()
                pcall(function() saberComp:ProcessInput(true, { name = "ATTACK", inputState = Enum.UserInputState.Begin }) end)
            end
            local okT, errT = pcall(function()
                aim()
                pcall(function()
                    RunService:BindToRenderStep("CompIntel_TradeMove", Enum.RenderPriority.Last.Value, function()
                        if hum and moveDir then hum:Move(moveDir, false) end
                    end)
                end)
                if haveKeys and not plain then pcall(keypress, KEY_W); pcall(keypress, KEY_A) end
                -- 1) let go of block
                unblock()
                -- (v76) the dash needs W to really be down; the OS key press usually lands by the next
                -- frame, so wait exactly that one frame instead of burning a refused dash first
                if haveKeys and not plain and not UserInputService:IsKeyDown(Enum.KeyCode.W) then RunService.RenderStepped:Wait() end
                -- 2) the dash: asked for again every frame until the game takes it (W has to register first)
                local force = 0
                pcall(function() force = rawget(rawget(saberComp, "CharacterComponent"), "Force") or 0 end)
                local dashed = false
                if haveKeys and force >= 40 and not plain then
                    local tD = os.clock()
                    while os.clock() - tD < 0.25 do
                        aim()
                        local cs = combatStateNow()
                        if cs == "blocking" then unblock() end
                        local onCd = false
                        pcall(function() onCd = rawget(saberComp, "Cooldowns"):OnCooldown("dash") end)
                        if (cs == "ignited" or cs == "blocking") and not onCd and groundedMS(movementState()) then
                            faceThem()
                            sendDashInput()
                            -- (v76) the game switches state instantly: check RIGHT AWAY instead of a frame later
                            if movementState() == "dashing" then dashed = true break end
                        end
                        RunService.RenderStepped:Wait()
                        if movementState() == "dashing" then dashed = true break end
                    end
                end
                -- 3) ...cancelled into the swing at once (or a plain swing if a dash wasn't possible)
                if dashed then
                    pcall(function() rawget(saberComp, "_janitor"):Remove("DashCancelInputBegan") end)
                end
                local tC = os.clock()
                while os.clock() - tC < 0.15 and combatStateNow() ~= "ignited" do
                    if combatStateNow() == "blocking" then unblock() end
                    RunService.RenderStepped:Wait()
                end
                faceThem()
                local h = dashed and saberStillValid(saberComp) and rawget(saberComp, "_dashCancelHandler")
                if type(h) == "function" then pcall(h, true) else swing() end
                -- keep steering just long enough for the swing to go out, then hand back (and re-block)
                RunService.RenderStepped:Wait()
                aim()
                RunService.RenderStepped:Wait()
            end)
            if not okT then warn("[CompIntel] perfect trade error: " .. tostring(errT)) end
            pcall(function() RunService:UnbindFromRenderStep("CompIntel_TradeMove") end)
            if haveKeys then pcall(keyrelease, KEY_W); pcall(keyrelease, KEY_A) end
            tradeBusy = false
            reblockIfHeld() -- block back up (only if you're still holding it)
        end)
    end

    local streak, lastDecision = 0, 0
    local function tryTrade()
        if not settings.perfectTrade or tradeBusy then return end
        -- built for multi spam on your block: a new trade can follow 0.15s after the last one, and a hit
        -- 0.04s after your block went back up already counts (only the block pose itself at block start doesn't)
        if os.clock() - lastTrade < 0.15 then return end
        if not wasBlocking or os.clock() - blockSince < 0.04 then return end
        local char = LocalPlayer.Character
        local mh = char and char:FindFirstChild("HumanoidRootPart")
        if not mh then return end
        local plr = pickAttacker(mh)
        if not plr then return end
        local trk, isKick = findAttackTrack(plr.Character)
        if trk and isKick then return end -- kicks are not traded
        if not settings.tradeNatural then
            doTrade(plr, 0, false)
            return
        end
        -- NATURAL: one decision per blocked hit (each hit fires two triggers - the 2nd must not re-roll)
        local now = os.clock()
        if now - lastDecision < 0.12 then return end
        lastDecision = now
        -- a long pause since the last trade = a new exchange: the streak starts over
        if now - lastTrade > 2.5 then streak = 0 end
        local chance = (settings.tradeChance or 65) / 100
        if streak >= (settings.tradeStreak or 2) then chance = chance * 0.25 end -- rarely keeps going
        if math.random() > chance then
            streak = 0 -- "just kept blocking" this time
            return
        end
        streak += 1
        local react = (settings.tradeReact or 110) / 1000
        local delay = react * (0.6 + math.random() * 0.8) -- 60% .. 140% of the reaction time
        local plain = math.random() * 100 < (settings.tradePlain or 20)
        doTrade(plr, delay, plain)
    end

    -- trigger 1: my block-hit reaction animation starts
    local function hookChar(char)
        task.spawn(function()
            local hum = char:WaitForChild("Humanoid", 10)
            local animator = hum and hum:WaitForChild("Animator", 10)
            if not animator then return end
            track(animator.AnimationPlayed:Connect(function(t)
                if not settings.perfectTrade then return end
                local ok, id = pcall(function() return string.match(t.Animation.AnimationId, "%d+") end)
                if ok and id and RESP[id] then tryTrade() end
            end))
        end)
    end
    if LocalPlayer.Character then hookChar(LocalPlayer.Character) end
    track(LocalPlayer.CharacterAdded:Connect(hookChar))

    -- trigger 2: my Block value drops; plus "how long have I been blocking"
    track(RunService.Heartbeat:Connect(function()
        if not settings.perfectTrade then wasBlocking = false return end
        local blocking = combatStateNow() == "blocking"
        if blocking and not wasBlocking then blockSince = os.clock() end
        if not blocking then blockSince = math.huge end
        wasBlocking = blocking
        local char = LocalPlayer.Character
        local bv = char and char:FindFirstChild("Block")
        if bv and bv:IsA("NumberValue") then
            local v = bv.Value
            if bv == lastBlockObj and lastBlockVal and v < lastBlockVal and blocking then tryTrade() end
            lastBlockObj, lastBlockVal = bv, v
        else
            lastBlockObj, lastBlockVal = nil, nil
        end
    end))
end

------------------------------------------------------------------------
-- KEYBINDS. A bind is plain text: "K", "Ctrl+U", "Ctrl+Shift+F5", "MB3" (middle click) or
-- "MB4" / "MB5" (the mouse SIDE buttons). Modifiers must match exactly, so Ctrl+U does not
-- fire on a plain U. Any toggle can register one with KB.add(getBind, onFire) and get a
-- rebind box in the menu with KB.makeRow(order, label, settingsKey).
-- NOTE: Roblox itself never reports the side buttons, so they are read through the
-- executor's own iskeypressed (virtual-key 0x05 / 0x06) when it has that function.
------------------------------------------------------------------------
local KB = { list = {}, capturing = false, side = { { vk = 0x05, name = "MB4" }, { vk = 0x06, name = "MB5" } } }
function KB.mods()
    local U = UserInputService
    return U:IsKeyDown(Enum.KeyCode.LeftControl) or U:IsKeyDown(Enum.KeyCode.RightControl),
        U:IsKeyDown(Enum.KeyCode.LeftShift) or U:IsKeyDown(Enum.KeyCode.RightShift),
        U:IsKeyDown(Enum.KeyCode.LeftAlt) or U:IsKeyDown(Enum.KeyCode.RightAlt)
end
function KB.prefix()
    local c, s, a = KB.mods()
    return (c and "Ctrl+" or "") .. (s and "Shift+" or "") .. (a and "Alt+" or "")
end
function KB.parse(spec)
    local ctrl, shift, alt, key = false, false, false, nil
    for part in tostring(spec):gmatch("[^+]+") do
        local low = part:lower()
        if low == "ctrl" then ctrl = true elseif low == "shift" then shift = true
        elseif low == "alt" then alt = true else key = part end
    end
    return ctrl, shift, alt, key
end
KB.modKey = {
    LeftControl = "c", RightControl = "c", LeftShift = "s", RightShift = "s", LeftAlt = "a", RightAlt = "a",
}
function KB.match(spec, keyName)
    local c, s, a, key = KB.parse(spec)
    if not key or key ~= keyName then return false end
    local mc, ms, ma = KB.mods()
    -- when the bind itself IS a modifier key (e.g. "RightControl"), that key being held down
    -- is the bind - not an extra modifier
    local own = KB.modKey[keyName]
    if own == "c" then mc = false elseif own == "s" then ms = false elseif own == "a" then ma = false end
    return c == mc and s == ms and a == ma
end
function KB.fire(keyName)
    if KB.capturing then return end
    for _, b in ipairs(KB.list) do
        local spec = b.key()
        if spec and spec ~= "None" and KB.match(spec, keyName) then pcall(b.fire) end
    end
end
function KB.add(getBind, onFire) KB.list[#KB.list + 1] = { key = getBind, fire = onFire } end
function KB.sideDown(vk)
    if type(iskeypressed) ~= "function" then return false end
    local ok, v = pcall(iskeypressed, vk)
    return ok and v == true
end
track(UserInputService.InputBegan:Connect(function(input, processed)
    local ut = input.UserInputType
    if ut == Enum.UserInputType.Keyboard then
        if not processed then KB.fire(input.KeyCode.Name) end
        return
    end
    local name = (ut == Enum.UserInputType.MouseButton1 and "MB1")
        or (ut == Enum.UserInputType.MouseButton2 and "MB2")
        or (ut == Enum.UserInputType.MouseButton3 and "MB3")
    if not name then return end
    -- the game "processes" its own left/right-click controls, so mouse binds can't wait for an
    -- unprocessed click; instead ignore clicks that land on this menu
    for _, f in ipairs({ KB.guiFrame, KB.guideFrame, KB.intelFrame }) do
        if f and f.Visible then
            local ok, inside = pcall(function()
                local m = UserInputService:GetMouseLocation() - game:GetService("GuiService"):GetGuiInset()
                local ap, as = f.AbsolutePosition, f.AbsoluteSize
                return m.X >= ap.X and m.X <= ap.X + as.X and m.Y >= ap.Y and m.Y <= ap.Y + as.Y
            end)
            if ok and inside then return end
        end
    end
    KB.fire(name)
end))
do
    local was = {}
    track(RunService.Heartbeat:Connect(function()
        for _, s in ipairs(KB.side) do
            local down = KB.sideDown(s.vk)
            if down and not was[s.name] then KB.fire(s.name) end
            was[s.name] = down
        end
    end))
end

------------------------------------------------------------------------
-- Self-heal: every 2s re-check that ON features are really applied to your
-- CURRENT character (covers respawns, the game resetting attributes, etc.).
-- Features never depend on the panel being visible.
------------------------------------------------------------------------
track(task.spawn(function()
    while true do
        task.wait(2)
        local char = LocalPlayer.Character
        if char then
            if settings.force and (char:GetAttribute(REGEN_ATTR) ~= REGEN_MULTIPLIER
                or char:GetAttribute(DRAIN_ATTR) ~= -REFILL_PER_TICK or #forceConns == 0) then
                forceApply(char)
            end
            if settings.block and blockMode == "delete" and blockHookedChar ~= char then
                blockDeleteHook(char)
            end
        end
    end
end))

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------
local parentGui = (gethui and gethui()) or game:GetService("CoreGui")
local okParent = pcall(function() local _ = parentGui.Name end)
if not okParent then parentGui = LocalPlayer:WaitForChild("PlayerGui") end
local old = parentGui:FindFirstChild(GUI_NAME)
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local okSet = pcall(function() gui.Parent = parentGui end)
if not okSet then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

-- TOASTS (v81): a little pop-up in the TOP-RIGHT corner whenever a keybind toggles a feature, e.g.
-- "Perfect trade  ON". It shows even while the menu is hidden (Ctrl+H) and fades away after ~2.5s.
do
    local TweenService = game:GetService("TweenService")
    local holder = Instance.new("Frame")
    holder.Name = "Toasts"
    holder.AnchorPoint = Vector2.new(1, 0)
    holder.Position = UDim2.new(1, -16, 0, 16)
    holder.Size = UDim2.fromOffset(260, 0)
    holder.AutomaticSize = Enum.AutomaticSize.Y
    holder.BackgroundTransparency = 1
    holder.ZIndex = 50
    holder.Parent = gui
    local lay = Instance.new("UIListLayout")
    lay.SortOrder = Enum.SortOrder.LayoutOrder
    lay.Padding = UDim.new(0, 6)
    lay.HorizontalAlignment = Enum.HorizontalAlignment.Right
    lay.Parent = holder
    local n = 0
    function AP.toast(name, on)
        pcall(function()
            n += 1
            local box = Instance.new("Frame")
            box.LayoutOrder = n
            box.Size = UDim2.fromOffset(0, 30)
            box.AutomaticSize = Enum.AutomaticSize.X
            box.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
            box.BackgroundTransparency = 1
            box.BorderSizePixel = 0
            box.ZIndex = 50
            box.Parent = holder
            Instance.new("UICorner", box).CornerRadius = UDim.new(0, 8)
            local stroke = Instance.new("UIStroke")
            stroke.Color = on and Color3.fromRGB(60, 170, 90) or Color3.fromRGB(200, 70, 70)
            stroke.Thickness = 1.5
            stroke.Transparency = 1
            stroke.Parent = box
            local pad = Instance.new("UIPadding")
            pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 12), UDim.new(0, 12)
            pad.Parent = box
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.fromScale(0, 1)
            lbl.AutomaticSize = Enum.AutomaticSize.X
            lbl.BackgroundTransparency = 1
            lbl.Font = Enum.Font.GothamBold
            lbl.TextSize = 13
            lbl.RichText = true
            lbl.TextColor3 = Color3.fromRGB(235, 235, 240)
            lbl.TextTransparency = 1
            lbl.Text = ('%s  <font color="%s">%s</font>'):format(name, on and "#4fd27a" or "#e06060", on and "ON" or "OFF")
            lbl.ZIndex = 51
            lbl.Parent = box
            -- keep at most 4 on screen (oldest goes first)
            local kids = {}
            for _, c in ipairs(holder:GetChildren()) do if c:IsA("Frame") then kids[#kids + 1] = c end end
            table.sort(kids, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
            for i = 1, #kids - 4 do kids[i]:Destroy() end
            local fin = TweenInfo.new(0.15)
            TweenService:Create(box, fin, { BackgroundTransparency = 0.1 }):Play()
            TweenService:Create(stroke, fin, { Transparency = 0 }):Play()
            TweenService:Create(lbl, fin, { TextTransparency = 0 }):Play()
            task.delay(2.5, function()
                if not box.Parent then return end
                local fout = TweenInfo.new(0.4)
                TweenService:Create(box, fout, { BackgroundTransparency = 1 }):Play()
                TweenService:Create(stroke, fout, { Transparency = 1 }):Play()
                TweenService:Create(lbl, fout, { TextTransparency = 1 }):Play()
                task.wait(0.45)
                if box.Parent then box:Destroy() end
            end)
        end)
    end
end

------------------------------------------------------------------------
-- Intro splash: the Comp Client logo pops in with a pulsing red glow, then fades away.
-- The logo is built into this script (a 512px JPEG as base64). If the executor can't save and
-- load it, a plain "Comp Client" text popup plays instead - so something always appears.
------------------------------------------------------------------------
task.spawn(function()
    local okIntro, errIntro = pcall(function()
        local TweenService = game:GetService("TweenService")
        local ContentProvider = game:GetService("ContentProvider")
        local host = gui and gui.Parent
        if not host then return end
        local oldIntro = host:FindFirstChild("CompIntel_Intro")
        if oldIntro then oldIntro:Destroy() end

        local sg = Instance.new("ScreenGui")
        sg.Name = "CompIntel_Intro"
        sg.IgnoreGuiInset = true
        sg.ResetOnSpawn = false
        sg.DisplayOrder = 1000
        sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        if not pcall(function() sg.Parent = host end) then sg:Destroy() return end

        local SIZE = 300
        local RED = Color3.fromRGB(255, 35, 35)

        -- red glow: two soft circles behind the logo that breathe in and out
        local glow = Instance.new("Frame")
        glow.AnchorPoint = Vector2.new(0.5, 0.5)
        glow.Position = UDim2.fromScale(0.5, 0.5)
        glow.Size = UDim2.fromOffset(0, 0)
        glow.BackgroundColor3 = RED
        glow.BackgroundTransparency = 1
        glow.BorderSizePixel = 0
        glow.ZIndex = 1
        glow.Parent = sg
        Instance.new("UICorner", glow).CornerRadius = UDim.new(1, 0)
        local glow2 = glow:Clone()
        glow2.BackgroundColor3 = Color3.fromRGB(255, 90, 90)
        glow2.Parent = sg

        -- the logo (hidden until it has loaded)
        local img = Instance.new("ImageLabel")
        img.AnchorPoint = Vector2.new(0.5, 0.5)
        img.Position = UDim2.fromScale(0.5, 0.5)
        img.Size = UDim2.fromOffset(0, 0)
        img.BackgroundTransparency = 1
        img.Image = ""
        img.ImageTransparency = 1
        img.ScaleType = Enum.ScaleType.Fit
        img.ZIndex = 5
        img.Visible = false
        img.Parent = sg
        Instance.new("UICorner", img).CornerRadius = UDim.new(0.07, 0)
        local imgStroke = Instance.new("UIStroke")
        imgStroke.Color = RED
        imgStroke.Thickness = 3
        imgStroke.Transparency = 1
        imgStroke.Parent = img

        -- the text popup (only shown if the logo can't be loaded)
        local txt = Instance.new("TextLabel")
        txt.AnchorPoint = Vector2.new(0.5, 0.5)
        txt.Position = UDim2.fromScale(0.5, 0.5)
        txt.Size = UDim2.fromOffset(900, 140)
        txt.BackgroundTransparency = 1
        txt.Font = Enum.Font.GothamBlack
        txt.Text = "Comp Client"
        txt.TextSize = 28
        txt.TextColor3 = Color3.fromRGB(255, 255, 255)
        txt.TextTransparency = 1
        txt.ZIndex = 5
        txt.Visible = false
        txt.Parent = sg
        local txtStroke = Instance.new("UIStroke")
        txtStroke.Color = RED
        txtStroke.Thickness = 2
        txtStroke.Transparency = 1
        txtStroke.Parent = txt

        -- 1) get the logo on screen: decode the built-in picture, save it as a file, load that file
        local function loadLogo()
            if type(writefile) ~= "function" or type(getcustomasset) ~= "function" then return false end
            local LOGO_B64 = [==[
/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAYEBAUEBAYFBQUGBgYHCQ4JCQgICRINDQoOFRIWFhUSFBQXGiEcFxgfGRQUHScdHyIjJSUlFhwpLCgkKyEkJST/
2wBDAQYGBgkICREJCREkGBQYJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCT/wAARCAIAAgADASIAAhEBAxEB/8QA
HwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkK
FhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXG
x8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAEC
AxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOE
hYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD5UooooAKK
KKACiiigAooooAKKKKACiiigAopaKAEopaKAAUtFFAxtFLR2oEJRRRQAUUUUAFFFLigBKKXFHegBKKWjFACUUuKKAEopcUGgBKKKKACiiigAooooAKKKKACl
xSU4UDSEFOAzRtpwpNlqIh4ppp5FNNJDYlJS0VRmFJS0UANop1JQISiiloASlxRzS0DEpKWkoEwooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKAFoF
JTloGhDRinYpMUDsAFGKWilcLCUhpaSmISilxRQISilxRQAUCiigBaTtRS0DEpaKKACiiilcdgpDS0UwsJRS0UCEpKXFBoEJRSig0AJRS4oxQFgpVGaMZp6q
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
YGl6imCnjpSY07jTxRTsCjAouFhuKKdgU0mgQvApC2aQmkzTsJyFJptFFMgKKKKACiiigAoopcUAJTgKMUucUiku4uKUYpmaUdRSLTRLTfWjdRnNIu9xrGm4
pxFAXimZtXG0u2gACpAR9abY4xvuNVasom1NzcUm5EXcBUEkpY5NRqzpXLS1erJ3cHvVd3yabupKajYyqVnIXOaQ0UVVjC4UA4opM0xXsKTSUlFArhSikooA
UmjNJRQO4ppKKKBBRRRQAUUUUAFFFFABRRRQAtLSUtAwoFFLSKQZpDRRQJsKKSimIKM0lFAh1FJS0igooopiFFOzimZozSsVewpajdTc0ZosLmHFuKbmkopi
buLSUUUCCiiigAooooAKKKKAHUCiikUgJpM0GkpiY6gHFFFIaDNKtJil6UDQpNJSZozQNsM0A80UUWJuOLZGKbmikosNu4tFJmjNMkWkopKBC5pKKKACiiig
AooooAKKKKACiiigAooooAKKKKACiiigAooooAdRRRSYxRSGiigphRSZozTJA0lFFAgpaSigBc0tNp1Awoo6UGkOwUhopKZIUUUUAFFFFABRRRQAUUUUAFFF
FABRRRQAoNKDTaUUDTFxRRmkNABmlFJS0AmBooopWGFFJmjNMVw70Zo70UAFFJRQIKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi
iigD/9k=
]==]
            local raw = LOGO_B64:gsub("%s", "")
            local bytes
            pcall(function()
                if crypt and type(crypt.base64decode) == "function" then bytes = crypt.base64decode(raw)
                elseif crypt and crypt.base64 and type(crypt.base64.decode) == "function" then bytes = crypt.base64.decode(raw)
                elseif type(base64_decode) == "function" then bytes = base64_decode(raw)
                elseif base64 and type(base64.decode) == "function" then bytes = base64.decode(raw) end
            end)
            if type(bytes) ~= "string" or #bytes < 1000 or bytes:byte(1) ~= 0xFF then
                -- no usable decoder in this executor: decode it ourselves
                local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
                local lookup = {}
                for i = 1, 64 do lookup[ALPHA:byte(i)] = i - 1 end
                local out, n, buf, bits = {}, 0, 0, 0
                for i = 1, #raw do
                    local v = lookup[raw:byte(i)]
                    if v then
                        buf = buf * 64 + v
                        bits = bits + 6
                        if bits >= 8 then
                            bits = bits - 8
                            n = n + 1
                            out[n] = string.char(math.floor(buf / 2 ^ bits) % 256)
                            buf = buf % 2 ^ bits
                        end
                    end
                end
                bytes = table.concat(out)
            end
            writefile("CompIntel_logo.jpg", bytes)
            local asset = getcustomasset("CompIntel_logo.jpg")
            if not asset then return false end
            img.Image = asset
            pcall(function() ContentProvider:PreloadAsync({ img }) end)
            task.wait(0.3)
            return true
        end
        local okLogo, logoShown = pcall(loadLogo)
        local shown = okLogo and logoShown == true

        -- 2) pop in (logo, or the text popup as the fallback)
        local popInfo = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
        local stroke
        if shown then
            stroke = imgStroke
            img.Visible = true
            TweenService:Create(img, popInfo, { Size = UDim2.fromOffset(SIZE, SIZE), ImageTransparency = 0 }):Play()
            TweenService:Create(imgStroke, TweenInfo.new(0.5), { Transparency = 0.15 }):Play()
        else
            stroke = txtStroke
            txt.Visible = true
            TweenService:Create(txt, popInfo, { TextSize = 78, TextTransparency = 0 }):Play()
            TweenService:Create(txtStroke, TweenInfo.new(0.5), { Transparency = 0 }):Play()
        end

        -- 3) red glow pulse for ~2.2s
        local t0 = os.clock()
        while os.clock() - t0 < 2.2 and sg.Parent do
            local t = os.clock() - t0
            local pulse = (math.sin(t * 6) + 1) / 2                     -- 0..1, about one beat per second
            local grow = math.min(t / 0.5, 1)                           -- glow eases in with the pop
            glow.Size = UDim2.fromOffset((SIZE * 1.25 + pulse * 55) * grow, (SIZE * 1.25 + pulse * 55) * grow)
            glow.BackgroundTransparency = 1 - (0.38 + pulse * 0.17) * grow
            glow2.Size = UDim2.fromOffset((SIZE * 1.05 + pulse * 30) * grow, (SIZE * 1.05 + pulse * 30) * grow)
            glow2.BackgroundTransparency = 1 - (0.22 + (1 - pulse) * 0.14) * grow
            stroke.Thickness = 2 + pulse * 6
            RunService.RenderStepped:Wait()
        end

        -- 4) fade away
        local fade = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        if shown then
            TweenService:Create(img, fade, { ImageTransparency = 1, Size = UDim2.fromOffset(SIZE * 1.12, SIZE * 1.12) }):Play()
        else
            TweenService:Create(txt, fade, { TextTransparency = 1, TextSize = 90 }):Play()
        end
        TweenService:Create(stroke, fade, { Transparency = 1 }):Play()
        TweenService:Create(glow, fade, { BackgroundTransparency = 1 }):Play()
        TweenService:Create(glow2, fade, { BackgroundTransparency = 1 }):Play()
        task.wait(0.8)
        sg:Destroy()
    end)
    if not okIntro then warn("[CompIntel] intro splash failed: " .. tostring(errIntro)) end
end)
local COLORS = {
    bg = Color3.fromRGB(24, 24, 28), panel = Color3.fromRGB(34, 34, 40),
    text = Color3.fromRGB(235, 235, 240), sub = Color3.fromRGB(150, 150, 160),
    on = Color3.fromRGB(60, 170, 90), off = Color3.fromRGB(90, 90, 100),
}

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(210, 320) -- compact; the rows scroll (mouse wheel)
frame.Position = UDim2.new(0, 20, 0.5, -160)
frame.BackgroundColor3 = COLORS.bg
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui
KB.guiFrame = frame
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -16, 0, 26)
title.Position = UDim2.fromOffset(8, 2)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = COLORS.text
title.Text = "Comp Client"
title.Parent = frame

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -16, 0, 26)
hint.Position = UDim2.fromOffset(8, 2)
hint.BackgroundTransparency = 1
hint.Font = Enum.Font.Gotham
hint.TextSize = 10
hint.TextXAlignment = Enum.TextXAlignment.Right
hint.TextColor3 = COLORS.sub
hint.Text = "Ctrl+H = hide  |  Intel v2"
hint.Parent = frame

-- everything below the title lives in `content`, which stays hidden until the
-- password is entered
-- a scrolling list: mouse wheel (or drag the thin bar) to scroll; rows stack in the order
-- they're created (the first number given to makeRow/makeSwitch is just the sort order)
local content = Instance.new("ScrollingFrame")
content.Size = UDim2.new(1, 0, 1, -30)
content.Position = UDim2.fromOffset(0, 30)
content.BackgroundTransparency = 1
content.BorderSizePixel = 0
content.ScrollBarThickness = 4
content.ScrollBarImageColor3 = COLORS.sub
content.ScrollingDirection = Enum.ScrollingDirection.Y
content.CanvasSize = UDim2.new(0, 0, 0, 0)
content.AutomaticCanvasSize = Enum.AutomaticSize.Y
content.Visible = false
content.Parent = frame
do
    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 4)
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.Parent = content
    local pad = Instance.new("UIPadding")
    pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 2), UDim.new(0, 8)
    pad.Parent = content
end

local function makeRow(y, labelText)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -16, 0, 26)
    row.LayoutOrder = y
    row.BackgroundColor3 = COLORS.panel
    row.BorderSizePixel = 0
    row.Parent = content
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -70, 1, 0)
    label.Position = UDim2.fromOffset(8, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Gotham
    label.TextSize = 11
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextColor3 = COLORS.text
    label.Text = labelText
    label.Parent = row
    return row
end

-- everything the config system needs to push saved values back into the menu: key -> setter / refresher
local CFG_UI = { sw = {}, num = {}, kb = {}, wl = {} }

-- `key` (optional) = the settings entry this switch controls, so saved configs can flip it
local function makeSwitch(y, labelText, initial, onChanged, key)
    local row = makeRow(y, labelText)
    local state = initial
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(46, 18)
    btn.Position = UDim2.new(1, -52, 0.5, -9)
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 10
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.AutoButtonColor = true
    btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(1, 0)
    local function render()
        btn.Text = state and "ON" or "OFF"
        btn.BackgroundColor3 = state and COLORS.on or COLORS.off
    end
    btn.MouseButton1Click:Connect(function()
        state = not state
        render()
        onChanged(state)
    end)
    render()
    -- lets other code (e.g. a keybind) flip this switch: setter(on, skipCallback)
    local function setter(on, skipCallback)
        state = on
        render()
        if not skipCallback then onChanged(on) end
    end
    if key then CFG_UI.sw[key] = setter end
    return setter
end

-- section headers: Resources / Combat / HBE (the number is the position in the list)
local function makeHeader(order, text)
    local h = Instance.new("TextLabel")
    h.Size = UDim2.new(1, -16, 0, 18)
    h.LayoutOrder = order
    h.BackgroundTransparency = 1
    h.Font = Enum.Font.GothamBold
    h.TextSize = 11
    h.TextColor3 = COLORS.on
    h.TextXAlignment = Enum.TextXAlignment.Left
    h.Text = text
    h.Parent = content
    -- thin line under the title
    local line = Instance.new("Frame")
    line.Size = UDim2.new(1, 0, 0, 1)
    line.Position = UDim2.new(0, 0, 1, -1)
    line.BackgroundColor3 = COLORS.off
    line.BorderSizePixel = 0
    line.Parent = h
end
-- WHITELIST drop-down: a header row "Whitelist (n) v"; click it to open a search box and the
-- list of everyone in the server. Tick a name = that feature skips them. Stored by UserId.
local function makeWhitelist(order, labelText, listName, btnWord)
    local wl = settings.whitelist[listName]
    local container = Instance.new("Frame")
    container.Size = UDim2.new(1, -16, 0, 26)
    container.AutomaticSize = Enum.AutomaticSize.Y
    container.LayoutOrder = order
    container.BackgroundTransparency = 1
    container.BorderSizePixel = 0
    container.Parent = content
    local lay = Instance.new("UIListLayout")
    lay.SortOrder = Enum.SortOrder.LayoutOrder
    lay.Padding = UDim.new(0, 2)
    lay.Parent = container

    local head = Instance.new("Frame")
    head.Size = UDim2.new(1, 0, 0, 26)
    head.LayoutOrder = 1
    head.BackgroundColor3 = COLORS.panel
    head.BorderSizePixel = 0
    head.Parent = container
    Instance.new("UICorner", head).CornerRadius = UDim.new(0, 6)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -92, 1, 0)
    lbl.Position = UDim2.fromOffset(8, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 11
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextColor3 = COLORS.text
    lbl.TextTruncate = Enum.TextTruncate.AtEnd
    lbl.Text = labelText
    lbl.Parent = head
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(78, 18)
    btn.Position = UDim2.new(1, -84, 0.5, -9)
    btn.BackgroundColor3 = COLORS.bg
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 9
    btn.TextColor3 = COLORS.text
    btn.AutoButtonColor = true
    btn.Parent = head
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

    local panel = Instance.new("Frame")
    panel.Size = UDim2.new(1, 0, 0, 150)
    panel.LayoutOrder = 2
    panel.BackgroundColor3 = COLORS.panel
    panel.BorderSizePixel = 0
    panel.Visible = false
    panel.Parent = container
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 6)
    local search = Instance.new("TextBox")
    search.Size = UDim2.new(1, -10, 0, 22)
    search.Position = UDim2.fromOffset(5, 4)
    search.BackgroundColor3 = COLORS.bg
    search.BorderSizePixel = 0
    search.Font = Enum.Font.Gotham
    search.TextSize = 11
    search.TextColor3 = COLORS.text
    search.PlaceholderText = "search players..."
    search.PlaceholderColor3 = COLORS.sub
    search.Text = ""
    search.ClearTextOnFocus = false
    search.Parent = panel
    Instance.new("UICorner", search).CornerRadius = UDim.new(0, 5)
    local list = Instance.new("ScrollingFrame")
    list.Size = UDim2.new(1, -10, 1, -34)
    list.Position = UDim2.fromOffset(5, 30)
    list.BackgroundTransparency = 1
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 3
    list.CanvasSize = UDim2.new(0, 0, 0, 0)
    list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    list.Parent = panel
    local ll = Instance.new("UIListLayout")
    ll.SortOrder = Enum.SortOrder.LayoutOrder
    ll.Padding = UDim.new(0, 2)
    ll.Parent = list

    local function count()
        local n = 0
        for _ in pairs(wl) do n += 1 end
        btn.Text = ("%s (%d) %s"):format(btnWord or "Whitelist", n, panel.Visible and "^" or "v")
    end
    local function rebuild()
        for _, c in ipairs(list:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        local q = search.Text:lower()
        local players = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then players[#players + 1] = plr end
        end
        table.sort(players, function(a, b) return a.Name:lower() < b.Name:lower() end)
        for i, plr in ipairs(players) do
            local nm = plr.DisplayName ~= "" and plr.DisplayName or plr.Name
            if q == "" or plr.Name:lower():find(q, 1, true) or nm:lower():find(q, 1, true) then
                local on = wl[plr.UserId] == true
                local b = Instance.new("TextButton")
                b.Size = UDim2.new(1, -4, 0, 20)
                b.LayoutOrder = i
                b.BackgroundColor3 = on and COLORS.on or COLORS.bg
                b.BackgroundTransparency = on and 0.35 or 0
                b.BorderSizePixel = 0
                b.Font = Enum.Font.Gotham
                b.TextSize = 11
                b.TextColor3 = COLORS.text
                b.TextXAlignment = Enum.TextXAlignment.Left
                b.TextTruncate = Enum.TextTruncate.AtEnd
                b.Text = ("  %s %s%s"):format(on and "[x]" or "[ ]", nm, nm ~= plr.Name and (" (@" .. plr.Name .. ")") or "")
                b.Parent = list
                b.MouseButton1Click:Connect(function()
                    if wl[plr.UserId] then wl[plr.UserId] = nil else wl[plr.UserId] = true end
                    count()
                    rebuild()
                end)
            end
        end
    end
    btn.MouseButton1Click:Connect(function()
        panel.Visible = not panel.Visible
        if panel.Visible then rebuild() end
        count()
    end)
    search:GetPropertyChangedSignal("Text"):Connect(function() if panel.Visible then rebuild() end end)
    track(Players.PlayerAdded:Connect(function() if panel.Visible then rebuild() end end))
    track(Players.PlayerRemoving:Connect(function() task.defer(function() if panel.Visible then rebuild() end end) end))
    CFG_UI.wl[listName] = function() count(); if panel.Visible then rebuild() end end
    count()
end

-- keybind row: click the box, then press the key / combo (Ctrl+U ...) / middle click / mouse
-- side button you want. Esc cancels, Backspace/Delete clears it ("None").
function KB.makeRow(order, labelText, settingKey)
    local row = makeRow(order, labelText)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(78, 18)
    btn.Position = UDim2.new(1, -84, 0.5, -9)
    btn.BackgroundColor3 = COLORS.bg
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 9
    btn.TextColor3 = COLORS.text
    btn.TextTruncate = Enum.TextTruncate.AtEnd
    btn.Text = tostring(settings[settingKey])
    btn.AutoButtonColor = true
    btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    CFG_UI.kb[settingKey] = function() btn.Text = tostring(settings[settingKey]) end

    local MOD_NAMES = {
        [Enum.KeyCode.LeftControl] = true, [Enum.KeyCode.RightControl] = true,
        [Enum.KeyCode.LeftShift] = true, [Enum.KeyCode.RightShift] = true,
        [Enum.KeyCode.LeftAlt] = true, [Enum.KeyCode.RightAlt] = true,
    }
    local MOUSE = {
        [Enum.UserInputType.MouseButton1] = "MB1",
        [Enum.UserInputType.MouseButton2] = "MB2",
        [Enum.UserInputType.MouseButton3] = "MB3",
    }
    local listening = false
    btn.MouseButton1Click:Connect(function()
        if listening then return end
        listening = true
        KB.capturing = true
        btn.Text = (type(iskeypressed) == "function") and "press..." or "press (no MB4/5)"
        local done = false
        local conns = {}
        local function stop(spec)
            if done then return end
            done = true
            listening = false
            for _, c in ipairs(conns) do c:Disconnect() end
            if spec then settings[settingKey] = spec end
            btn.Text = tostring(settings[settingKey])
            task.defer(function() KB.capturing = false end) -- after the toggle listener has seen this same press
        end
        local pendingMod, usedWithMod = nil, false
        conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input)
            local ut = input.UserInputType
            if ut == Enum.UserInputType.Keyboard then
                local kc = input.KeyCode
                if MOD_NAMES[kc] then pendingMod = kc return end   -- might be a combo, might be the bind itself
                if kc == Enum.KeyCode.Escape then stop(nil) return end
                if kc == Enum.KeyCode.Backspace or kc == Enum.KeyCode.Delete then stop("None") return end
                stop(KB.prefix() .. kc.Name)                       -- e.g. Ctrl+U
            elseif MOUSE[ut] then
                stop(KB.prefix() .. MOUSE[ut])                     -- left / right / middle click, also with Ctrl+...
            end
        end)
        -- a modifier pressed and released with nothing else = that modifier IS the bind (Right Ctrl etc.)
        conns[#conns + 1] = UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Keyboard and pendingMod and input.KeyCode == pendingMod then
                stop(pendingMod.Name)
            end
        end)
        for _, c in ipairs(conns) do track(c) end
        -- the side buttons only exist through the executor, so poll them while listening
        task.spawn(function()
            local was = {}
            for _, s in ipairs(KB.side) do was[s.name] = KB.sideDown(s.vk) end
            while not done do
                for _, s in ipairs(KB.side) do
                    local down = KB.sideDown(s.vk)
                    if down and not was[s.name] then stop(KB.prefix() .. s.name) end
                    was[s.name] = down
                end
                RunService.Heartbeat:Wait()
            end
        end)
    end)
end

-- number boxes (type a value, press Enter or click away)
local function makeNumberBox(y, labelText, key, minV, maxV)
    local row = makeRow(y, labelText)
    local box = Instance.new("TextBox")
    box.Size = UDim2.fromOffset(46, 18)
    box.Position = UDim2.new(1, -52, 0.5, -9)
    box.BackgroundColor3 = COLORS.bg
    box.BorderSizePixel = 0
    box.Font = Enum.Font.GothamBold
    box.TextSize = 10
    box.TextColor3 = COLORS.text
    box.Text = tostring(settings[key])
    box.ClearTextOnFocus = false
    box.Parent = row
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)
    box.FocusLost:Connect(function()
        local n = tonumber(box.Text)
        if n then settings[key] = math.clamp(n, minV, maxV) end
        box.Text = tostring(settings[key])
    end)
    CFG_UI.num[key] = { min = minV, max = maxV, refresh = function() box.Text = tostring(settings[key]) end }
end

------------------------------------------------------------------------
-- OPPONENT INTEL - the window + the over-head resource tags
------------------------------------------------------------------------
local function hexOf(c) return string.format("#%02x%02x%02x", math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255)) end
local function esc(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function pips(n, max, color)
    local s = ""
    for i = 1, max do s = s .. (i <= n and ('<font color="' .. color .. '">●</font>') or '<font color="#55555f">●</font>') end
    return s
end
local function hpColor(f)
    if f > 0.6 then return "#4fd27a" elseif f > 0.3 then return "#e6c84f" end
    return "#e06060"
end

do
    local win = Instance.new("Frame")
    win.Name = "Intel"
    win.Size = UDim2.fromOffset(250, 340)
    win.Position = UDim2.new(1, -270, 0.5, -170)
    win.BackgroundColor3 = COLORS.bg
    win.BorderSizePixel = 0
    win.Active = true
    win.Visible = false
    win.Parent = gui
    Instance.new("UICorner", win).CornerRadius = UDim.new(0, 8)
    KB.intelFrame = win

    local head = Instance.new("TextLabel")
    head.Size = UDim2.new(1, -16, 0, 24)
    head.Position = UDim2.fromOffset(8, 2)
    head.BackgroundTransparency = 1
    head.Font = Enum.Font.GothamBold
    head.TextSize = 13
    head.TextXAlignment = Enum.TextXAlignment.Left
    head.TextColor3 = COLORS.text
    head.Text = "Opponent Intel"
    head.Parent = win

    -- buttons: < > (switch target), Lock, Reset
    local function smallBtn(text, x, w)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(w, 18)
        b.Position = UDim2.new(1, x, 0, 5)
        b.BackgroundColor3 = COLORS.panel
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamBold
        b.TextSize = 10
        b.TextColor3 = COLORS.text
        b.Text = text
        b.AutoButtonColor = true
        b.Parent = win
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
        return b
    end
    local bPrev = smallBtn("<", -142, 20)
    local bNext = smallBtn(">", -120, 20)
    local bLock = smallBtn("Lock", -96, 42)
    local bReset = smallBtn("Reset", -50, 42)

    local body = Instance.new("ScrollingFrame")
    body.Size = UDim2.new(1, -8, 1, -32)
    body.Position = UDim2.fromOffset(4, 28)
    body.BackgroundTransparency = 1
    body.BorderSizePixel = 0
    body.ScrollBarThickness = 3
    body.ScrollBarImageColor3 = COLORS.sub
    body.CanvasSize = UDim2.new(0, 0, 0, 0)
    body.AutomaticCanvasSize = Enum.AutomaticSize.Y
    body.Parent = win
    local txt = Instance.new("TextLabel")
    txt.Size = UDim2.new(1, -10, 0, 0)
    txt.Position = UDim2.fromOffset(4, 0)
    txt.AutomaticSize = Enum.AutomaticSize.Y
    txt.BackgroundTransparency = 1
    txt.Font = Enum.Font.Gotham
    txt.TextSize = 11
    txt.TextWrapped = true
    txt.RichText = true
    txt.TextXAlignment = Enum.TextXAlignment.Left
    txt.TextYAlignment = Enum.TextYAlignment.Top
    txt.TextColor3 = COLORS.text
    txt.Text = ""
    txt.Parent = body

    local function cycle(dir)
        local list = Intel.candidates()
        if #list == 0 then return end
        local idx = 0
        for i, p in ipairs(list) do if p == Intel.target then idx = i end end
        idx = ((idx - 1 + dir) % #list) + 1
        Intel.target, Intel.locked = list[idx], true
    end
    bPrev.MouseButton1Click:Connect(function() cycle(-1) end)
    bNext.MouseButton1Click:Connect(function() cycle(1) end)
    bLock.MouseButton1Click:Connect(function()
        if Intel.locked then Intel.locked = false else Intel.locked = Intel.target ~= nil end
    end)
    local resetArmed = 0
    bReset.MouseButton1Click:Connect(function()
        -- two clicks within 2s: forget every player's move stats (resources stay)
        if os.clock() - resetArmed < 2 then
            for _, d in pairs(Intel.data) do
                d.counts, d.total, d.log, d.after, d.dist, d.stuns = {}, 0, {}, {}, {}, 0
                d.chain, d.combos, d.lastCombo = {}, {}, nil
            end
            resetArmed = 0
            bReset.Text = "Reset"
        else
            resetArmed = os.clock()
            bReset.Text = "Sure?"
            task.delay(2, function() if bReset.Text == "Sure?" then bReset.Text = "Reset" end end)
        end
    end)

    local function render()
        local plr = Intel.pickTarget()
        bLock.Text = Intel.locked and "Auto" or "Lock"
        if not plr then
            txt.Text = '<font color="#96969f">No opponent in range.\n\nGet within ' .. settings.intelRange
                .. ' studs of someone (or raise "Intel range").\nThe one fighting you is picked by itself; use &lt; &gt; to pick someone else.</font>'
            return
        end
        local d = Intel.get(plr)
        local char = plr.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local hp, maxHp = hum and hum.Health or 0, hum and math.max(hum.MaxHealth, 1) or 100
        local dist = Intel.distTo(plr)
        local now = os.clock()
        local L = {}
        local name = plr.DisplayName ~= plr.Name and (plr.DisplayName .. " (@" .. plr.Name .. ")") or plr.Name
        L[#L + 1] = ('<b><font size="13">%s</font></b>%s'):format(esc(name), Intel.locked and ' <font color="#e6c84f">[locked]</font>' or "")
        L[#L + 1] = ('<font color="#96969f">%s studs away  |  %s</font>'):format(dist and math.floor(dist + 0.5) or "?",
            d.blocking and '<font color="#5aa0ff">BLOCKING</font>' or (d.bladeOut and "saber out" or "saber away"))
        L[#L + 1] = ""
        L[#L + 1] = ('HP  <font color="%s"><b>%d</b></font> / %d'):format(hpColor(hp / maxHp), math.floor(hp + 0.5), math.floor(maxHp + 0.5))
        L[#L + 1] = ('Block  <b>%d</b> / %d%s'):format(math.floor(d.block + 0.5), Intel.MAXB, d.blocking and "" or ' <font color="#96969f">~</font>')
        L[#L + 1] = ('Parries ~ %s  <b>%d</b>/%d%s'):format(pips(d.parries, Intel.MAXP, "#e6c84f"), d.parries, Intel.MAXP,
            d.pNext and ('  <font color="#96969f">+1 in %.1fs</font>'):format(math.max(0, d.pNext - now)) or "")
        L[#L + 1] = ('Kicks ~ %s  <b>%d</b>/%d%s'):format(pips(d.kicks, Intel.MAXK, "#e07a4f"), d.kicks, Intel.MAXK,
            d.kNext and ('  <font color="#96969f">+1 in %.1fs</font>'):format(math.max(0, d.kNext - now)) or "")
        L[#L + 1] = ""

        -- most used
        L[#L + 1] = ('<b><font color="%s">MOST USED</font></b>  <font color="#96969f">(%d moves seen)</font>'):format(hexOf(COLORS.on), d.total)
        local sorted = {}
        for move, n in pairs(d.counts) do sorted[#sorted + 1] = { move = move, n = n } end
        table.sort(sorted, function(a, b) return a.n > b.n end)
        if #sorted == 0 then
            L[#L + 1] = '<font color="#96969f">  nothing yet - fight them for a bit</font>'
        end
        for i = 1, math.min(#sorted, 7) do
            local e = sorted[i]
            local s = d.dist[e.move]
            local avg = (s and s.n > 0) and (" ~" .. math.floor(s.sum / s.n + 0.5) .. " studs") or ""
            L[#L + 1] = ('  %d. %s  <b>%d%%</b> <font color="#96969f">(%dx%s)</font>'):format(i, e.move,
                math.floor(e.n / math.max(d.total, 1) * 100 + 0.5), e.n, avg)
        end

        -- habits: what usually follows each of their top moves
        local habits = {}
        for i = 1, math.min(#sorted, 4) do
            local a = d.after[sorted[i].move]
            if a then
                local bestM, bestN, sum = nil, 0, 0
                for m, n in pairs(a) do
                    sum += n
                    if n > bestN then bestM, bestN = m, n end
                end
                if bestM and sum >= 3 then
                    habits[#habits + 1] = ('  after %s -> <b>%s</b> <font color="#96969f">(%d%%)</font>'):format(sorted[i].move, bestM,
                        math.floor(bestN / sum * 100 + 0.5))
                end
            end
        end
        if #habits > 0 then
            L[#L + 1] = ""
            L[#L + 1] = ('<b><font color="%s">HABITS</font></b>'):format(hexOf(COLORS.on))
            for _, h in ipairs(habits) do L[#L + 1] = h end
        end
        -- next move guess from their last move
        if d.lastMove and now - d.lastMoveT < 3 and d.after[d.lastMove] then
            local a, bestM, bestN, sum = d.after[d.lastMove], nil, 0, 0
            for m, n in pairs(a) do
                sum += n
                if n > bestN then bestM, bestN = m, n end
            end
            if bestM and sum >= 3 then
                L[#L + 1] = ('  <font color="#e6c84f">NEXT GUESS: %s (%d%%)</font>'):format(bestM, math.floor(bestN / sum * 100 + 0.5))
            end
        end

        -- combos: their move chains (moves under 1s apart, quick turns included), most repeated first
        L[#L + 1] = ""
        L[#L + 1] = ('<b><font color="%s">COMBOS</font></b>'):format(hexOf(COLORS.on))
        local combos = {}
        for key, n in pairs(d.combos) do combos[#combos + 1] = { key = key, n = n } end
        table.sort(combos, function(a, b) return a.n > b.n end)
        local shown = 0
        for _, c in ipairs(combos) do
            if c.n >= 2 and shown < 5 then
                shown += 1
                L[#L + 1] = ('  <b>%dx</b>  %s'):format(c.n, esc(c.key))
            end
        end
        if shown == 0 then L[#L + 1] = '<font color="#96969f">  none repeated yet</font>' end
        if d.lastCombo then
            L[#L + 1] = ('  <font color="#96969f">last: %s (%.1fs ago)</font>'):format(esc(d.lastCombo), now - d.lastComboT)
        end

        -- recent moves
        L[#L + 1] = ""
        L[#L + 1] = ('<b><font color="%s">RECENT</font></b>'):format(hexOf(COLORS.on))
        if #d.log == 0 then L[#L + 1] = '<font color="#96969f">  -</font>' end
        for i = 1, math.min(#d.log, 10) do
            local e = d.log[i]
            L[#L + 1] = ('  %s <font color="#96969f">%.1fs ago%s</font>'):format(e.move, now - e.t,
                e.dist and ("  " .. math.floor(e.dist + 0.5) .. " studs") or "")
        end
        L[#L + 1] = ""
        L[#L + 1] = ('<font color="#96969f">stunned %dx  |  died %dx  |  ~ = estimate</font>'):format(d.stuns, d.deaths)
        txt.Text = table.concat(L, "\n")
    end

    local acc = 0
    track(RunService.Heartbeat:Connect(function(dt)
        if not win.Visible then return end
        acc += dt
        if acc < 0.15 then return end
        acc = 0
        pcall(render)
    end))

    -- drag by the title area
    do
        local dragging, dragStart, startPos
        win.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging, dragStart, startPos = true, input.Position, win.Position
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then dragging = false end
                end)
            end
        end)
        track(UserInputService.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                local dd = input.Position - dragStart
                win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + dd.X, startPos.Y.Scale, startPos.Y.Offset + dd.Y)
            end
        end))
    end

    function Intel.setWindow(on)
        settings.intel = on
        win.Visible = on and frame.Visible
        if on then pcall(render) end
    end
end

-- RESOURCE TAGS: a small card over each enemy's head (your screen only)
do
    local tags = {} -- [player] = { bb, name, hpFill, blkFill, res }
    local holder = gui.Parent
    local function makeTag(plr)
        local bb = Instance.new("BillboardGui")
        bb.Name = "CompIntel_Tag"
        bb.Size = UDim2.fromOffset(150, 52)
        bb.StudsOffset = Vector3.new(0, 3.4, 0)
        bb.AlwaysOnTop = true
        bb.ResetOnSpawn = false
        bb.LightInfluence = 0
        local bg = Instance.new("Frame")
        bg.Size = UDim2.fromScale(1, 1)
        bg.BackgroundColor3 = COLORS.bg
        bg.BackgroundTransparency = 0.25
        bg.BorderSizePixel = 0
        bg.Parent = bb
        Instance.new("UICorner", bg).CornerRadius = UDim.new(0, 6)
        local name = Instance.new("TextLabel")
        name.Size = UDim2.new(1, -8, 0, 14)
        name.Position = UDim2.fromOffset(4, 1)
        name.BackgroundTransparency = 1
        name.Font = Enum.Font.GothamBold
        name.TextSize = 11
        name.TextColor3 = COLORS.text
        name.TextTruncate = Enum.TextTruncate.AtEnd
        name.Text = plr.DisplayName
        name.Parent = bg
        local function bar(y, color)
            local back = Instance.new("Frame")
            back.Size = UDim2.new(1, -8, 0, 5)
            back.Position = UDim2.fromOffset(4, y)
            back.BackgroundColor3 = Color3.fromRGB(55, 55, 62)
            back.BorderSizePixel = 0
            back.Parent = bg
            Instance.new("UICorner", back).CornerRadius = UDim.new(1, 0)
            local fill = Instance.new("Frame")
            fill.Size = UDim2.fromScale(1, 1)
            fill.BackgroundColor3 = color
            fill.BorderSizePixel = 0
            fill.Parent = back
            Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)
            return fill
        end
        local hpFill = bar(17, Color3.fromRGB(79, 210, 122))
        local blkFill = bar(25, Color3.fromRGB(90, 160, 255))
        local res = Instance.new("TextLabel")
        res.Size = UDim2.new(1, -8, 0, 16)
        res.Position = UDim2.fromOffset(4, 33)
        res.BackgroundTransparency = 1
        res.Font = Enum.Font.Gotham
        res.TextSize = 11
        res.RichText = true
        res.TextColor3 = COLORS.text
        res.Parent = bg
        pcall(function() bb.Parent = holder end)
        return { bb = bb, name = name, hpFill = hpFill, blkFill = blkFill, res = res }
    end
    local function dropTag(plr)
        local t = tags[plr]
        tags[plr] = nil
        if t then pcall(function() t.bb:Destroy() end) end
    end
    Intel.clearTags = function() for plr in pairs(tags) do dropTag(plr) end end
    track(Players.PlayerRemoving:Connect(dropTag))

    local acc = 0
    track(RunService.Heartbeat:Connect(function(dt)
        acc += dt
        if acc < 0.1 then return end
        acc = 0
        if not settings.intelTags then
            if next(tags) then Intel.clearTags() end
            return
        end
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local char = plr.Character
                local head = char and char:FindFirstChild("Head")
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                local dist = Intel.distTo(plr)
                local show = head and hum and hum.Health > 0 and dist and dist <= settings.intelRange
                    and not (settings.intelTeamCheck and sameTeam(plr))
                if show then
                    local t = tags[plr]
                    if not t or not t.bb.Parent then t = makeTag(plr); tags[plr] = t end
                    if t.bb.Adornee ~= head then t.bb.Adornee = head end
                    local d = Intel.get(plr)
                    local f = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                    t.hpFill.Size = UDim2.fromScale(f, 1)
                    t.hpFill.BackgroundColor3 = f > 0.6 and Color3.fromRGB(79, 210, 122) or (f > 0.3 and Color3.fromRGB(230, 200, 79) or Color3.fromRGB(224, 96, 96))
                    t.blkFill.Size = UDim2.fromScale(math.clamp(d.block / Intel.MAXB, 0, 1), 1)
                    t.res.Text = ('%d hp  P%s  K%s'):format(math.floor(hum.Health + 0.5),
                        pips(d.parries, Intel.MAXP, "#e6c84f"), pips(d.kicks, Intel.MAXK, "#e07a4f"))
                else
                    dropTag(plr)
                end
            end
        end
    end))
end

------------------------------------------------------------------------
-- the menu rows
------------------------------------------------------------------------
makeHeader(10, "RESOURCES")
makeHeader(20, "PERFECT TRADE")
makeHeader(40, "OPPONENT INTEL")

makeSwitch(11, "Infinite Force", settings.force, setForce, "force")
makeSwitch(12, "Infinite Block", settings.block, setBlock, "block")
makeSwitch(13, "Infinite Parry", settings.parry, function(on) settings.parry = on end, "parry")
makeSwitch(14, "Infinite Kicks", settings.kick, function(on) settings.kick = on end, "kick")

-- someone's swing lands on your block -> you multi them once right after (then block again if held)
local tradeSwitch = makeSwitch(21, "Perfect trade", settings.perfectTrade, function(on) settings.perfectTrade = on end, "perfectTrade")
KB.makeRow(22, "Perfect trade key", "tradeKey")
KB.add(function() return settings.tradeKey end, function()
    settings.perfectTrade = not settings.perfectTrade
    if tradeSwitch then tradeSwitch(settings.perfectTrade, true) end
    if AP.toast then AP.toast("Perfect trade", settings.perfectTrade) end
end)
makeSwitch(23, "Natural (human-like)", settings.tradeNatural, function(on) settings.tradeNatural = on end, "tradeNatural")
makeNumberBox(24, "Trade chance (%)", "tradeChance", 0, 100)
makeNumberBox(25, "Reaction (ms)", "tradeReact", 0, 400)
makeNumberBox(26, "Max trades in a row", "tradeStreak", 1, 10)
makeNumberBox(27, "Plain swing (%)", "tradePlain", 0, 100)
makeSwitch(28, "Trade team check", settings.tradeTeamCheck, function(on) settings.tradeTeamCheck = on end, "tradeTeamCheck")
makeWhitelist(29, "Trade only (none = all)", "tradeOnly", "Pick")

local intelSwitch = makeSwitch(41, "Intel window", settings.intel, function(on) Intel.setWindow(on) end, "intel")
KB.makeRow(42, "Intel window key", "intelKey")
KB.add(function() return settings.intelKey end, function()
    Intel.setWindow(not settings.intel)
    if intelSwitch then intelSwitch(settings.intel, true) end
    if AP.toast then AP.toast("Intel window", settings.intel) end
end)
makeSwitch(43, "Resource tags (over heads)", settings.intelTags, function(on) settings.intelTags = on end, "intelTags")
makeNumberBox(44, "Intel range (studs)", "intelRange", 10, 300)
makeSwitch(45, "Intel team check", settings.intelTeamCheck, function(on) settings.intelTeamCheck = on end, "intelTeamCheck")

------------------------------------------------------------------------
-- GUIDE: a button at the very top of the feature list opens a separate window that explains
-- every feature and its values. Drag the title bar to move it; drag any edge or corner to
-- resize it (they glow green when you hover them).
------------------------------------------------------------------------
do
    local SECTIONS = {
        { "GETTING STARTED", {
            { "Using this window", {
                "Drag the title bar to move this window.",
                "Drag any edge or corner to make it bigger or smaller. They glow green when you hover them.",
                "Scroll with the mouse wheel. The X (or the Guide button) closes it.",
            } },
            { "The basics", {
                "Click a switch to turn a feature ON or OFF (green = ON).",
                "Type a number into a box and press Enter (or click away) to set it.",
                "Mouse wheel scrolls the main menu. {{Ctrl+H}} hides or shows the menu, the Intel window and this guide. Features keep running while hidden.",
                "Running the script again replaces the old copy, so you never get doubles.",
            } },
            { "Before you start", {
                "Equip and ignite your lightsaber. Infinite Parry/Kicks/Block and Perfect trade find your saber by themselves. If one does nothing, unequip and re-equip it and wait a couple of seconds.",
                "Turn on **Infinite Force** if you use Perfect trade, because its dash costs Force.",
                "Press {{F9}} to open the Roblox console. The script prints what it found there.",
            } },
            { "What it can and can not do", {
                "Everything here works on YOUR screen and with YOUR inputs. The server still decides damage, stuns and whether a hit lands, so nothing is a guarantee.",
            } },
        } },
        { "CONFIGS", {
            { "Save a config", {
                "Type a name in the box under CONFIGS and press SAVE (or Enter). It stores every switch, number, your keys and the Trade only list.",
                "Saving under an existing name overwrites it. Only letters, numbers, spaces, - and _ are kept in names.",
                "Files are written to {{CompIntel/configs}} in your executor's workspace folder. If your executor can not write files they are kept in memory until you close the game, and the status line says so.",
            } },
            { "Load a config", {
                "Click LOAD CONFIG to open the list, then click a name. Every switch, number, key and list is set to what you saved, and the features turn on or off to match.",
                "The X next to a name deletes it: click once (it turns red with a ?), then click again within 2.5 seconds.",
            } },
        } },
        { "RESOURCES", {
            { "Infinite Force", {
                "Your Force bar stays full, so dashes and Force powers never run out.",
            } },
            { "Infinite Block", {
                "Your block meter never breaks. The hit-on-block animation still plays if your executor can hook functions; otherwise hits on your block simply do nothing.",
            } },
            { "Infinite Parry / Infinite Kicks", {
                "Your parries stay at 5 and your kicks at 3, so you never run out. Needs your saber equipped and an executor with getgc.",
            } },
        } },
        { "PERFECT TRADE", {
            { "Perfect trade", {
                "While you block, when someone's swing lands on your block you let go and hit them back with ONE multi (dash cancelled into a swing), then your block goes back up if you're still holding it. That's a trade.",
                "It answers the attacker who is close, swinging (or just swung) and facing you. Kicks are ignored.",
                "**Perfect trade key**: click the box and press a key to toggle it from anywhere. A pop-up in the top right says ON or OFF.",
            } },
            { "Natural (human-like)", {
                "ON (recommended): it plays like a person. It doesn't trade every hit, reacts with a random human delay, rarely trades many times in a row, and now and then answers with a plain swing instead of a multi. It also re-checks after the delay: if you stopped blocking or they walked off, it doesn't go.",
                "OFF: the old way. Every hit is traded, instantly, always with a multi.",
            } },
            { "Trade chance (%)", {
                "Default {{65}}. How many of the hits on your block get traded. 100 = every one (like OFF, but still with the human delay).",
            } },
            { "Reaction (ms)", {
                "Default {{110}}. The average wait before the trade starts. Each trade picks a random time around it (60% to 140% of it), so it is never the same twice. Lower = snappier, higher = more casual.",
            } },
            { "Max trades in a row", {
                "Default {{2}}. After this many trades in a row the next one is far less likely, the way a real player sometimes just keeps blocking.",
            } },
            { "Plain swing (%)", {
                "Default {{20}}. How often the trade is a plain swing instead of a multi. 0 = always a multi.",
            } },
            { "Trade team check / Trade only", {
                "Team check ON: never trades with your own team or side.",
                "Trade only: click Pick and tick players. When anyone is ticked, Perfect trade ONLY answers them. Nobody ticked = everyone.",
            } },
        } },
        { "OPPONENT INTEL", {
            { "Intel window", {
                "A window that shows the opponent you're fighting. It picks whoever last made a move near you (within 25 studs), otherwise the nearest enemy in range.",
                "**< >** switch to the previous / next player in range (this locks onto them). **Lock** keeps the current one; click **Auto** to go back to automatic. **Reset** (click twice) forgets everyone's move stats.",
                "Drag it anywhere. **Intel window key** shows or hides it from anywhere.",
            } },
            { "What it shows", {
                "**HP**: exact. **Block**: their block meter, exact while they block. Between blocks it refills the way the game does (2.5s, then fast), marked ~.",
                "**Parries ~ / Kicks ~**: ESTIMATES. The real numbers are only on their computer, so the script counts every parry and kick it sees them do and refills them with the game's own timers: 1 parry every 5s (not while blocking), 1 kick every 2s, only while they keep blocking. A parry that stuns someone gives them 1 back. \"+1 in\" shows when the next one comes back. Everything resets to full when they respawn.",
                "**MOST USED**: their moves, most used first, with % and how many times. The studs number is how far from YOU they usually are when they use it, for example kicks from about 6 studs.",
                "**HABITS**: what they usually do right AFTER each of their main moves (within 3 seconds). **NEXT GUESS**: from their last move, what they will most likely do next.",
                "**COMBOS**: their move chains, most repeated first, for example {{3x  Slight turn left > Swing > Parry}}. Moves less than 1 second apart count as one combo, and a quick turn right before a move is included (Slight turn = 35 to 90 degrees, Turn = 90 to 150, Turn around = more). The same move several times in a row shows as x2, x3. Only combos they did at least twice are listed; **last:** shows the newest one.",
                "**RECENT**: their last moves with how long ago and from how far.",
            } },
            { "Moves it can tell apart", {
                "Swing, Multi, Dash attack, Kick, Dash kick, Parry, Block, Dash, Flip / roll, Saber throw and Force power.",
                "It counts everyone all the time, even with the window closed, so the numbers are ready when you open it.",
            } },
            { "Resource tags (over heads)", {
                "A small card above every enemy in range: name, HP bar (green, yellow, red), block bar (blue), HP number, parries (yellow dots) and kicks (orange dots). Only you see them.",
            } },
            { "Intel range / Intel team check", {
                "Range (default {{60}} studs): how far the tags show and how far the window looks for an opponent.",
                "Team check ON: teammates get no tag and are never picked.",
            } },
        } },
        { "TIPS AND FIXES", {
            { "A feature does nothing", {
                "Equip and ignite your saber, wait 2 seconds, then check {{F9}} for what was found.",
            } },
            { "Parry / kick numbers look off", {
                "They are estimates. If you joined mid-fight, the script didn't see their earlier parries and kicks, so it starts them at full. They line up again after a respawn or once they refill.",
            } },
            { "Trades look too robotic", {
                "Turn Natural ON, lower Trade chance (50 to 60), raise Reaction (130 to 170) and Plain swing (25 to 35).",
            } },
        } },
    }

    local MINW, MINH = 300, 200
    local guide = Instance.new("Frame")
    guide.Name = "Guide"
    guide.BackgroundColor3 = COLORS.bg
    guide.BorderSizePixel = 0
    guide.Active = true
    guide.Visible = false
    guide.ZIndex = 5
    guide.Parent = gui
    Instance.new("UICorner", guide).CornerRadius = UDim.new(0, 8)
    local gstroke = Instance.new("UIStroke")
    gstroke.Color = COLORS.off
    gstroke.Thickness = 1
    gstroke.Parent = guide
    KB.guideFrame = guide

    -- title bar (drag to move)
    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(1, 0, 0, 30)
    bar.BackgroundColor3 = COLORS.panel
    bar.BorderSizePixel = 0
    bar.Active = true
    bar.Parent = guide
    Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 8)
    local barFix = Instance.new("Frame")
    barFix.Size = UDim2.new(1, 0, 0, 8)
    barFix.Position = UDim2.new(0, 0, 1, -8)
    barFix.BackgroundColor3 = COLORS.panel
    barFix.BorderSizePixel = 0
    barFix.Parent = bar
    local gtitle = Instance.new("TextLabel")
    gtitle.Size = UDim2.new(1, -60, 1, 0)
    gtitle.Position = UDim2.fromOffset(12, 0)
    gtitle.BackgroundTransparency = 1
    gtitle.Font = Enum.Font.GothamBold
    gtitle.TextSize = 13
    gtitle.TextXAlignment = Enum.TextXAlignment.Left
    gtitle.TextColor3 = COLORS.text
    gtitle.Text = "Comp Client - Guide"
    gtitle.Parent = bar
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.fromOffset(24, 22)
    closeBtn.Position = UDim2.new(1, -40, 0, 4)
    closeBtn.BackgroundColor3 = Color3.fromRGB(150, 60, 60)
    closeBtn.BorderSizePixel = 0
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 12
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.Text = "X"
    closeBtn.Parent = bar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

    -- scrolling text area
    local body = Instance.new("ScrollingFrame")
    body.Position = UDim2.fromOffset(0, 30)
    body.Size = UDim2.new(1, 0, 1, -30)
    body.BackgroundTransparency = 1
    body.BorderSizePixel = 0
    body.ScrollBarThickness = 6
    body.ScrollBarImageColor3 = COLORS.sub
    body.ScrollingDirection = Enum.ScrollingDirection.Y
    body.CanvasSize = UDim2.new(0, 0, 0, 0)
    body.AutomaticCanvasSize = Enum.AutomaticSize.Y
    body.Parent = guide
    do
        local lay = Instance.new("UIListLayout")
        lay.SortOrder = Enum.SortOrder.LayoutOrder
        lay.Padding = UDim.new(0, 6)
        lay.HorizontalAlignment = Enum.HorizontalAlignment.Center
        lay.Parent = body
        local pad = Instance.new("UIPadding")
        pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 16)
        pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 10), UDim.new(0, 14)
        pad.Parent = body
    end

    local function fmt(s)
        s = s:gsub("%*%*(.-)%*%*", "<b>%1</b>")
        s = s:gsub("{{(.-)}}", '<font color="#f2c46d">%1</font>')
        return s
    end
    local order = 0
    for _, sec in ipairs(SECTIONS) do
        order = order + 1
        local h = Instance.new("TextLabel")
        h.Size = UDim2.new(1, 0, 0, 24)
        h.LayoutOrder = order
        h.BackgroundTransparency = 1
        h.Font = Enum.Font.GothamBold
        h.TextSize = 14
        h.TextColor3 = COLORS.on
        h.TextXAlignment = Enum.TextXAlignment.Left
        h.Text = sec[1]
        h.Parent = body
        local ln = Instance.new("Frame")
        ln.Size = UDim2.new(1, 0, 0, 1)
        ln.Position = UDim2.new(0, 0, 1, -1)
        ln.BackgroundColor3 = COLORS.off
        ln.BorderSizePixel = 0
        ln.Parent = h
        for _, item in ipairs(sec[2]) do
            order = order + 1
            local lines = {}
            for i, l in ipairs(item[2]) do lines[i] = "- " .. l end
            local card = Instance.new("TextLabel")
            card.Size = UDim2.new(1, 0, 0, 0)
            card.AutomaticSize = Enum.AutomaticSize.Y
            card.LayoutOrder = order
            card.BackgroundColor3 = COLORS.panel
            card.BorderSizePixel = 0
            card.Font = Enum.Font.Gotham
            card.TextSize = 12
            card.TextColor3 = COLORS.text
            card.TextWrapped = true
            card.RichText = true
            card.LineHeight = 1.15
            card.TextXAlignment = Enum.TextXAlignment.Left
            card.TextYAlignment = Enum.TextYAlignment.Top
            card.Text = '<b><font color="#6fd08a">' .. item[1] .. "</font></b>\n" .. fmt(table.concat(lines, "\n"))
            card.Parent = body
            Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)
            local p = Instance.new("UIPadding")
            p.PaddingTop, p.PaddingBottom = UDim.new(0, 7), UDim.new(0, 7)
            p.PaddingLeft, p.PaddingRight = UDim.new(0, 9), UDim.new(0, 9)
            p.Parent = card
        end
    end

    -- move / resize
    local gx, gy, gw, gh = 0, 0, 540, 420
    local drag
    local function viewport()
        local cam = workspace.CurrentCamera
        return cam and cam.ViewportSize or Vector2.new(1280, 720)
    end
    local function apply()
        guide.Position = UDim2.fromOffset(gx, gy)
        guide.Size = UDim2.fromOffset(gw, gh)
    end
    local function isPress(input)
        return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
    end
    local function beginDrag(input, mode, l, r, t, b, handle)
        if not isPress(input) then return end
        drag = { mode = mode, l = l, r = r, t = t, b = b, hnd = handle,
            mx = input.Position.X, my = input.Position.Y, x = gx, y = gy, w = gw, h = gh }
    end
    bar.InputBegan:Connect(function(input) beginDrag(input, "move") end)

    -- the eight grab areas: 4 sides + 4 corners (invisible until hovered)
    local HANDLES = {
        { UDim2.new(0, -3, 0, 14), UDim2.new(0, 7, 1, -28), true, false, false, false },   -- left
        { UDim2.new(1, -4, 0, 14), UDim2.new(0, 7, 1, -28), false, true, false, false },   -- right
        { UDim2.new(0, 14, 0, -3), UDim2.new(1, -28, 0, 7), false, false, true, false },   -- top
        { UDim2.new(0, 14, 1, -4), UDim2.new(1, -28, 0, 7), false, false, false, true },   -- bottom
        { UDim2.new(0, -3, 0, -3), UDim2.fromOffset(16, 16), true, false, true, false },   -- top-left
        { UDim2.new(1, -13, 0, -3), UDim2.fromOffset(16, 16), false, true, true, false },  -- top-right
        { UDim2.new(0, -3, 1, -13), UDim2.fromOffset(16, 16), true, false, false, true },  -- bottom-left
        { UDim2.new(1, -13, 1, -13), UDim2.fromOffset(16, 16), false, true, false, true }, -- bottom-right
    }
    for _, d in ipairs(HANDLES) do
        local hnd = Instance.new("Frame")
        hnd.Position, hnd.Size = d[1], d[2]
        hnd.BackgroundColor3 = COLORS.on
        hnd.BackgroundTransparency = 1
        hnd.BorderSizePixel = 0
        hnd.Active = true
        hnd.ZIndex = 10
        hnd.Parent = guide
        Instance.new("UICorner", hnd).CornerRadius = UDim.new(0, 4)
        hnd.MouseEnter:Connect(function() hnd.BackgroundTransparency = 0.55 end)
        hnd.MouseLeave:Connect(function()
            if not (drag and drag.hnd == hnd) then hnd.BackgroundTransparency = 1 end
        end)
        hnd.InputBegan:Connect(function(input) beginDrag(input, "resize", d[3], d[4], d[5], d[6], hnd) end)
    end

    track(UserInputService.InputChanged:Connect(function(input)
        if not drag then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local dx, dy = input.Position.X - drag.mx, input.Position.Y - drag.my
        local v = viewport()
        if drag.mode == "move" then
            gx = math.clamp(drag.x + dx, 80 - gw, v.X - 80)
            gy = math.clamp(drag.y + dy, 0, v.Y - 40)
        else
            local nw, nh = drag.w, drag.h
            if drag.r then nw = drag.w + dx elseif drag.l then nw = drag.w - dx end
            if drag.b then nh = drag.h + dy elseif drag.t then nh = drag.h - dy end
            nw = math.clamp(nw, MINW, math.max(MINW, v.X - 8))
            nh = math.clamp(nh, MINH, math.max(MINH, v.Y - 8))
            gw, gh = nw, nh
            if drag.l then gx = drag.x + (drag.w - nw) end
            if drag.t then gy = drag.y + (drag.h - nh) end
        end
        apply()
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if drag and isPress(input) then
            if drag.hnd then drag.hnd.BackgroundTransparency = 1 end
            drag = nil
        end
    end))

    -- the button at the top of the feature list
    local gb = Instance.new("TextButton")
    gb.Size = UDim2.new(1, -16, 0, 28)
    gb.LayoutOrder = 1
    gb.BackgroundColor3 = COLORS.on
    gb.BorderSizePixel = 0
    gb.Font = Enum.Font.GothamBold
    gb.TextSize = 12
    gb.TextColor3 = Color3.new(1, 1, 1)
    gb.AutoButtonColor = true
    gb.Parent = content
    Instance.new("UICorner", gb).CornerRadius = UDim.new(0, 6)

    local placed = false
    local function setOpen(on)
        if on and not placed then
            placed = true
            local v = viewport()
            gw = math.min(560, math.max(MINW, v.X - 40))
            gh = math.min(440, math.max(MINH, v.Y - 80))
            gx = math.floor((v.X - gw) / 2)
            gy = math.floor((v.Y - gh) / 2)
            apply()
        end
        guide.Visible = on
        gb.Text = on and "CLOSE GUIDE" or "GUIDE - how everything works"
    end
    setOpen(false)
    -- keeps the button label right when Ctrl+H hides the guide along with the menu
    guide:GetPropertyChangedSignal("Visible"):Connect(function()
        gb.Text = guide.Visible and "CLOSE GUIDE" or "GUIDE - how everything works"
    end)
    gb.MouseButton1Click:Connect(function() setOpen(not guide.Visible) end)
    closeBtn.MouseButton1Click:Connect(function() setOpen(false) end)
end

------------------------------------------------------------------------
-- CONFIGS: save everything you have set (switches, numbers, keys, the Trade only list) under a
-- name, and load any saved config from a drop-down. Files live in your executor's workspace folder:
--     CompIntel/configs/<name>.json
-- (an executor with no file functions keeps them in memory until the game closes instead)
------------------------------------------------------------------------
do
    local HttpService = game:GetService("HttpService")
    local FOLDER, SUB = "CompIntel", "CompIntel/configs"
    local hasFS = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
    local env = (getgenv and getgenv()) or _G
    env.CompIntel_MemConfigs = env.CompIntel_MemConfigs or {}
    local mem = env.CompIntel_MemConfigs

    local function snapshot()
        local d = { sw = {}, num = {}, kb = {}, wl = {} }
        for k in pairs(CFG_UI.sw) do d.sw[k] = settings[k] == true end
        for k in pairs(CFG_UI.num) do d.num[k] = settings[k] end
        for k in pairs(CFG_UI.kb) do d.kb[k] = settings[k] end
        for listName in pairs(CFG_UI.wl) do
            local arr = {}
            for uid in pairs(settings.whitelist[listName]) do arr[#arr + 1] = uid end
            d.wl[listName] = arr
        end
        return d
    end

    local function applyConfig(d)
        for k, v in pairs(d.sw or {}) do
            local setter = CFG_UI.sw[k]
            if setter and type(v) == "boolean" then
                if settings[k] ~= v then pcall(setter, v) else pcall(setter, v, true) end
            end
        end
        for k, v in pairs(d.num or {}) do
            local nb, n = CFG_UI.num[k], tonumber(v)
            if nb and n then
                settings[k] = math.clamp(n, nb.min, nb.max)
                nb.refresh()
            end
        end
        for k, v in pairs(d.kb or {}) do
            if CFG_UI.kb[k] and type(v) == "string" then
                settings[k] = v
                CFG_UI.kb[k]()
            end
        end
        for listName, arr in pairs(d.wl or {}) do
            local t = settings.whitelist[listName]
            if t and type(arr) == "table" then
                for kk in pairs(t) do t[kk] = nil end
                for _, uid in ipairs(arr) do
                    local n = tonumber(uid)
                    if n then t[n] = true end
                end
                if CFG_UI.wl[listName] then CFG_UI.wl[listName]() end
            end
        end
    end

    local function cfgPath(name) return SUB .. "/" .. name .. ".json" end

    local function listNames()
        local names, seen = {}, {}
        if hasFS and type(listfiles) == "function" and type(isfolder) == "function" then
            pcall(function()
                if isfolder(SUB) then
                    for _, p in ipairs(listfiles(SUB)) do
                        local n = tostring(p):match("([^/\\]+)%.json$")
                        if n and not seen[n] then seen[n] = true; names[#names + 1] = n end
                    end
                end
            end)
        end
        for n in pairs(mem) do
            if not seen[n] then seen[n] = true; names[#names + 1] = n end
        end
        table.sort(names, function(a, b) return a:lower() < b:lower() end)
        return names
    end

    local function saveConfig(name)
        local json = HttpService:JSONEncode(snapshot())
        if hasFS then
            local ok = pcall(function()
                if type(isfolder) == "function" and type(makefolder) == "function" then
                    if not isfolder(FOLDER) then makefolder(FOLDER) end
                    if not isfolder(SUB) then makefolder(SUB) end
                end
                writefile(cfgPath(name), json)
            end)
            if ok then mem[name] = nil return "file" end
        end
        mem[name] = json
        return "memory"
    end

    local function readConfig(name)
        local json = mem[name]
        if not json and hasFS then
            pcall(function()
                if isfile(cfgPath(name)) then json = readfile(cfgPath(name)) end
            end)
        end
        if not json then return nil end
        local ok, d = pcall(function() return HttpService:JSONDecode(json) end)
        if ok and type(d) == "table" then return d end
        return nil
    end

    local function deleteConfig(name)
        mem[name] = nil
        if hasFS and type(delfile) == "function" then
            pcall(function() if isfile(cfgPath(name)) then delfile(cfgPath(name)) end end)
        end
    end

    local function cleanName(s)
        s = tostring(s or "")
        s = s:gsub("[^%w _%-]", "")
        s = s:gsub("^%s+", "")
        s = s:gsub("%s+$", "")
        return s:sub(1, 32)
    end

    ---------------------------------------------------------------- UI
    makeHeader(2, "CONFIGS")
    local box = Instance.new("Frame")
    box.Size = UDim2.new(1, -16, 0, 0)
    box.AutomaticSize = Enum.AutomaticSize.Y
    box.LayoutOrder = 3
    box.BackgroundTransparency = 1
    box.BorderSizePixel = 0
    box.Parent = content
    do
        local lay = Instance.new("UIListLayout")
        lay.SortOrder = Enum.SortOrder.LayoutOrder
        lay.Padding = UDim.new(0, 4)
        lay.Parent = box
    end

    -- row 1: name box + SAVE
    local row1 = Instance.new("Frame")
    row1.Size = UDim2.new(1, 0, 0, 26)
    row1.LayoutOrder = 1
    row1.BackgroundColor3 = COLORS.panel
    row1.BorderSizePixel = 0
    row1.Parent = box
    Instance.new("UICorner", row1).CornerRadius = UDim.new(0, 6)
    local nameBox = Instance.new("TextBox")
    nameBox.Size = UDim2.new(1, -72, 0, 18)
    nameBox.Position = UDim2.fromOffset(6, 4)
    nameBox.BackgroundColor3 = COLORS.bg
    nameBox.BorderSizePixel = 0
    nameBox.Font = Enum.Font.Gotham
    nameBox.TextSize = 11
    nameBox.TextColor3 = COLORS.text
    nameBox.PlaceholderText = "config name..."
    nameBox.PlaceholderColor3 = COLORS.sub
    nameBox.Text = ""
    nameBox.ClearTextOnFocus = false
    nameBox.TextXAlignment = Enum.TextXAlignment.Left
    nameBox.Parent = row1
    Instance.new("UICorner", nameBox).CornerRadius = UDim.new(0, 5)
    do
        local p = Instance.new("UIPadding")
        p.PaddingLeft = UDim.new(0, 6)
        p.Parent = nameBox
    end
    local saveBtn = Instance.new("TextButton")
    saveBtn.Size = UDim2.fromOffset(54, 18)
    saveBtn.Position = UDim2.new(1, -60, 0.5, -9)
    saveBtn.BackgroundColor3 = COLORS.on
    saveBtn.BorderSizePixel = 0
    saveBtn.Font = Enum.Font.GothamBold
    saveBtn.TextSize = 10
    saveBtn.TextColor3 = Color3.new(1, 1, 1)
    saveBtn.Text = "SAVE"
    saveBtn.AutoButtonColor = true
    saveBtn.Parent = row1
    Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 6)

    -- row 2: the LOAD drop-down toggle
    local row2 = Instance.new("Frame")
    row2.Size = UDim2.new(1, 0, 0, 26)
    row2.LayoutOrder = 2
    row2.BackgroundColor3 = COLORS.panel
    row2.BorderSizePixel = 0
    row2.Parent = box
    Instance.new("UICorner", row2).CornerRadius = UDim.new(0, 6)
    local loadBtn = Instance.new("TextButton")
    loadBtn.Size = UDim2.new(1, -12, 0, 18)
    loadBtn.Position = UDim2.fromOffset(6, 4)
    loadBtn.BackgroundColor3 = COLORS.bg
    loadBtn.BorderSizePixel = 0
    loadBtn.Font = Enum.Font.GothamBold
    loadBtn.TextSize = 10
    loadBtn.TextColor3 = COLORS.text
    loadBtn.AutoButtonColor = true
    loadBtn.Parent = row2
    Instance.new("UICorner", loadBtn).CornerRadius = UDim.new(0, 5)

    -- the drop-down list of saved configs
    local dd = Instance.new("Frame")
    dd.Size = UDim2.new(1, 0, 0, 112)
    dd.LayoutOrder = 3
    dd.BackgroundColor3 = COLORS.panel
    dd.BorderSizePixel = 0
    dd.Visible = false
    dd.Parent = box
    Instance.new("UICorner", dd).CornerRadius = UDim.new(0, 6)
    local ddList = Instance.new("ScrollingFrame")
    ddList.Size = UDim2.new(1, -10, 1, -10)
    ddList.Position = UDim2.fromOffset(5, 5)
    ddList.BackgroundTransparency = 1
    ddList.BorderSizePixel = 0
    ddList.ScrollBarThickness = 3
    ddList.CanvasSize = UDim2.new(0, 0, 0, 0)
    ddList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    ddList.Parent = dd
    do
        local ll = Instance.new("UIListLayout")
        ll.SortOrder = Enum.SortOrder.LayoutOrder
        ll.Padding = UDim.new(0, 2)
        ll.Parent = ddList
    end

    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, 0, 0, 0)
    status.AutomaticSize = Enum.AutomaticSize.Y
    status.LayoutOrder = 4
    status.BackgroundTransparency = 1
    status.Font = Enum.Font.Gotham
    status.TextSize = 10
    status.TextWrapped = true
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.TextColor3 = COLORS.sub
    status.Text = hasFS and "  type a name, then SAVE. Load from the list." or "  (no file access: configs last until you close the game)"
    status.Parent = box
    local function setStatus(text, bad)
        status.Text = "  " .. text
        status.TextColor3 = bad and Color3.fromRGB(220, 80, 80) or COLORS.sub
    end

    local function refreshLoadLabel()
        loadBtn.Text = "LOAD CONFIG  " .. (dd.Visible and "^" or "v")
    end

    local rebuildList
    local function doLoad(name)
        local d = readConfig(name)
        if not d then setStatus("could not read '" .. name .. "'", true) return end
        applyConfig(d)
        nameBox.Text = name
        setStatus("loaded '" .. name .. "'")
        log("config loaded: " .. name)
        dd.Visible = false
        refreshLoadLabel()
    end
    rebuildList = function()
        for _, c in ipairs(ddList:GetChildren()) do
            if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
        end
        local names = listNames()
        if #names == 0 then
            local e = Instance.new("TextLabel")
            e.Size = UDim2.new(1, -4, 0, 20)
            e.BackgroundTransparency = 1
            e.Font = Enum.Font.Gotham
            e.TextSize = 11
            e.TextColor3 = COLORS.sub
            e.TextXAlignment = Enum.TextXAlignment.Left
            e.Text = "  (no saved configs yet)"
            e.Parent = ddList
            return
        end
        for i, name in ipairs(names) do
            local r = Instance.new("Frame")
            r.Size = UDim2.new(1, -4, 0, 22)
            r.LayoutOrder = i
            r.BackgroundTransparency = 1
            r.BorderSizePixel = 0
            r.Parent = ddList
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, -26, 1, 0)
            b.BackgroundColor3 = COLORS.bg
            b.BorderSizePixel = 0
            b.Font = Enum.Font.Gotham
            b.TextSize = 11
            b.TextColor3 = COLORS.text
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.TextTruncate = Enum.TextTruncate.AtEnd
            b.AutoButtonColor = true
            b.Text = "  " .. name
            b.Parent = r
            Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
            b.MouseButton1Click:Connect(function() doLoad(name) end)
            -- delete: click X, then click again (it turns red and asks) within 2.5 seconds
            local x = Instance.new("TextButton")
            x.Size = UDim2.new(0, 22, 1, 0)
            x.Position = UDim2.new(1, -22, 0, 0)
            x.BackgroundColor3 = COLORS.off
            x.BorderSizePixel = 0
            x.Font = Enum.Font.GothamBold
            x.TextSize = 10
            x.TextColor3 = Color3.new(1, 1, 1)
            x.Text = "X"
            x.AutoButtonColor = true
            x.Parent = r
            Instance.new("UICorner", x).CornerRadius = UDim.new(0, 5)
            local armed = false
            x.MouseButton1Click:Connect(function()
                if not armed then
                    armed = true
                    x.Text, x.BackgroundColor3 = "?", Color3.fromRGB(190, 60, 60)
                    task.delay(2.5, function()
                        if armed and x.Parent then
                            armed = false
                            x.Text, x.BackgroundColor3 = "X", COLORS.off
                        end
                    end)
                else
                    deleteConfig(name)
                    setStatus("deleted '" .. name .. "'")
                    rebuildList()
                end
            end)
        end
    end

    loadBtn.MouseButton1Click:Connect(function()
        dd.Visible = not dd.Visible
        if dd.Visible then rebuildList() end
        refreshLoadLabel()
    end)
    local function doSave()
        local name = cleanName(nameBox.Text)
        if name == "" then setStatus("type a name first (letters, numbers, spaces)", true) return end
        local existed = false
        for _, n in ipairs(listNames()) do if n == name then existed = true break end end
        local okS, where = pcall(saveConfig, name)
        if not okS then setStatus("save failed: " .. tostring(where), true) return end
        nameBox.Text = name
        setStatus((existed and "overwrote '" or "saved '") .. name .. "'" .. (where == "file" and "" or " (in memory only)"))
        log("config saved: " .. name)
        if dd.Visible then rebuildList() end
    end
    saveBtn.MouseButton1Click:Connect(doSave)
    nameBox.FocusLost:Connect(function(enterPressed) if enterPressed then doSave() end end)
    refreshLoadLabel()
end

------------------------------------------------------------------------
-- Password lock. The panel shows only this screen until the right password is
-- typed. Only a hash is stored here, not the password itself.
-- NOTE: this keeps casual users out of the menu; it isn't real security (anyone
-- who reads/edits the script on GitHub can remove it).
------------------------------------------------------------------------
local PASSWORD_HASH = 1815920161
local function hashPassword(s)
    local h = 5381
    for i = 1, #s do
        h = bit32.bxor((h * 33) % 4294967296, string.byte(s, i))
    end
    return h
end

local lock = Instance.new("Frame")
lock.Size = UDim2.new(1, 0, 1, -36)
lock.Position = UDim2.fromOffset(0, 36)
lock.BackgroundTransparency = 1
lock.BorderSizePixel = 0
lock.Parent = frame

local lockLabel = Instance.new("TextLabel")
lockLabel.Size = UDim2.new(1, -16, 0, 40)
lockLabel.Position = UDim2.fromOffset(8, 40)
lockLabel.BackgroundTransparency = 1
lockLabel.Font = Enum.Font.Gotham
lockLabel.TextSize = 13
lockLabel.TextWrapped = true
lockLabel.TextColor3 = COLORS.sub
lockLabel.Text = "Locked. Enter the password to see the features."
lockLabel.Parent = lock

local pwBox = Instance.new("TextBox")
pwBox.Size = UDim2.new(1, -16, 0, 32)
pwBox.Position = UDim2.fromOffset(8, 96)
pwBox.BackgroundColor3 = COLORS.panel
pwBox.BorderSizePixel = 0
pwBox.Font = Enum.Font.GothamBold
pwBox.TextSize = 13
pwBox.TextColor3 = COLORS.text
pwBox.PlaceholderText = "Password"
pwBox.PlaceholderColor3 = COLORS.sub
pwBox.Text = ""
pwBox.ClearTextOnFocus = false
pwBox.Parent = lock
Instance.new("UICorner", pwBox).CornerRadius = UDim.new(0, 6)

local unlockBtn = Instance.new("TextButton")
unlockBtn.Size = UDim2.new(1, -16, 0, 32)
unlockBtn.Position = UDim2.fromOffset(8, 138)
unlockBtn.BackgroundColor3 = COLORS.on
unlockBtn.BorderSizePixel = 0
unlockBtn.Font = Enum.Font.GothamBold
unlockBtn.TextSize = 13
unlockBtn.TextColor3 = Color3.new(1, 1, 1)
unlockBtn.Text = "Unlock"
unlockBtn.Parent = lock
Instance.new("UICorner", unlockBtn).CornerRadius = UDim.new(0, 6)

local function tryUnlock()
    if hashPassword(pwBox.Text) == PASSWORD_HASH then
        pwBox.Text = ""
        lock.Visible = false
        content.Visible = true
        log("unlocked")
    else
        pwBox.Text = ""
        lockLabel.Text = "Wrong password."
        lockLabel.TextColor3 = Color3.fromRGB(220, 80, 80)
    end
end
unlockBtn.MouseButton1Click:Connect(tryUnlock)
pwBox.FocusLost:Connect(function(enterPressed)
    if enterPressed then tryUnlock() end
end)

-- dragging
do
    local dragging, dragStart, startPos
    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
end

local function onList()
    local on = {}
    if settings.force then table.insert(on, "Force") end
    if settings.block then table.insert(on, "Block") end
    if settings.parry then table.insert(on, "Parry") end
    if settings.kick then table.insert(on, "Kicks") end
    if settings.perfectTrade then table.insert(on, "PerfectTrade") end
    if settings.intel then table.insert(on, "IntelWindow") end
    if settings.intelTags then table.insert(on, "ResourceTags") end
    return #on > 0 and table.concat(on, ", ") or "nothing"
end

--[[
    Ctrl + H fully hides/shows the menu - nothing is left on screen.
    Glitch-proofing:
      - Hiding ONLY flips `frame.Visible`. No feature reads the panel, the switches,
        or `Visible`; they all read the `settings` table, which hiding never touches.
      - The gui itself stays Enabled and parented, so nothing gets destroyed or
        garbage-collected while hidden.
      - The 2s self-heal loop keeps re-applying ON features while hidden.
      - Instead of an on-screen status line, F9 prints what's still ON each time
        you hide it, so you can check without anything showing.
]]
track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed or input.KeyCode ~= Enum.KeyCode.H then return end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
        frame.Visible = not frame.Visible
        if not frame.Visible and KB.guideFrame then KB.guideFrame.Visible = false end -- nothing left on screen
        if KB.intelFrame then KB.intelFrame.Visible = frame.Visible and settings.intel end
        if frame.Visible then
            log("menu shown")
        else
            log("menu hidden (Ctrl+H to bring it back) - still ON: " .. onList())
        end
    end
end))

------------------------------------------------------------------------
-- cleanup (used when you re-execute the script)
------------------------------------------------------------------------
local function cleanup()
    setForce(false)
    setBlock(false)
    settings.parry, settings.kick, settings.perfectTrade = false, false, false
    settings.intel, settings.intelTags = false, false
    pcall(function() if Intel.clearTags then Intel.clearTags() end end)
    pcall(function() RunService:UnbindFromRenderStep("CompIntel_TradeMove") end)
    for _, c in ipairs(connections) do
        if type(c) == "thread" then
            pcall(task.cancel, c)
        else
            pcall(function() c:Disconnect() end)
        end
    end
    if gui then pcall(function() local i = gui.Parent and gui.Parent:FindFirstChild("CompIntel_Intro"); if i then i:Destroy() end end) end
    if gui then gui:Destroy() end
end
if getgenv then getgenv().CompIntel_Cleanup = cleanup end

log("loaded (Intel edition) - Ctrl+H toggles the panel")