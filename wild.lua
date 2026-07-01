local script_path = debug.getinfo(1, "S").source:sub(2) -- strip leading '@'
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path

Mem = require("data.Memory")
Gui = require("gui_module")
PokemonNames = require("pokemon_names")
ItemNames = require("item_names")
local hud = Gui.create("Shiny Hunt - Wild")

function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

function get_item_name(id)
    return ItemNames[id] or ("Unknown Item #" .. tostring(id))
end

-- Checks a list of raw typed tokens (each could be a number like "69" or
-- a name like "Bellsprout") against the current species, matching on
-- either its numeric ID or its name (case-insensitive). nil tokens list
-- means no filter was set, so everything is allowed.
function species_matches_filter(tokens, id, name)
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

function send_discord_notification(message)
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

local desired_species = -1
local atkdef
local spespc
local species
local item = 0
local shinyvalue = 0
local stopRequested = false
local stopReason = ""
-- Set true only by the ROM hook (a real, one-time confirmation that an
-- actual encounter started) - used so the DV-wait loop doesn't bail out
-- on a transient species_addr==0 blip during a real encounter's own
-- startup transition, while still catching genuinely spurious flickers
-- where no real battle ever started at all.
local realEncounterConfirmed = false
local printedMessage = false
local enemy_addr
local daytime
local LoadBattleMenuAddr
local EnemyWildmonInitialized

initialX, initialY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
mapgroup, mapnumber = memory.readbyte(0xdcb5), memory.readbyte(0xdcb6)
local version = memory.readbyte(0x141)
local region = memory.readbyte(0x142)
local encounterCount = 0
local shinyCount = 0
local highestSpeSpc = 0
local highestAtkDef = 0

-- $CFA9 (Y) / $CFAA (X) confirmed via multi-frame stability testing: both
-- read with ZERO flicker across 6 consecutive frames at every one of the
-- four menu positions, and the layout is 1-indexed (not 0-indexed):
--   FIGHT=(1,1)  PKMN=(1,2)
--   PACK =(2,1)  RUN =(2,2)
-- (The earlier CFAC tile-ID approach was dropped: it was stable within a
-- single battle but its actual value shifted between battles, since it
-- reflects whatever background tile happened to be loaded in VRAM that
-- session rather than a fixed logical menu state.)
local MENU_CURSOR_Y = 0xCFA9
local MENU_CURSOR_X = 0xCFAA
local RUN_CURSOR = {y = 2, x = 2}

-- $C634: confirmed via WRAM diffing (before/after using the first move)
-- to be the in-battle PP counter for the first move slot. Lives in the
-- fixed WRAM bank ($C000-$CFFF), so no bank-switching concerns reading it.
local FIRST_MOVE_PP_ADDR = 0xC634

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
    return
end

local dv_flag_addr = enemy_addr + 0x21
local species_addr = enemy_addr + 0x22
local item_addr = enemy_addr - 0x05
local daytime_addr = 0xd269

function shiny(atkdef, spespc)
    if spespc == 0xAA then
        if atkdef == 0x2A or atkdef == 0x3A or atkdef == 0x6A or atkdef == 0x7A or atkdef == 0xAA or atkdef == 0xBA or atkdef == 0xEA or atkdef == 0xFA then
            shinyvalue = 1
            return true
        end
    end
    return false
end

function press_button(btn)
    input = {[btn] = true}
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
function attempt_step(direction)
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
-- net drift over time, no matter how long the bot runs.
local safe_pair = nil

function find_safe_pair(verbose)
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
                print(string.format("Found safe zero-drift pair: %s / %s", pair.out, pair.back))
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
function try_unstuck()
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

