local M = {}

-- ===== Setup (runs once when this module is required by the launcher) =====

local script_path = debug.getinfo(1, "S").source:sub(2) -- strip leading '@'
local script_dir = script_path:match("(.*[/\\])") or "./"
-- wild.lua lives in modules/, and data/ is a SIBLING of modules/ (both
-- directly under the base folder) - "../?.lua" reaches up one level so
-- require("data.X") resolves correctly.
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Mem = require("data.memory")
Gui = require("gui_module")
PokemonNames = require("data.pokemon_names")
ItemNames = require("data.item_names")

local hud -- assigned in M.init()

local function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

local function get_item_name(id)
    return ItemNames[id] or ("Unknown Item #" .. tostring(id))
end

-- Routine, high-frequency trace prints go through this instead of print()
-- directly, so they can be silenced by default (they add real overhead
-- at high fast-forward speeds) and re-enabled via the GUI's "Verbose
-- Logging" checkbox when actually debugging something.
local function vprint(msg)
    if Gui.verbose_logging(hud) then
        print(msg)
    end
end

-- Checks a list of raw typed tokens (each could be a number like "69" or
-- a name like "Bellsprout") against the current species, matching on
-- either its numeric ID or its name (case-insensitive). nil tokens list
-- means no filter was set, so everything is allowed.
local function species_matches_filter(tokens, id, name)
    if tokens == nil then return true end
    local nameLower = name:lower()
    for _, token in ipairs(tokens) do
        local asNumber = tonumber(token)
        if asNumber ~= nil and asNumber == id then
            return true
        end
        if token:lower() == nameLower then
            return true
        end
    end
    return false
end

-- Sends a notification via a local relay (discord_relay.ps1 + start_relay.bat)
-- which forwards it to Discord. CONFIRMED via webhook.site testing that
-- comm.httpPost always wraps its payload as a URL-encoded form field named
-- "payload" (application/x-www-form-urlencoded) - this is fixed BizHawk
-- behavior on every version, not a bug, and Discord's webhook endpoint
-- will never accept that shape directly. The relay always runs on this
-- fixed local address, so it's a constant rather than a GUI field.
local DISCORD_RELAY_URL = "http://127.0.0.1:5000/"

local function send_discord_notification(message)
    if not Gui.discord_enabled(hud) then return end
    local safeMessage = message:gsub('"', '\\"')
    local payload = string.format('{"content": "%s"}', safeMessage)
    local ok, response = pcall(comm.httpPost, DISCORD_RELAY_URL, payload)
    if ok then
        print("Discord notification sent, response: " .. tostring(response))
    else
        print("Discord notification failed: " .. tostring(response))
    end
end

-- Stuck detection: tracks real-world time since the bot last made
-- genuine progress (a successful nudge cycle, or being actively engaged
-- in a battle) - NOT raw position, since a successful nudge cycle
-- deliberately returns to the exact same "home" tile every time by
-- design, which would make raw position look "unchanged" constantly
-- even when everything is working perfectly. If it's been
-- STUCK_THRESHOLD_SECONDS since the last progress signal, sends a
-- single Discord alert (not repeated every frame) until progress
-- happens again, at which point it resets and can fire again later.
local STUCK_THRESHOLD_SECONDS = 300
local lastProgressTime = nil
local stuckNotificationSent = false

local function mark_progress()
    lastProgressTime = os.time()
    stuckNotificationSent = false
end

local function check_stuck_and_notify()
    if lastProgressTime == nil then
        lastProgressTime = os.time()
        return
    end
    if not stuckNotificationSent and os.time() - lastProgressTime >= STUCK_THRESHOLD_SECONDS then
        stuckNotificationSent = true
        print(string.format("WARNING: no progress for %d+ seconds - potentially stuck", STUCK_THRESHOLD_SECONDS))
        send_discord_notification(string.format(
            "Potentially stuck: no movement or battle progress for over %d minutes.",
            math.floor(STUCK_THRESHOLD_SECONDS / 60)))
    end
end

-- ===== Persistent state (shared between M.init and M.step via closure) =====

local desired_species = -1
local atkdef
local spespc
local species
local item = 0
local shinyvalue = 0
-- Set true once per new battle (in the hook that only fires on a genuine
-- new encounter, not per turn). PP reads as stale for a couple of frames
-- right when a battle menu first loads - this ensures we only wait for
-- it to settle ONCE, on the actual first turn, not on every turn of an
-- ongoing multi-turn battle (where PP is already accurate from the start).
local pendingBattleSettle = false
local stopRequested = false
local stopReason = ""
-- Set true only by the ROM hook (a real, one-time confirmation that an
-- actual encounter started) - used so the DV-wait loop doesn't bail out
-- on a transient species_addr==0 blip during a real encounter's own
-- startup transition, while still catching genuinely spurious flickers
-- where no real battle ever started at all.
local realEncounterConfirmed = false
local pendingEncounterUpdate = false
local printedMessage = false
local enemy_addr
local LoadBattleMenuAddr
local EnemyWildmonInitialized

