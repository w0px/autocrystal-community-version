-- gamecorner.lua
-- Game Corner prize Pokemon (Abra, Cubone, Wobbuffet, etc.) via
-- soft-reset. Structurally this is closest to egg.lua, NOT wild.lua/
-- static.lua - the prize goes directly into your PARTY (a purchase),
-- not into an enemy-data slot like a wild battle would.
--
-- Save right at the prize-selection menu, with the cursor already on
-- whichever Pokemon you want (confirmed: pressing A ~6 times from there
-- handles the "are you sure?" confirmation and the following text,
-- ending with the Pokemon in your party - no need to know the exact
-- count, just mash until party size increases, same as egg.lua).
--
-- Since the savestate is taken at this exact screen, your coin balance
-- gets correctly restored on every single reload too - no risk of
-- coins draining across resets, since nothing is ever actually spent
-- outside of a state that gets reloaded away again.
--
-- No kill mode, no species stop: the species is already fixed by
-- whichever prize you selected before saving, and killing a purchased
-- Pokemon is never desirable.
--
-- Same anti-determinism fix as Starters/Egg/Static: soft-resetting with
-- perfectly identical input timing produces IDENTICAL "random" results
-- every attempt unless timing variance is deliberately introduced after
-- each reload.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Gui = require("gui_module")
PokemonNames = require("data.pokemon_names")
Stats = require("data.stats")
RngEnabler = require("data.rng_enabler")

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

local SAVESTATE_SLOT = 6 -- separate from Starters(3)/Egg(4)/Static(5)

local party_base_addr
local partysizeBeforeReceiving
local newSlotIndex
local newDvAddr, newSpeciesAddr

local resetCount = 0

-- Every split point happens during the mash-A phase - there's no
-- separate "received but not yet read" window like egg.lua has, since
-- we read DVs directly from the party slot the moment party size
-- increases, same read point as the last split.
local MASH_SPLITS_TARGET = 8
local mashSplitsFired = 0
local lastResetTime = nil

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
    joypad.set({})
    emu.frameadvance()
end

-- ===== M.init: runs ONCE =====
local DISABLED_FIELDS = {
    "chkStopSpecies", "txtSpeciesId",
    "chkKillMode", "txtKillFilter",
}

function M.init(sharedForm, yOffset, existingHud)
    -- See egg.lua/wild.lua for why this is wrapped in pcall.
    pcall(function() comm.httpSetTimeout(3000) end)

    Stats.load()

    local version = memory.readbyte(0x141)
    local region = memory.readbyte(0x142)

    if version == 0x54 then
        if region == 0x4A then party_base_addr = 0xDC9D
        else party_base_addr = 0xDCD7 end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x4A then party_base_addr = 0xD9E8
        elseif region == 0x4B then party_base_addr = 0xDB1F
        else party_base_addr = 0xDA22 end
    else
        print("No valid ROM detected")
        return false
    end

    hud = existingHud
    Gui.reconfigure(hud, DISABLED_FIELDS)

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
        "Ready - stand at the prize menu with your Pokemon selected, then click Start...")
    return true
end

function M.on_switch_to()
    Gui.reconfigure(hud, DISABLED_FIELDS)
    Gui.clear_last_encounter(hud)
end

-- Called every time Start is clicked. Saves the current position -
-- prize menu open, cursor on the desired Pokemon - as the reset target.
function M.on_resume()
    savestate.saveslot(SAVESTATE_SLOT)
    partysizeBeforeReceiving = memory.readbyte(party_base_addr)
    newSlotIndex = partysizeBeforeReceiving
    newDvAddr = party_base_addr + 0x1D + newSlotIndex * 0x30
    newSpeciesAddr = party_base_addr + 1 + newSlotIndex
    mashSplitsFired = 0
    lastResetTime = os.time()
end

-- If 60 seconds pass without reaching a shiny/not-shiny decision (e.g.
-- a phone call interrupted the mashing sequence), force the same
-- reload this module already does every normal cycle anyway - simpler
-- and more reliable than guessing what recovery input is needed, since
-- it just goes back to a known-good state unconditionally.
local STUCK_RESET_TIMEOUT = 60
local function check_stuck_and_force_reset()
    if lastResetTime == nil then
        lastResetTime = os.time()
        return
    end
    if os.time() - lastResetTime >= STUCK_RESET_TIMEOUT then
        print(string.format("WARNING: no reset for %d+ seconds - likely stuck (phone call, etc). Forcing a reload.", STUCK_RESET_TIMEOUT))
        send_discord_notification(string.format(
            "Potentially stuck: no reset for over %d seconds. Forced a reload to recover - check on it if this keeps happening.",
            STUCK_RESET_TIMEOUT))
        savestate.loadslot(SAVESTATE_SLOT)
        partysizeBeforeReceiving = memory.readbyte(party_base_addr)
        mashSplitsFired = 0
        lastResetTime = os.time()
    end
end

-- ===== M.step =====
function M.step()
    check_stuck_and_force_reset()

    local currentPartySize = memory.readbyte(party_base_addr)

    if currentPartySize <= partysizeBeforeReceiving then
        -- Still working through the "are you sure?" confirmation and
        -- the following text - keep mashing A.
        if mashSplitsFired < MASH_SPLITS_TARGET then
            if Gui.true_randomness_enabled(hud) then
                RngEnabler.enable_randomness(RngEnabler.FULL_COVERAGE_RANGE)
            else
                RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
            end
            mashSplitsFired = mashSplitsFired + 1
        end
        press_button("A")
        return false
    end

    -- Party size increased - the Pokemon is in, read its DVs directly.
    resetCount = resetCount + 1
    local species = memory.readbyte(newSpeciesAddr)
    local speciesName = get_pokemon_name(species)
    local atkdef = memory.readbyte(newDvAddr)
    local spespc = memory.readbyte(newDvAddr + 1)
    local atkv = math.floor(atkdef / 16)
    local defv = atkdef % 16
    local spdv = math.floor(spespc / 16)
    local spcv = spespc % 16
    local isShiny = shiny(atkdef, spespc)

    print(string.format("%s (#%d) | Atk: %d Def: %d Spe: %d Spc: %d", speciesName, species, atkv, defv, spdv, spcv))

    Stats.record_encounter()
    Gui.update_last_encounter(hud, resetCount, species, speciesName, atkv, defv, spdv, spcv, isShiny, "(no item)")

    if isShiny then
        print(string.format("SHINY Game Corner Pokemon found! %s Atk:%d Def:%d Spe:%d Spc:%d - stopping here",
            speciesName, atkv, defv, spdv, spcv))
        Stats.record_shiny()
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
            "SHINY found! Stopped.")
        send_discord_notification(string.format(
            "Shiny Game Corner Pokemon found! %s (Atk:%d Def:%d Spe:%d Spc:%d)",
            speciesName, atkv, defv, spdv, spcv))
        return true
    else
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
            "Not shiny - resetting...")
        savestate.loadslot(SAVESTATE_SLOT)
        mashSplitsFired = 0
        lastResetTime = os.time()
        return false
    end
end

return M