function do_nudge_cycle()
    local madeRealProgress = false

    if safe_pair == nil then
        -- This can fail repeatedly right before a wild encounter actually
        -- triggers (the game appears to briefly lock out new movement
        -- input during that transition) - print full detail occasionally
        -- rather than on every single cycle to avoid spamming the console.
        local verbose = (failed_pair_attempts % 20 == 0)
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
        local movedOut = attempt_step(safe_pair.out)
        if memory.readbyte(species_addr) ~= 0 then return end
        local movedBack = attempt_step(safe_pair.back)
        madeRealProgress = movedOut and movedBack

        cycles_since_print = cycles_since_print + 1
        if cycles_since_print >= 20 then
            cycles_since_print = 0
            local x, y = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
            print(string.format("Still nudging (%s/%s) at X=%d Y=%d", safe_pair.out, safe_pair.back, x, y))
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
function navigate_to_menu_option(target)
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
function press_and_wait_for_cursor_change(btn, timeout)
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
-- NOTE: unlike RUN_CURSOR, the "submenu opened, wait, then press A" timing
-- here is a frame-count guess, not yet RAM-verified the way the main menu
-- cursor was. If this misbehaves (wrong move selected, or menu skipped),
-- treat it the same way we diagnosed the RUN bug: watch the actual cursor
-- value during this window and adjust.
local FIGHT_CURSOR = {y = 1, x = 1}

function do_kill_turn()
    local nav_attempts = 0
    while have_battle_controls and memory.readbyte(species_addr) ~= 0 do
        local cy = memory.readbyte(MENU_CURSOR_Y)
        local cx = memory.readbyte(MENU_CURSOR_X)

        if cy == FIGHT_CURSOR.y and cx == FIGHT_CURSOR.x then
            print("Pressing A to select FIGHT")
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

    -- Give the move-select submenu a moment to actually render before
    -- confirming the (already highlighted) first move.
    for i = 1, 15 do
        emu.frameadvance()
        if memory.readbyte(species_addr) == 0 then return end
    end
    print("Pressing A to use first move")
    press_button("A")

    -- Wait out the attack animation/text and let the turn resolve, then
    -- wait for the next turn's menu (or battle end) before returning -
    -- the outer loop will call this again next turn if still ongoing.
    -- IMPORTANT: use A here, not B. This window includes the post-faint
    -- sequence (EXP gain, level up, evolution) if the enemy fainted, and
    -- pressing B during the evolution sparkle animation is the actual
    -- in-game way to CANCEL an evolution mid-way through. A advances the
    -- same text/menus without that side effect.
    have_battle_controls = false
    while not have_battle_controls and memory.readbyte(species_addr) ~= 0 do
        emu.frameadvance()
        press_button("A")
    end
end

Mem.RegisterROMHook(LoadBattleMenuAddr, function()
    have_battle_controls = true
    print(string.format("Battle menu loaded | Cursor Y=%d X=%d",
        memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))
end, "Detect Battle Menu")

Mem.RegisterROMHook(EnemyWildmonInitialized, function()
    realEncounterConfirmed = true
    print("combat started")
    item = memory.readbyte(item_addr)
    local itemName = get_item_name(item)
    atkdef = memory.readbyte(enemy_addr)
    spespc = memory.readbyte(enemy_addr + 1)
    highestAtkDef = math.max(highestAtkDef, atkdef)
    highestSpeSpc = math.max(highestSpeSpc, spespc)
    species = memory.readbyte(species_addr)
    local speciesName = get_pokemon_name(species)
    print(string.format("%s (#%d) | Atk: %d Def: %d Spe: %d Spc: %d | Item: %s",
        speciesName, species, math.floor(atkdef/16), atkdef%16, math.floor(spespc/16), spespc%16, itemName))

    encounterCount = encounterCount + 1
    local atkDV = math.floor(atkdef / 16)
    local defDV = atkdef % 16
    local speDV = math.floor(spespc / 16)
    local spcDV = spespc % 16
    local isShinyEncounter = shiny(atkdef, spespc)

    Gui.update_counts(hud, encounterCount, shinyCount, "Checking encounter...")
    Gui.update_last_encounter(hud, encounterCount, species, speciesName, atkDV, defDV, speDV, spcDV, isShinyEncounter, itemName)

    if isShinyEncounter then
        shinyCount = shinyCount + 1
        Gui.update_counts(hud, encounterCount, shinyCount, "SHINY FOUND!")
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
        Gui.update_counts(hud, encounterCount, shinyCount, stopReason)
        send_discord_notification(string.format(
            "%s %s (#%d) (Atk:%d Def:%d Spe:%d Spc:%d)",
            stopReason, speciesName, species, atkDV, defDV, speDV, spcDV))
    end
end, "Tell Display Battle Started / sending data")