local mapgroup, mapnumber
local version, region
-- Deliberately NOT persisted - resets to 0 every launch, so it's always
-- unambiguous "encounters this session" vs the shared lifetime totals.
local sessionEncounterCount = 0

Stats = require("data.stats")

local highestSpeSpc = 0
local highestAtkDef = 0

-- $CFA9 (Y) / $CFAA (X) confirmed via multi-frame stability testing: both
-- read with ZERO flicker across 6 consecutive frames at every one of the
-- four menu positions, and the layout is 1-indexed (not 0-indexed):
--   FIGHT=(1,1)  PKMN=(1,2)
--   PACK =(2,1)  RUN =(2,2)
local MENU_CURSOR_Y = 0xCFA9
local MENU_CURSOR_X = 0xCFAA
local RUN_CURSOR = {y = 2, x = 2}

-- $C634: confirmed via WRAM diffing (before/after using the first move)
-- to be the in-battle PP counter for the first move slot. Lives in the
-- fixed WRAM bank ($C000-$CFFF), so no bank-switching concerns reading it.
local FIRST_MOVE_PP_ADDR = 0xC634
-- Verified via pokecrystal.sym symbol file: wBattleMonHP/wBattleMonMaxHP,
-- same fixed (non-bank-switched) region as FIRST_MOVE_PP_ADDR above.
local OWN_HP_ADDR = 0xC63C
local OWN_MAX_HP_ADDR = 0xC63E
-- Flee instead of attacking if HP drops below this fraction of max -
-- a safety margin above the game's own "red bar" threshold, so there's
-- room to actually flee before a possible next hit could faint us.
local LOW_HP_FLEE_THRESHOLD = 0.25

local dv_flag_addr, species_addr, item_addr

local function shiny(atkdef, spespc)
    -- IMPORTANT: reset every call, not just set on a hit - otherwise
    -- shinyvalue stays 1 forever after the first real shiny, silently
    -- flagging every subsequent encounter as shiny too.
    shinyvalue = 0
    if spespc == 0xAA then
        if atkdef == 0x2A or atkdef == 0x3A or atkdef == 0x6A or atkdef == 0x7A or atkdef == 0xAA or atkdef == 0xBA or atkdef == 0xEA or atkdef == 0xFA then
            shinyvalue = 1
            return true
        end
    end
    return false
end

-- Own Pokemon's HP can exceed 255 at higher levels, so this is a 16-bit
-- read, not a single byte like the PP check.
local function has_safe_hp()
    local currentHP = memory.read_u16_be(OWN_HP_ADDR)
    local maxHP = memory.read_u16_be(OWN_MAX_HP_ADDR)
    if maxHP == 0 then return true end -- avoid divide-by-zero if read too early
    return (currentHP / maxHP) > LOW_HP_FLEE_THRESHOLD
end

local function press_button(btn)
    local input = {[btn] = true}
    for i = 1, 4 do -- Hold button for 4 frames (make sure the game registers it)
        joypad.set(input)
        emu.frameadvance()
    end
    emu.frameadvance() -- Add one frame buffer so consecutive button presses don't blend together
end

-- $D4DD: confirmed via multi-frame WRAM diffing + a 5-step verification
-- test to be a real "movement in progress" flag. Idle value 0xFF; goes
-- busy the instant a step starts (observed 0-frame delay across every
-- test), returns to 0xFF right as the tile-step completes (~11-12 frames
-- later on flat ground). This replaces position-polling entirely - no
-- more guessing how many frames to wait.
local MOVEMENT_FLAG_ADDR = 0xD4DD
local MOVEMENT_IDLE_VALUE = 0xFF

