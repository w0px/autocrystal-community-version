-- fishing.lua
-- Fishing encounters via the Select "quick draw" item registration -
-- register your rod to Select in-game, stand facing water, then start
-- this module. It presses Select to cast, mashes A while waiting for a
-- bite, and recasts if nothing happens within the timeout.
--
-- Once a bite turns into a real battle, it's the EXACT SAME battle
-- system wild.lua already handles (same species_addr, same DV/shiny
-- detection, same menu navigation) - reused here essentially unchanged.
--
-- NOTE: the bite-detection approach is a brute-force heuristic (mash A
-- continuously during a generous wait window, checking species_addr),
-- not an independently RAM-verified "bite" flag - unlike most of the
-- rest of this project. It should be robust regardless of exact timing
-- since we're not trying to react to a narrow window, just always
-- pressing A throughout. The FISH_CAST_ATTEMPTS timeout below is a
-- first-guess value and may need tuning based on real testing - if
-- bites are getting missed or recasting happens too eagerly/too late,
-- that's the number to adjust.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Mem = require("data.memory")
Gui = require("gui_module")
PokemonNames = require("data.pokemon_names")
ItemNames = require("data.item_names")
Stats = require("data.stats")

local hud

function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

function get_item_name(id)
    return ItemNames[id] or ("Unknown Item #" .. tostring(id))
end

function vprint(msg)
    if Gui.verbose_logging(hud) then
        print(msg)
    end
end

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

-- ===== Persistent state =====

local atkdef, spespc, species, item
local shinyvalue = 0
local stopRequested = false
local stopReason = ""
local realEncounterConfirmed = false
local pendingEncounterUpdate = false
local enemy_addr
local LoadBattleMenuAddr
local EnemyWildmonInitialized
local version, region
local sessionEncounterCount = 0
local highestSpeSpc = 0
local highestAtkDef = 0

local MENU_CURSOR_Y = 0xCFA9
local MENU_CURSOR_X = 0xCFAA
local RUN_CURSOR = {y = 2, x = 2}
local FIRST_MOVE_PP_ADDR = 0xC634

local dv_flag_addr, species_addr, item_addr

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
    for i = 1, 4 do
        joypad.set(input)
        emu.frameadvance()
    end
    emu.frameadvance()
end

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
local FIGHT_CURSOR = {y = 1, x = 1}

function do_kill_turn()
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

    have_battle_controls = false
    while not have_battle_controls and memory.readbyte(species_addr) ~= 0 do
        emu.frameadvance()
        press_button("A")
    end
end

-- ===== Fishing-specific: cast, wait for a bite, recast if nothing =====
local FISH_CAST_ATTEMPTS = 40 -- ~40 * 5 frames = ~200 frames (~3-4s) - first-guess, may need tuning

function do_fish_cycle()
    vprint("Casting rod (Select)...")
    press_button("Select")

    local attempts = 0
    while attempts < FISH_CAST_ATTEMPTS do
        if memory.readbyte(species_addr) ~= 0 then
            vprint("Bite! Battle starting.")
            return
        end
        press_button("A")
        attempts = attempts + 1
    end

    vprint("No bite within timeout - recasting")
end

local overworld_loaded = false
local overworld_settle_frames = 0
local REQUIRED_SETTLE_FRAMES = 10

-- ===== M.init =====
function M.init(sharedForm, yOffset, existingHud)
    Stats.load()

    version = memory.readbyte(0x141)
    region = memory.readbyte(0x142)

    hud = existingHud
    Gui.reconfigure(hud, {}) -- fishing encounters vary by species/item just like wild ones - nothing to disable

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
            enemy_addr = 0xda22
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x73c5)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x45 then
            enemy_addr = 0xda22
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x73C5)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4A then
            enemy_addr = 0xd9e8
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x73C5)
            Mem.SetRomBankAddress("Gold")
        elseif region == 0x4B then
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

    Mem.RegisterROMHook(LoadBattleMenuAddr, function()
        if ActiveModuleName ~= "fishing" then return end
        have_battle_controls = true
        vprint(string.format("Battle menu loaded | Cursor Y=%d X=%d",
            memory.readbyte(MENU_CURSOR_Y), memory.readbyte(MENU_CURSOR_X)))
    end, "Detect Battle Menu")

    Mem.RegisterROMHook(EnemyWildmonInitialized, function()
        if ActiveModuleName ~= "fishing" then return end
        realEncounterConfirmed = true
        vprint("combat started")
        item = memory.readbyte(item_addr)
        atkdef = memory.readbyte(enemy_addr)
        spespc = memory.readbyte(enemy_addr + 1)
        highestAtkDef = math.max(highestAtkDef, atkdef)
        highestSpeSpc = math.max(highestSpeSpc, spespc)
        species = memory.readbyte(species_addr)
        shiny(atkdef, spespc)

        local speciesName = get_pokemon_name(species)
        local itemName = get_item_name(item)
        print(string.format("%s (#%d) | Atk: %d Def: %d Spe: %d Spc: %d | Item: %s",
            speciesName, species, math.floor(atkdef/16), atkdef%16, math.floor(spespc/16), spespc%16, itemName))

        sessionEncounterCount = sessionEncounterCount + 1
        pendingEncounterUpdate = true
    end, "Tell Display Battle Started / sending data")

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount,
        "Ready - stand facing water with rod on Select...")
    return true
end

function M.on_switch_to()
    Gui.reconfigure(hud, {})
    Gui.clear_last_encounter(hud)
end

function M.on_resume()
    overworld_settle_frames = 0
    overworld_loaded = false
end

-- ===== M.step =====
function M.step()
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
        Gui.update_last_encounter(hud, Stats.totalEncounters, species, speciesName, atkDV, defDV, speDV, spcDV, isShinyEncounter, itemName)

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

    if rawSpecies == 0 then
        have_battle_controls = false
        overworld_settle_frames = overworld_settle_frames + 1
        if overworld_settle_frames >= REQUIRED_SETTLE_FRAMES then
            if not overworld_loaded then
                vprint("Ready to fish again")
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
        do_fish_cycle()
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Fishing...")

    elseif memory.readbyte(species_addr) ~= 0 then
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

            local killFilterTokens = Gui.kill_species_filter(hud)
            local killAllowedForThisSpecies = species_matches_filter(killFilterTokens, species, get_pokemon_name(species))
            local hasPP = memory.readbyte(FIRST_MOVE_PP_ADDR) > 0

            if Gui.kill_non_shiny(hud) and killAllowedForThisSpecies and hasPP then
                Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Attacking...")
                do_kill_turn()
            else
                if Gui.kill_non_shiny(hud) and killAllowedForThisSpecies and not hasPP then
                    print("First move has 0 PP - fleeing instead of attacking")
                end

                Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Fleeing battle...")

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
                    vprint("Ran away - clearing exit text until battle actually ends")
                    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionEncounterCount, "Escaped, wrapping up...")
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
    return false
end

return M