local overworld_loaded = false
local overworld_settle_frames = 0
local REQUIRED_SETTLE_FRAMES = 10 -- consecutive frames of species_addr==0 before we trust we're truly back

-- Top-level watchdog: tracks real elapsed frames since the player's tile
-- position last actually changed, completely independent of which
-- internal branch/state we're currently in. This is deliberately NOT
-- tied to do_nudge_cycle()'s own failure counter, because some stalls
-- (e.g. an egg hatching, or any other cutscene that leaves species_addr
-- reading nonzero) never reach that function at all - they can bounce
-- between the "settling" and "DV-wait" branches forever without ever
-- getting to the overworld movement logic where that counter lives.
-- ~60 fps on GBC, so 30 seconds is roughly 1800 frames.
local WATCHDOG_FRAMES = 1800
local watchdogLastX, watchdogLastY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
local watchdogLastMoveFrame = emu.framecount()

function watchdog_force_unstuck()
    print(string.format("WATCHDOG: no position change for %d+ frames (~30s) regardless of internal state - forcing recovery", WATCHDOG_FRAMES))
    for i = 1, 30 do
        press_button("B")
    end
    -- Reset every piece of state that could be holding us in a bad loop,
    -- so whatever runs next re-evaluates everything from scratch.
    safe_pair = nil
    overworld_settle_frames = 0
    overworld_loaded = false
    realEncounterConfirmed = false
    watchdogLastMoveFrame = emu.framecount()
end

Gui.update_counts(hud, encounterCount, shinyCount, "Settling into overworld...")