-- Press `direction`, then use the flag to know exactly when the step
-- (if any) starts and finishes, rather than guessing frame counts.
-- Returns true only if the tile position actually changed - the flag
-- tells us WHEN to check, the position change tells us WHETHER it
-- counted as a real step (vs. a blocked bump against a wall/tree).
local function attempt_step(direction)
    local startX, startY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)

    for i = 1, 4 do
        joypad.set({[direction] = true})
        emu.frameadvance()
    end
    joypad.set({[direction] = false})

    local n = 0
    while memory.readbyte(MOVEMENT_FLAG_ADDR) == MOVEMENT_IDLE_VALUE and n < 20 do
        emu.frameadvance()
        n = n + 1
        if memory.readbyte(species_addr) ~= 0 then return true end
    end

    n = 0
    while memory.readbyte(MOVEMENT_FLAG_ADDR) ~= MOVEMENT_IDLE_VALUE and n < 90 do
        emu.frameadvance()
        n = n + 1
        if memory.readbyte(species_addr) ~= 0 then return true end
    end

    local endX, endY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
    return (endX ~= startX or endY ~= startY)
end

-- Only ever commits to a direction pair verified to be a true round trip
-- (step out, step back, land on the EXACT same tile) - guarantees zero
-- net drift WITHIN a single established pair's use. On its own this does
-- NOT stop the anchor itself from slowly relocating: whenever a pair
-- needs re-verifying (e.g., after a battle, or after a cycle fails the
-- round-trip check), find_safe_pair() used to just treat wherever the
-- character currently is as the new reference point - small shifts from
-- each re-verification compound over many encounters into real drift.
-- homeX/homeY fixes this: it's the one true anchor, set once per Start,
-- and do_nudge_cycle actively walks back to it before ever re-verifying
-- a pair, rather than settling for "wherever we happen to be now".
local safe_pair = nil
local homeX, homeY = nil, nil

-- Attempts one step closer to home. Returns true once actually there.
local function walk_toward_home()
    local curX, curY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
    if curX == homeX and curY == homeY then return true end

    if curX < homeX then
        attempt_step("Right")
    elseif curX > homeX then
        attempt_step("Left")
    elseif curY < homeY then
        attempt_step("Down")
    elseif curY > homeY then
        attempt_step("Up")
    end

    if memory.readbyte(species_addr) ~= 0 then return false end
    curX, curY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
    return (curX == homeX and curY == homeY)
end

local function find_safe_pair(verbose)
    local anchorX, anchorY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
    local candidates = {
        {out = "Right", back = "Left"},
        {out = "Left",  back = "Right"},
        {out = "Down",  back = "Up"},
        {out = "Up",    back = "Down"},
    }

    for _, pair in ipairs(candidates) do
        local movedOut = attempt_step(pair.out)
        if memory.readbyte(species_addr) ~= 0 then return nil end

        if movedOut then
            local movedBack = attempt_step(pair.back)
            if memory.readbyte(species_addr) ~= 0 then return nil end

            local nowX, nowY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
            if movedBack and nowX == anchorX and nowY == anchorY then
                vprint(string.format("Found safe zero-drift pair: %s / %s", pair.out, pair.back))
                return pair
            else
                if verbose then
                    print(string.format("%s/%s didn't return to anchor (now X=%d Y=%d, anchor was X=%d Y=%d) - trying next pair",
                        pair.out, pair.back, nowX, nowY, anchorX, anchorY))
                end
                anchorX, anchorY = nowX, nowY
            end
        else
            if verbose then
                print(string.format("%s blocked from this tile - skipping this pair", pair.out))
            end
        end
    end

    return nil
end

local cycles_since_print = 0
local failed_pair_attempts = 0
local consecutive_movement_failures = 0
local UNSTUCK_THRESHOLD = 100

-- If a phone call, sign, or any other unexpected text box pops up in the
-- overworld, our button presses stop producing real movement even though
-- the terrain itself is fine - this looks identical to any other stretch
-- of failed attempts from here, so rather than detecting each possible
-- interruption individually, we just notice "no real movement for a
-- long time despite believing we're free to move" and try to clear
-- whatever's blocking us generically.
local function try_unstuck()
    print(string.format("No real movement for %d cycles - possibly a phone call/sign/text box blocking input. Trying to clear it.", consecutive_movement_failures))
    -- B, never A: some phone calls (rematch challenges) end in a
    -- "battle now? Yes/No" prompt, and mashing A could accidentally
    -- CONFIRM a trainer battle - something this bot has zero ability to
    -- handle (completely different menus/addresses than wild encounters).
    -- B is the safe cancel/decline button used everywhere else in this
    -- script for exactly this reason.
    for i = 1, 10 do
        press_button("B")
        if memory.readbyte(species_addr) ~= 0 then break end
    end
    safe_pair = nil -- re-verify from scratch, position/context may have shifted
    consecutive_movement_failures = 0
end

