-- static.lua
-- Static encounters (Sudowoodo, legendary beasts/birds, gift Pokemon
-- battles, etc.) via soft-reset - works for BOTH respawnable statics
-- (which could also be fled-and-retried) and one-time-only statics
-- (which can't), since reloading a savestate from BEFORE the
-- interaction happened is universal regardless of which category a
-- given static falls into. No need to special-case either kind.
--
-- Mechanically this is a hybrid: the encounter itself is read the same
-- way wild.lua reads any wild battle (hook-based, since the Pokemon is
-- the ENEMY, not a party addition like Starters/Egg) - but the overall
-- flow (savestate, 8-way split RNG, mash-and-check, reload-if-not-shiny)
-- matches Starters/Egg's soft-reset loop, not Wild's continuous walking.
--
-- No kill mode, no species stop, no True Randomness disabling: killing
-- a static is never desirable (many are one-time-only, and even
-- respawnable ones aren't worth killing over catching), and the species
-- is already fixed/known for whichever static you're resetting, so a
-- species filter doesn't apply the way it does for Wild.
--
-- Same anti-determinism fix as Starters/Egg: soft-resetting with
-- perfectly identical input timing produces IDENTICAL "random" results
-- every attempt unless timing variance is deliberately introduced after
-- each reload.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Mem = require("data.memory")
Gui = require("gui_module")
PokemonNames = require("data.pokemon_names")
ItemNames = require("data.item_names")
Stats = require("data.stats")
RngEnabler = require("data.rng_enabler")

local function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

local function get_item_name(id)
    if id == 0 then return "(no item)" end
    return ItemNames[id] or ("Unknown item #" .. tostring(id))
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

local SAVESTATE_SLOT = 5 -- separate from Starters' slot 3 and Egg's slot 4

local enemy_addr, species_addr, item_addr
local LoadBattleMenuAddr, EnemyWildmonInitialized
local version, region

local atkdef, spespc, species, item = 0, 0, 0, 0
local shinyvalue = 0
local resetCount = 0
local pendingEncounterUpdate = false

-- Every split point happens during the mash-A phase, since (unlike
-- Egg) the hook reads DVs immediately the instant the battle starts -
-- there's no later "received but not yet read" window to split at
-- afterward, so all 8 splits need to land before that hook ever fires.
local MASH_SPLITS_TARGET = 8
local mashSplitsFired = 0

local function shiny(atk, sp)
    shinyvalue = 0
    if sp == 0xAA then
        if atk == 0x2A or atk == 0x3A or atk == 0x6A or atk == 0x7A or atk == 0xAA or atk == 0xBA or atk == 0xEA or atk == 0xFA then
            shinyvalue = 1
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

-- Hooks get REPLACED by name every time RegisterROMHook runs - must be
-- called every time this module becomes active, not just once. See
-- wild.lua for the original confirmation of this behavior.
local function register_hooks()
    Mem.RegisterROMHook(EnemyWildmonInitialized, function()
        if ActiveModuleName ~= "static" then return end
        item = memory.readbyte(item_addr)
        atkdef = memory.readbyte(enemy_addr)
        spespc = memory.readbyte(enemy_addr + 1)
        species = memory.readbyte(species_addr)
        shiny(atkdef, spespc) -- sets shinyvalue as a side effect if applicable

        local speciesName = get_pokemon_name(species)
        local itemName = get_item_name(item)
        print(string.format("%s (#%d) | Atk: %d Def: %d Spe: %d Spc: %d | Item: %s",
            speciesName, species, math.floor(atkdef/16), atkdef%16, math.floor(spespc/16), spespc%16, itemName))

        pendingEncounterUpdate = true
    end, "Static Encounter Battle Started")
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

    version = memory.readbyte(0x141)
    region = memory.readbyte(0x142)

    hud = existingHud
    Gui.reconfigure(hud, DISABLED_FIELDS)

    if version == 0x54 then
        if region == 0x44 or region == 0x46 or region == 0x49 or region == 0x53 or region == 0x45 then
            enemy_addr = 0xd20c
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            Mem.SetRomBankAddress("Crystal")
        elseif region == 0x4A then
            enemy_addr = 0xd23d
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)
            Mem.SetRomBankAddress("Crystal")
        else
            print("No valid ROM detected")
            return false
        end
    elseif version == 0x55 or version == 0x58 then
        if region == 0x44 or region == 0x46 or region == 0x49 or region == 0x53 or region == 0x45 then
            enemy_addr = 0xda22
            LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4E62)
            EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x73c5)
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
        else
            print("No valid ROM detected")
            return false
        end
    else
        print("No valid ROM detected")
        return false
    end

    species_addr = enemy_addr + 0x22
    item_addr = enemy_addr - 0x05

    math.randomseed(os.time())
    register_hooks()

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
        "Ready - stand facing the static encounter, then click Start...")
    return true
end

function M.on_switch_to()
    register_hooks()
    Gui.reconfigure(hud, DISABLED_FIELDS)
    Gui.clear_last_encounter(hud)
end

-- Called every time Start is clicked. Saves the current position
-- (facing the static encounter) as the reset target.
function M.on_resume()
    savestate.saveslot(SAVESTATE_SLOT)
    mashSplitsFired = 0
    pendingEncounterUpdate = false
end

-- ===== M.step =====
function M.step()
    if pendingEncounterUpdate then
        pendingEncounterUpdate = false
        resetCount = resetCount + 1

        local speciesName = get_pokemon_name(species)
        local itemName = get_item_name(item)
        local atkv = math.floor(atkdef / 16)
        local defv = atkdef % 16
        local spdv = math.floor(spespc / 16)
        local spcv = spespc % 16
        local isShiny = (shinyvalue == 1)

        Stats.record_encounter()
        Gui.update_last_encounter(hud, resetCount, species, speciesName, atkv, defv, spdv, spcv, isShiny, itemName)

        if isShiny then
            print(string.format("SHINY static encounter found! %s Atk:%d Def:%d Spe:%d Spc:%d - stopping here",
                speciesName, atkv, defv, spdv, spcv))
            Stats.record_shiny()
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "SHINY found! Stopped - handle the battle yourself from here.")
            send_discord_notification(string.format(
                "Shiny static encounter found! %s (Atk:%d Def:%d Spe:%d Spc:%d) holding %s",
                speciesName, atkv, defv, spdv, spcv, itemName))
            return true
        else
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, resetCount,
                "Not shiny - resetting...")
            savestate.loadslot(SAVESTATE_SLOT)
            mashSplitsFired = 0
            return false
        end
    end

    -- Not yet in battle - keep mashing A to interact with/re-trigger the
    -- static encounter, spreading the 8-way split delay across attempts.
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

return M
