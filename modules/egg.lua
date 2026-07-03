-- egg.lua
-- Talk to the NPC that gives an egg (Day Care man for a normal egg, or
-- the special delivery NPC for a Togepi-style mystery egg - mechanically
-- identical from this script's perspective), receive it, and this module
-- immediately checks its DVs/shininess without walking anywhere first.
--
-- WHY THIS IS SAFE TO DO: an egg's species and DVs are fully fixed the
-- instant you receive it (confirmed via the same TASVideos RNG doc used
-- for Starters) - hatching just reveals what's already there. Walking a
-- full hatch (which can take thousands of steps depending on species)
-- only matters for actually PLAYING with the Pokemon, not for knowing
-- if it's shiny. So: fast reset-and-check loop for the common (non-shiny)
-- case, and only once we've found a shiny do we actually walk it out to
-- watch it hatch for real.
--
-- CONFIRMED mechanic: the "display species" byte for a party slot reads
-- 0xFD (253) while it's an unhatched egg, updating to the real species
-- the instant it hatches (pokecrystal disassembly + Bulbapedia's Glitch
-- Egg article, cross-checked).
--
-- Includes the same anti-determinism fix discovered for Starters: soft-
-- resetting with perfectly identical input timing produces IDENTICAL
-- "random" results every attempt (a well-known Gen 1/2 RNG quirk) unless
-- you deliberately introduce timing variance after each reload.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Mem = require("data.memory")
Gui = require("gui_module")
PokemonNames = require("data.pokemon_names")
Stats = require("data.stats")

local function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

local hud

local function vprint(msg)
    if Gui.verbose_logging(hud) then
        print(msg)
    end
end

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

local EGG_PLACEHOLDER = 0xFD
local SAVESTATE_SLOT = 4 -- separate from Starters' slot 3, avoids any cross-module confusion

local party_base_addr
local eggSlotIndex -- fixed once determined: the same slot every reset, since party size before receiving never changes
local eggDvAddr
local eggSpeciesListAddr
local partysizeBeforeReceiving

local enemy_species_addr -- generic wild-battle address, safety net during the walk-to-hatch phase only

local resetCount = 0
local stepsTaken = 0
local sessionEncounterCount = 0
local confirmedShinyAtkv, confirmedShinyDefv, confirmedShinySpdv, confirmedShinySpcv

-- State machine: "waiting_for_egg" -> "walking_to_hatch" (only reached
-- after confirming a shiny) -> done
local state = "waiting_for_egg"

local function shiny(atkdef, spespc)
    if spespc == 0xAA then
        if atkdef == 0x2A or atkdef == 0x3A or atkdef == 0x6A or atkdef == 0x7A or atkdef == 0xAA or atkdef == 0xBA or atkdef == 0xEA or atkdef == 0xFA then
            return true
        end
    end
    return false
end

local function press_button(btn)
    local input = {[btn] = true}
    for i = 1, 4 do
        joypad.set(input)
        emu.frameadvance()
    end
    emu.frameadvance()
end

-- ===== Movement (verbatim from wild.lua's proven drift-proof system) -
-- only used during the walking_to_hatch phase, after a shiny is found =====
local MOVEMENT_FLAG_ADDR = 0xD4DD
local MOVEMENT_IDLE_VALUE = 0xFF

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
        if memory.readbyte(enemy_species_addr) ~= 0 then return true end
    end

    n = 0
    while memory.readbyte(MOVEMENT_FLAG_ADDR) ~= MOVEMENT_IDLE_VALUE and n < 90 do
        emu.frameadvance()
        n = n + 1
        if memory.readbyte(enemy_species_addr) ~= 0 then return true end
    end

    local endX, endY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
    return (endX ~= startX or endY ~= startY)
end

local safe_pair = nil
local homeX, homeY = nil, nil

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

    if memory.readbyte(enemy_species_addr) ~= 0 then return false end
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
        if memory.readbyte(enemy_species_addr) ~= 0 then return nil end

        if movedOut then
            local movedBack = attempt_step(pair.back)
            if memory.readbyte(enemy_species_addr) ~= 0 then return nil end

            local nowX, nowY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
            if movedBack and nowX == anchorX and nowY == anchorY then
                vprint(string.format("Found safe zero-drift pair: %s / %s", pair.out, pair.back))
                return pair
            else
                anchorX, anchorY = nowX, nowY
            end
        end
    end

    return nil
end

local failed_pair_attempts = 0

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
            if memory.readbyte(enemy_species_addr) ~= 0 then return false end
            if not reachedHome then return true end
        end

        local verbose = Gui.verbose_logging(hud) and (failed_pair_attempts % 20 == 0)
        safe_pair = find_safe_pair(verbose)
        if safe_pair == nil and memory.readbyte(enemy_species_addr) == 0 then
            failed_pair_attempts = failed_pair_attempts + 1
        else
            madeRealProgress = (safe_pair ~= nil)
        end
    else
        local startX, startY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
        local movedOut = attempt_step(safe_pair.out)
        if memory.readbyte(enemy_species_addr) ~= 0 then return false end
        local movedBack = attempt_step(safe_pair.back)
        if memory.readbyte(enemy_species_addr) ~= 0 then return false end

        local endX, endY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
        local trulyReturned = (endX == startX and endY == startY)
        madeRealProgress = movedOut and movedBack and trulyReturned

        if movedOut and movedBack and not trulyReturned then
            safe_pair = nil
        end
    end

    return madeRealProgress
end

-- ===== M.init =====
function M.init(sharedForm, yOffset, existingHud)
    Stats.load()

    local version = memory.readbyte(0x141)
    local region = memory.readbyte(0x142)

    if version == 0x54 then
        if region == 0x4A then party_base_addr = 0xDC9D
        elseif region == 0x45 then party_base_addr = 0xDCD7
        else party_base_addr = 0xDCD7 end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x4A then party_base_addr = 0xD9E8
        elseif region == 0x45 then party_base_addr = 0xDA22
        elseif region == 0x4B then party_base_addr = 0xDB1F
        else party_base_addr = 0xDA22 end
    else
        print("No valid ROM detected")
        return false
    end

    if version == 0x54 then
        if region == 0x4A then enemy_species_addr = 0xd23d + 0x22
        else enemy_species_addr = 0xd20c + 0x22 end
    else
        if region == 0x4A then enemy_species_addr = 0xd9e8 + 0x22
        elseif region == 0x4B then enemy_species_addr = 0xdb1f + 0x22
        else enemy_species_addr = 0xda22 + 0x22 end
    end

    math.randomseed(os.time())

    hud = existingHud
    Gui.reconfigure(hud, {
        "chkStopSpecies", "txtSpeciesId",
        "chkStopItem", "txtItemFilter",
        "chkKillMode", "txtKillFilter",
    })

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
        "Ready - stand facing the NPC that gives the egg...")
    return true
end

function M.on_switch_to()
    Gui.reconfigure(hud, {
        "chkStopSpecies", "txtSpeciesId",
        "chkStopItem", "txtItemFilter",
        "chkKillMode", "txtKillFilter",
    })
    Gui.clear_last_encounter(hud)
end

-- Called every time Start is clicked. Saves the current position (facing
-- the NPC) as the reset target, and records the party size right now -
-- since resets always return to this exact point, the new egg will
-- always land in the same slot (the next open one) every single attempt.
function M.on_resume()
    savestate.saveslot(SAVESTATE_SLOT)
    partysizeBeforeReceiving = memory.readbyte(party_base_addr)
    eggSlotIndex = partysizeBeforeReceiving
    eggDvAddr = party_base_addr + 0x1D + eggSlotIndex * 0x30
    eggSpeciesListAddr = party_base_addr + 1 + eggSlotIndex
    state = "waiting_for_egg"
    safe_pair = nil
    homeX, homeY = nil, nil
end

-- ===== M.step =====
function M.step()
    if state == "waiting_for_egg" then
        local currentPartySize = memory.readbyte(party_base_addr)

        if currentPartySize <= partysizeBeforeReceiving then
            -- Still working through the NPC's dialogue - keep mashing A.
            for i = 1, 4 do emu.frameadvance() end
            press_button("A")
            return false
        end

        -- Egg received - DVs are already fixed, check immediately, no
        -- walking needed to know if it's shiny.
        press_button("B") -- clear any trailing text
        local atkdef = memory.readbyte(eggDvAddr)
        local spespc = memory.readbyte(eggDvAddr + 1)
        local species = memory.readbyte(eggSpeciesListAddr) -- still 0xFD at this point, expected
        local isShiny = shiny(atkdef, spespc)

        local atkv = math.floor(atkdef / 16)
        local defv = atkdef % 16
        local spdv = math.floor(spespc / 16)
        local spcv = spespc % 16

        resetCount = resetCount + 1
        Stats.record_encounter()
        Gui.update_last_encounter(hud, Stats.totalEncounters, species, "Egg", atkv, defv, spdv, spcv, isShiny, nil)

        if isShiny then
            print(string.format("SHINY egg found! Atk:%d Def:%d Spe:%d Spc:%d - walking it out to hatch now", atkv, defv, spdv, spcv))
            confirmedShinyAtkv, confirmedShinyDefv, confirmedShinySpdv, confirmedShinySpcv = atkv, defv, spdv, spcv
            Stats.record_shiny()
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "SHINY egg found! Walking to hatch...")
            send_discord_notification(string.format(
                "Shiny egg found! (Atk:%d Def:%d Spe:%d Spc:%d) - walking it out to hatch",
                atkv, defv, spdv, spcv))
            state = "walking_to_hatch"
            return false
        else
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "Not shiny - resetting...")
            savestate.loadslot(SAVESTATE_SLOT)
            -- Break the deterministic-RNG pattern (same fix as Starters):
            -- identical input timing every reset produces IDENTICAL
            -- "random" DVs every single time otherwise.
            local extraFrames = math.random(1, 30)
            for i = 1, extraFrames do emu.frameadvance() end
            return false
        end

    elseif state == "walking_to_hatch" then
        if memory.readbyte(enemy_species_addr) ~= 0 then
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                string.format("Wild encounter interrupted - fleeing (steps so far: %d)...", stepsTaken))
            while memory.readbyte(enemy_species_addr) ~= 0 do
                emu.frameadvance()
                press_button("B")
            end
            safe_pair = nil
            return false
        end

        local madeProgress = do_nudge_cycle()
        if madeProgress then
            stepsTaken = stepsTaken + 1
        end

        local currentSpeciesListValue = memory.readbyte(eggSpeciesListAddr)
        if currentSpeciesListValue ~= EGG_PLACEHOLDER then
            local speciesName = get_pokemon_name(currentSpeciesListValue)
            print(string.format("Hatched! %s - confirmed shiny, all done.", speciesName))
            Gui.update_last_encounter(hud, Stats.totalEncounters, currentSpeciesListValue, speciesName,
                confirmedShinyAtkv, confirmedShinyDefv, confirmedShinySpdv, confirmedShinySpcv, true, nil)
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "Hatched: " .. speciesName .. " (SHINY)!")
            return true
        end

        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
            string.format("Walking to hatch the shiny... (steps so far: %d)", stepsTaken))
        return false
    end

    return false
end

return M