local function do_nudge_cycle()
    local madeRealProgress = false

    if homeX == nil then
        homeX, homeY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
        vprint(string.format("Anchoring home tile at X=%d Y=%d", homeX, homeY))
    end

    if safe_pair == nil then
        local curX, curY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
        if curX ~= homeX or curY ~= homeY then
            local reachedHome = walk_toward_home()
            if memory.readbyte(species_addr) ~= 0 then return end
            madeRealProgress = true -- getting closer to home is real progress, not a stall
            if not reachedHome then
                return
            end
        end

        -- This can fail repeatedly right before a wild encounter actually
        -- triggers (the game appears to briefly lock out new movement
        -- input during that transition) - print full detail occasionally
        -- rather than on every single cycle to avoid spamming the console.
        local verbose = Gui.verbose_logging(hud) and (failed_pair_attempts % 20 == 0)
        safe_pair = find_safe_pair(verbose)
        if safe_pair == nil and memory.readbyte(species_addr) == 0 then
            failed_pair_attempts = failed_pair_attempts + 1
            if verbose then
                print("No safe zero-drift pair found yet - will retry next cycle")
            end
        else
            madeRealProgress = (safe_pair ~= nil)
        end
    else
        local startX, startY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
        local movedOut = attempt_step(safe_pair.out)
        if memory.readbyte(species_addr) ~= 0 then return end
        local movedBack = attempt_step(safe_pair.back)
        if memory.readbyte(species_addr) ~= 0 then return end

        local endX, endY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
        local trulyReturned = (endX == startX and endY == startY)
        madeRealProgress = movedOut and movedBack and trulyReturned

        if movedOut and movedBack and not trulyReturned then
            print(string.format(
                "WARNING: established pair (%s/%s) didn't return to start (was X=%d Y=%d, now X=%d Y=%d) - re-verifying a fresh pair",
                safe_pair.out, safe_pair.back, startX, startY, endX, endY))
            safe_pair = nil
        end

        cycles_since_print = cycles_since_print + 1
        if cycles_since_print >= 20 then
            cycles_since_print = 0
            local x, y = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
            vprint(string.format("Still nudging (%s/%s) at X=%d Y=%d", safe_pair and safe_pair.out or "?", safe_pair and safe_pair.back or "?", x, y))
        end
    end

    if madeRealProgress then
        consecutive_movement_failures = 0
    else
        consecutive_movement_failures = consecutive_movement_failures + 1
        if consecutive_movement_failures >= UNSTUCK_THRESHOLD then
            try_unstuck()
        end
    end
end

-- Compute the single correct next input to move the battle-menu cursor
-- toward `target` ({y=.., x=..}), based on the ACTUAL current cursor
-- position, never on an assumed sequence.
local function navigate_to_menu_option(target)
    local cy = memory.readbyte(MENU_CURSOR_Y)
    local cx = memory.readbyte(MENU_CURSOR_X)

    if cy == target.y and cx == target.x then
        return "A"
    elseif cy < target.y then
        return "Down"
    elseif cy > target.y then
        return "Up"
    elseif cx < target.x then
        return "Right"
    else
        return "Left"
    end
end

-- Press a button, then wait until the cursor actually moves (or we time out).
-- Self-correcting: if a press is dropped or lag delays it, we just
-- re-evaluate from wherever we actually ended up.
local function press_and_wait_for_cursor_change(btn, timeout)
    local prevY = memory.readbyte(MENU_CURSOR_Y)
    local prevX = memory.readbyte(MENU_CURSOR_X)
    press_button(btn)
    local n = 0
    while memory.readbyte(MENU_CURSOR_Y) == prevY
      and memory.readbyte(MENU_CURSOR_X) == prevX
      and n < timeout
      and memory.readbyte(species_addr) ~= 0 do
        emu.frameadvance()
        n = n + 1
    end
end

local have_battle_controls = false

-- Navigate to FIGHT and use whichever move is already highlighted by
-- default (the first move in the list) - no move-submenu navigation
-- needed, since "kill non-shiny" always wants the first attack.
local FIGHT_CURSOR = {y = 1, x = 1}