while true do
    emu.frameadvance()

    local rawSpecies = memory.readbyte(species_addr)

    -- The watchdog only makes sense in the overworld - position is
    -- SUPPOSED to stay constant during a battle (you don't walk around
    -- while fighting), so a long fight or a slow evolution animation
    -- would otherwise look identical to "stuck" and get force-cleared
    -- mid-animation. While in battle, just keep refreshing the clock so
    -- it starts fresh the moment we're actually back in the overworld.
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
                print("Overworld loaded - movement enabled")
            end
            overworld_loaded = true
        end
    else
        overworld_settle_frames = 0
        overworld_loaded = false
    end

    if not overworld_loaded then
        if rawSpecies == 0 then
            -- Still settling into the overworld: just clear any lingering
            -- text/transition prompts, don't attempt to move yet.
            joypad.set({B = true})
        end
    end

    if overworld_loaded then

        local currentX, currentY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)

        if (currentX ~= initialX or currentY ~= initialY) and memory.readbyte(species_addr) == 0 then
            -- Navigate back to initial position
            local deltaX = initialX - currentX
            local deltaY = initialY - currentY

            for _ = 1, math.abs(deltaX) do
                emu.frameadvance()
                joypad.set({Up = false, Right = (deltaX > 0), Down = false, Left = (deltaX < 0)})
                emu.frameadvance()
                if memory.readbyte(species_addr) ~= 0 then
                    emu.frameadvance()
                    break
                end
            end

            for _ = 1, math.abs(deltaY) do
                emu.frameadvance()
                joypad.set({Up = (deltaY < 0), Right = false, Down = (deltaY > 0), Left = false})
                emu.frameadvance()
                if memory.readbyte(species_addr) ~= 0 then
                    emu.frameadvance()
                    break
                end
            end
        else
            do_nudge_cycle()
            Gui.update_counts(hud, encounterCount, shinyCount, "Searching for encounters...")
        end

    elseif memory.readbyte(species_addr) ~= 0 then
        local dvWaitFrames = 0
        while memory.readbyte(dv_flag_addr) ~= 0x01 and dvWaitFrames < 120 do
            if memory.readbyte(species_addr) == 0 and not realEncounterConfirmed then
                -- Never saw the hook fire for this - genuinely spurious,
                -- bail immediately rather than waiting out the timeout.
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
            -- (The "no real encounter confirmed" case is routine - species_addr
            -- commonly blips for one stray frame during the battle-exit
            -- handoff back to the overworld. The recovery below still runs
            -- every time, it's just not worth printing anymore.)
            realEncounterConfirmed = false
            goto continue
        end

        realEncounterConfirmed = false

        if shinyvalue == 1 then
            print("Shiny found!!")
            break
        end

        if stopRequested then
            break
        end

        if memory.readbyte(species_addr) ~= 0 then
            -- Wait for the battle menu to actually be up before touching it
            while not have_battle_controls and memory.readbyte(species_addr) ~= 0 do
                emu.frameadvance()
                press_button("B")
            end

            local killFilterTokens = Gui.kill_species_filter(hud)
            local killAllowedForThisSpecies = species_matches_filter(killFilterTokens, species, get_pokemon_name(species))
            local hasPP = memory.readbyte(FIRST_MOVE_PP_ADDR) > 0

            if Gui.kill_non_shiny(hud) and killAllowedForThisSpecies and hasPP then
                Gui.update_counts(hud, encounterCount, shinyCount, "Attacking...")
                do_kill_turn()
            else
                if Gui.kill_non_shiny(hud) and killAllowedForThisSpecies and not hasPP then
                    print("First move has 0 PP - fleeing instead of attacking")
                end
            -- Cursor-verified navigation to RUN, using the confirmed
            -- 1-indexed grid: FIGHT=(1,1) PKMN=(1,2) PACK=(2,1) RUN=(2,2)
            local nav_attempts = 0
            local ran_away = false
            while have_battle_controls and memory.readbyte(species_addr) ~= 0 do
                local cy = memory.readbyte(MENU_CURSOR_Y)
                local cx = memory.readbyte(MENU_CURSOR_X)

                if cy == RUN_CURSOR.y and cx == RUN_CURSOR.x then
                    print(string.format("Pressing A to select RUN (Y=%d X=%d)", cy, cx))
                    press_button("A")
                    ran_away = true
                    break
                else
                    nav_attempts = nav_attempts + 1
                    if nav_attempts > 12 then
                        print("Navigation stuck after 12 attempts - backing out with B and stopping this attempt")
                        press_button("B")
                        break
                    end
                    local next_input = navigate_to_menu_option(RUN_CURSOR)
                    print(string.format("Y=%d X=%d -> pressing %s", cy, cx, next_input))
                    press_and_wait_for_cursor_change(next_input, 30)
                    local ny, nx = memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)
                    if ny == cy and nx == cx then
                        print(string.format("  no change after %s (still Y=%d X=%d) - possible timeout", next_input, ny, nx))
                    end
                end
            end

            if ran_away then
                -- The menu-cursor bytes get repurposed by other UI (like the
                -- "Got away safely!" text box) during this transition, so
                -- stop reading them entirely - just clear the message and
                -- wait for the battle to genuinely end.
                print("Ran away - clearing exit text until battle actually ends")
                local exitWaitFrames = 0
                while memory.readbyte(species_addr) ~= 0 and exitWaitFrames < 180 do
                    emu.frameadvance()
                    press_button("B")
                    exitWaitFrames = exitWaitFrames + 1
                end
                if exitWaitFrames >= 180 then
                    print("WARNING: species_addr never returned to 0 after running away (180 frame timeout) - continuing anyway")
                end
                have_battle_controls = false
            end
            end
        end
    end
    ::continue::
end