local function do_kill_turn()
    local nav_attempts = 0
    while have_battle_controls and memory.readbyte(species_addr) ~= 0 do
        local cy = memory.readbyte(MENU_CURSOR_Y)
        local cx = memory.readbyte(MENU_CURSOR_X)

        if cy == FIGHT_CURSOR.y and cx == FIGHT_CURSOR.x then
            vprint("Pressing A to select FIGHT")
            press_button("A")
            break
        else
            nav_attempts = nav_attempts + 1
            if nav_attempts > 12 then
                print("Kill-mode navigation stuck after 12 attempts - backing out with B")
                press_button("B")
                return
            end
            local next_input = navigate_to_menu_option(FIGHT_CURSOR)
            press_and_wait_for_cursor_change(next_input, 30)
        end
    end

    if memory.readbyte(species_addr) == 0 then return end

    for i = 1, 15 do
        emu.frameadvance()
        if memory.readbyte(species_addr) == 0 then return end
    end
    vprint("Pressing A to use first move")
    press_button("A")

    -- IMPORTANT: use A here, not B. This window includes the post-faint
    -- sequence (EXP gain, level up, evolution) if the enemy fainted, and
    -- pressing B during the evolution sparkle animation is the actual
    -- in-game way to CANCEL an evolution mid-way through. A advances the
    -- same text/menus without that side effect.
    --
    -- TIMEOUT: a "would you like to learn a new move?" or evolution
    -- prompt doesn't re-trigger the battle-menu hook this loop is
    -- waiting on, so without a limit here it can loop forever - which is
    -- exactly what was preventing Stop from working (step() never
    -- returns control to the launcher while stuck in an internal loop).
    -- If we hit this, signal the caller to stop the bot entirely rather
    -- than guess how to navigate a prompt we can't reliably detect.
    have_battle_controls = false
    local postAttackWait = 0
    while not have_battle_controls and memory.readbyte(species_addr) ~= 0 do
        emu.frameadvance()
        press_button("A")
        postAttackWait = postAttackWait + 1
        if postAttackWait > 600 then
            print("Stuck after attacking for 600+ frames (likely a move-learn or evolution prompt) - stopping so you can handle it manually")
            return "stuck"
        end
    end
end

local overworld_loaded = false
local overworld_settle_frames = 0
local REQUIRED_SETTLE_FRAMES = 10 -- consecutive frames of species_addr==0 before we trust we're truly back

-- Top-level watchdog: tracks real elapsed frames since the player's tile
-- position last actually changed, completely independent of which
-- internal branch/state we're currently in.
local WATCHDOG_FRAMES = 1800
local watchdogLastX, watchdogLastY
local watchdogLastMoveFrame

local function watchdog_force_unstuck()
    print(string.format("WATCHDOG: no position change for %d+ frames (~30s) regardless of internal state - forcing recovery", WATCHDOG_FRAMES))
    for i = 1, 30 do
        press_button("B")
    end
    safe_pair = nil
    overworld_settle_frames = 0
    overworld_loaded = false
    realEncounterConfirmed = false
    watchdogLastMoveFrame = emu.framecount()
end

-- Hooks get REPLACED by name every time RegisterROMHook runs (confirmed
-- from data/memory.lua's own event.unregisterbyname call) - so whichever
-- module registered LAST keeps its hooks active, even after switching to
-- a "different" module, unless that module re-registers its own. This
-- must be called every time this module becomes active, not just once.
local function register_hooks()
    Mem.RegisterROMHook(LoadBattleMenuAddr, function()
        if ActiveModuleName ~= "wild" then return end
        have_battle_controls = true
        vprint(string.format("Battle menu loaded | Cursor Y=%d X=%d",
            memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))
    end, "Detect Battle Menu")

    Mem.RegisterROMHook(EnemyWildmonInitialized, function()
        if ActiveModuleName ~= "wild" then return end
        realEncounterConfirmed = true
        pendingBattleSettle = true
        vprint("combat started")
        item = memory.readbyte(item_addr)
        atkdef = memory.readbyte(enemy_addr)
        spespc = memory.readbyte(enemy_addr + 1)
        highestAtkDef = math.max(highestAtkDef, atkdef)
        highestSpeSpc = math.max(highestSpeSpc, spespc)
        species = memory.readbyte(species_addr)
        shiny(atkdef, spespc) -- sets shinyvalue as a side effect if applicable

        local speciesName = get_pokemon_name(species)
        local itemName = get_item_name(item)
        print(string.format("%s (#%d) | Atk: %d Def: %d Spe: %d Spc: %d | Item: %s",
            speciesName, species, math.floor(atkdef/16), atkdef%16, math.floor(spespc/16), spespc%16, itemName))

        sessionEncounterCount = sessionEncounterCount + 1

        -- IMPORTANT: this hook fires as a ROM-hook callback, and we've
        -- confirmed BizHawk restricts what's allowed inside callbacks
        -- (emu.frameadvance throws outright; forms.drawText/drawRectangle
        -- calls made from here appear to silently not flush to screen).
        -- So we only record raw data here and let M.step() - running in
        -- the main loop, a confirmed-safe context - do all the actual
        -- GUI updates, stop-condition checks, and Discord notification.
        pendingEncounterUpdate = true
    end, "Tell Display Battle Started / sending data")
end

-- ===== M.init: runs ONCE, sets everything up =====
-- sharedForm: the launcher's persistent window handle.
-- yOffset: vertical position to start building this mode's UI at, so it
-- sits below whatever the launcher put at the top of the window.
-- Returns true on success, false if this ROM/version isn't supported.
function M.init(sharedForm, yOffset, existingHud)
    -- comm.httpPost has no default timeout, meaning if the Discord
    -- relay isn't actually listening, the call can hang indefinitely
    -- with no error - freezing the whole bot silently. 3 seconds is
    -- generous for a localhost request but bounds the wait.
    -- Wrapped in pcall: BizHawk keeps one persistent HttpClient for
    -- its whole process lifetime, and .NET only allows setting Timeout
    -- BEFORE the first request is ever sent on that client. Once any
    -- Discord notification has been sent, later script restarts (same
    -- BizHawk session) would hard-crash here without this pcall, since
    -- a request has already started. Safe to ignore failure - the
    -- timeout is already set from whenever it first succeeded.
    pcall(function() comm.httpSetTimeout(3000) end)

    Stats.load()

    mapgroup, mapnumber = memory.readbyte(0xdcb5), memory.readbyte(0xdcb6)
    version = memory.readbyte(0x141)
    region = memory.readbyte(0x142)

    hud = existingHud
    Gui.reconfigure(hud, {"chkTrueRandomness"}) -- wild uses every encounter-related field; True Randomness only applies to soft-reset modules

    if version == 0x54 then
        if region == 0x44 or region == 0x46 or region == 0x49 or region == 0x53 then
            enemy_addr = 0xd20c
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            Mem.SetRomBankAddress("Crystal")
        elseif region == 0x45 then
            enemy_addr = 0xd20c
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            Mem.SetRomBankAddress("Crystal")
        elseif region == 0x4A then
            enemy_addr = 0xd23d
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            Mem.SetRomBankAddress("Crystal")
        end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x44 or region == 0x46 or region == 0x49 or region == 0x53 then
            print("EUR Gold/Silver detected")
            enemy_addr = 0xda22
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x73c5)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x45 then
            print("USA Gold/Silver detected")
            enemy_addr = 0xda22
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x73C5)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4A then
            print("JPN Gold/Silver detected")
            enemy_addr = 0xd9e8
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x73C5)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4B then
            print("KOR Gold/Silver detected")
            enemy_addr = 0xdb1f
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x73C5)
            Mem.SetRomBankAddress("Gold")
        end
    else
        print("No valid ROM detected")
        return false
    end

    dv_flag_addr = enemy_addr + 0x21
    species_addr = enemy_addr + 0x22
    item_addr = enemy_addr - 0x05

    watchdogLastX, watchdogLastY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
    watchdogLastMoveFrame = emu.framecount()

    register_hooks()

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Settling into overworld...")
    return true
end

-- ===== M.step: called once per frame by the launcher's own loop =====
-- The launcher has ALREADY called emu.frameadvance() before this.
-- Returns true when this mode is done (shiny found / stop condition met)
-- so the launcher knows to stop calling step() and reset its UI to idle.
-- Returns false/nil to mean "keep going, call me again next frame".
-- Called by the launcher every time Start is clicked, even if this module
-- was already loaded and running before. Forces a fresh anchor point for
-- wherever the character actually is right now - handles being manually
-- moved to a different spot/map while stopped, which step() would
-- otherwise have no way to notice (it simply isn't called while stopped).
-- Called every time this module becomes the active one, whether for the
-- first time or returning to it after a different module ran. Distinct
-- from on_resume, which is specifically about the Start button.
function M.on_switch_to()
    register_hooks()
    Gui.reconfigure(hud, {"chkTrueRandomness"})
    Gui.clear_last_encounter(hud)
end

function M.on_resume()
    safe_pair = nil
    homeX, homeY = nil, nil
    overworld_settle_frames = 0
    overworld_loaded = false
    lastProgressTime = nil
    stuckNotificationSent = false
    stopRequested = false
    stopReason = ""
end

function M.step()
    check_stuck_and_notify()

    if pendingEncounterUpdate then
        pendingEncounterUpdate = false

        local speciesName = get_pokemon_name(species)
        local itemName = get_item_name(item)
        local atkDV = math.floor(atkdef / 16)
        local defDV = atkdef % 16
        local speDV = math.floor(spespc / 16)
        local spcDV = spespc % 16
        local isShinyEncounter = (shinyvalue == 1)
        Stats.record_encounter()

        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Checking encounter...")
        Gui.update_last_encounter(hud, sessionEncounterCount, species, speciesName, atkDV, defDV, speDV, spcDV, isShinyEncounter, itemName)

        if isShinyEncounter then
            Stats.record_shiny()
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "SHINY FOUND!")
            send_discord_notification(string.format(
                "Shiny found! %s (#%d) (Atk:%d Def:%d Spe:%d Spc:%d) holding %s",
                speciesName, species, atkDV, defDV, speDV, spcDV, itemName))
        end

        local isPerfect = (atkDV == 15 and defDV == 15 and speDV == 15 and spcDV == 15)
        local isPerfectNegative = (atkDV == 0 and defDV == 0 and speDV == 0 and spcDV == 0)
        local speciesStopEnabled, speciesTarget = Gui.stop_on_species(hud)
        local itemStopEnabled, itemFilterTokens = Gui.stop_on_item(hud)
        local itemMatches = item ~= 0 and species_matches_filter(itemFilterTokens, item, itemName)

        if Gui.stop_on_perfect(hud) and isPerfect then
            stopRequested = true
            stopReason = "Perfect DVs (15/15/15/15) found!"
        elseif Gui.stop_on_perfect_negative(hud) and isPerfectNegative then
            stopRequested = true
            stopReason = "Perfect Negative DVs (0/0/0/0) found!"
        elseif speciesStopEnabled and species == speciesTarget then
            stopRequested = true
            stopReason = string.format("Target species %s (#%d) found!", speciesName, speciesTarget)
        elseif itemStopEnabled and itemMatches then
            stopRequested = true
            stopReason = string.format("Held item %s found!", itemName)
        end

        if stopRequested then
            print(stopReason)
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, stopReason)
            send_discord_notification(string.format(
                "%s %s (#%d) (Atk:%d Def:%d Spe:%d Spc:%d)",
                stopReason, speciesName, species, atkDV, defDV, speDV, spcDV))
        end

    end

    local rawSpecies = memory.readbyte(species_addr)

    -- The watchdog only makes sense in the overworld - position is
    -- SUPPOSED to stay constant during a battle. While in battle, just
    -- keep refreshing the clock so it starts fresh once we're actually
    -- back in the overworld.
    if rawSpecies ~= 0 then
        watchdogLastX, watchdogLastY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
        watchdogLastMoveFrame = emu.framecount()
    else
        local watchdogX, watchdogY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
        if watchdogX ~= watchdogLastX or watchdogY ~= watchdogLastY then
            watchdogLastX, watchdogLastY = watchdogX, watchdogY
            watchdogLastMoveFrame = emu.framecount()
        elseif emu.framecount() - watchdogLastMoveFrame >= WATCHDOG_FRAMES then
            watchdog_force_unstuck()
        end
    end

    if rawSpecies == 0 then
        have_battle_controls = false
        overworld_settle_frames = overworld_settle_frames + 1
        if overworld_settle_frames >= REQUIRED_SETTLE_FRAMES then
            if not overworld_loaded then
                vprint("Overworld loaded - movement enabled")
                -- Force a fresh safe-pair verification for wherever we
                -- actually are now - handles being manually moved to a
                -- different spot/map while the bot was stopped, and any
                -- residual drift from the encounter that just ended.
                safe_pair = nil
            end
            overworld_loaded = true
        end
    else
        overworld_settle_frames = 0
        overworld_loaded = false
    end

    if not overworld_loaded then
        if rawSpecies == 0 then
            joypad.set({B = true})
        end
    end

    if overworld_loaded then
        if do_nudge_cycle() then
            mark_progress()
        end
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Searching for encounters...")

    elseif memory.readbyte(species_addr) ~= 0 then
        mark_progress()
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "In battle...")

        local dvWaitFrames = 0
        while memory.readbyte(dv_flag_addr) ~= 0x01 and dvWaitFrames < 120 do
            if memory.readbyte(species_addr) == 0 and not realEncounterConfirmed then
                break
            end
            emu.frameadvance()
            press_button("B")
            dvWaitFrames = dvWaitFrames + 1
        end

        if memory.readbyte(dv_flag_addr) ~= 0x01 then
            if realEncounterConfirmed then
                print("DV-wait: timed out after " .. dvWaitFrames .. " frames waiting for dv_flag_addr despite a confirmed encounter - backing off")
            end
            realEncounterConfirmed = false
            goto continue
        end

        realEncounterConfirmed = false

        if shinyvalue == 1 then
            print("Shiny found!!")
            return true
        end

        if stopRequested then
            return true
        end

        if memory.readbyte(species_addr) ~= 0 then
            while not have_battle_controls and memory.readbyte(species_addr) ~= 0 do
                emu.frameadvance()
                press_button("B")
            end

            -- PP reads as stale for a couple of frames immediately after
            -- a NEW battle's menu first loads, before settling to its
            -- real value. Only wait for this ONCE per battle
            -- (pendingBattleSettle only gets set true on a genuine new
            -- encounter). Note: species_addr can transiently flicker to
            -- 0 for a single frame right at battle start before settling
            -- to its real nonzero value, so this wait does NOT bail out
            -- early on that check the way other loops do - a flicker
            -- there previously cut this wait short after just 1 frame.
            if pendingBattleSettle then
                pendingBattleSettle = false
                for i = 1, 30 do
                    emu.frameadvance()
                end
            end

            local killFilterTokens = Gui.kill_species_filter(hud)
            local killAllowedForThisSpecies = species_matches_filter(killFilterTokens, species, get_pokemon_name(species))
            local hasPP = memory.readbyte(FIRST_MOVE_PP_ADDR) > 0
            local hpSafe = has_safe_hp()

            if Gui.kill_non_shiny(hud) and killAllowedForThisSpecies and hasPP and hpSafe then
                Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Attacking...")
                local killResult = do_kill_turn()
                if killResult == "stuck" then
                    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount,
                        "Stopped - move-learn or evolution prompt needs your input")
                    return true
                end
            else
                Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Fleeing battle...")

                -- Running from a wild battle in Gen 2 isn't guaranteed to
                -- succeed - there's a chance-based escape formula, and a
                -- failed attempt shows "Can't escape!" while the battle
                -- continues (the enemy gets a turn). Selecting RUN and
                -- pressing A only confirms we ATTEMPTED to flee, not that
                -- it worked - so retry the whole sequence if the first
                -- attempt's exit-wait times out, rather than assuming
                -- success and getting stuck.
                local escapeAttempts = 0
                local fledSuccessfully = false
                while not fledSuccessfully and escapeAttempts < 5 and memory.readbyte(species_addr) ~= 0 do
                    escapeAttempts = escapeAttempts + 1

                    -- Wait for have_battle_controls to become true
                    -- again before retrying - it gets set false at the
                    -- end of every attempt (success or failure), so
                    -- without this, attempts 2+ found the nav loop's
                    -- condition already false and skipped it entirely,
                    -- silently doing nothing for the rest of the
                    -- "attempts".
                    while not have_battle_controls and memory.readbyte(species_addr) ~= 0 do
                        emu.frameadvance()
                        press_button("B")
                    end

                    local nav_attempts = 0
                    local ran_away = false
                    while have_battle_controls and memory.readbyte(species_addr) ~= 0 do
                        local cy = memory.readbyte(MENU_CURSOR_Y)
                        local cx = memory.readbyte(MENU_CURSOR_X)

                        if cy == RUN_CURSOR.y and cx == RUN_CURSOR.x then
                            vprint(string.format("Pressing A to select RUN (Y=%d X=%d)", cy, cx))
                            press_button("A")
                            ran_away = true
                            break
                        else
                            nav_attempts = nav_attempts + 1
                            if nav_attempts > 12 then
                                vprint("Navigation stuck after 12 attempts - backing out with B and stopping this attempt")
                                press_button("B")
                                break
                            end
                            local next_input = navigate_to_menu_option(RUN_CURSOR)
                            vprint(string.format("Y=%d X=%d -> pressing %s", cy, cx, next_input))
                            press_and_wait_for_cursor_change(next_input, 30)
                            local ny, nx = memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)
                            if ny == cy and nx == cx then
                                vprint(string.format("  no change after %s (still Y=%d X=%d) - possible timeout", next_input, ny, nx))
                            end
                        end
                    end

                    if ran_away then
                        vprint(string.format("Ran away (attempt %d) - clearing exit text until battle actually ends", escapeAttempts))
                        local exitWaitFrames = 0
                        while memory.readbyte(species_addr) ~= 0 and exitWaitFrames < 180 do
                            emu.frameadvance()
                            press_button("B")
                            exitWaitFrames = exitWaitFrames + 1
                        end
                        if memory.readbyte(species_addr) == 0 then
                            fledSuccessfully = true
                            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Escaped, wrapping up...")
                        else
                            vprint(string.format("Escape attempt %d timed out (Can't escape!, most likely) - retrying", escapeAttempts))
                        end
                        have_battle_controls = false
                    end
                end

                if not fledSuccessfully and memory.readbyte(species_addr) ~= 0 then
                    print(string.format("WARNING: could not escape after %d attempts - continuing anyway", escapeAttempts))
                end
            end
        end
    end

    ::continue::
    return false
end

return M
