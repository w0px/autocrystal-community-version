-- starters.lua
-- Shiny starter soft-resetting. Ported from an earlier standalone script
-- into the init()/step() module pattern used by the launcher.
--
-- Fixed bugs from the original version:
--   - vba.pause() was a VisualBoyAdvance function, not BizHawk - would
--     have thrown an error the moment a shiny was actually found. Now
--     just returns true (the standard "I'm done" signal the launcher
--     expects), same as every other mode.
--   - Now uses the shared GUI (same window as other modes) and the
--     shared lifetime Stats module (so TOTAL ENCOUNTERS is a true total
--     across every mode, not reset per-module).
--   - CRITICAL FIX: soft-resetting with perfectly identical input timing
--     every single attempt produces IDENTICAL "random" DVs every time -
--     a well-known Gen 1/2 RNG quirk (the roll is driven by elapsed
--     frames since a fixed point). A randomized delay after each reload
--     breaks this determinism so DVs actually vary between attempts.
--
-- NOTE: the species name lookup below uses the standard Gen 1/2 party
-- structure convention (species ID list starts right after the party
-- count byte) - this has NOT been independently RAM-verified this
-- session the way other addresses were. Please sanity-check it against
-- the actual Pokemon shown on screen the first time you run this.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. script_dir .. "../?.lua;" .. package.path

Gui = require("gui_module")
Stats = require("data.stats")
PokemonNames = require("data.pokemon_names")
RngEnabler = require("data.rng_enabler")

local function get_pokemon_name(id)
    return PokemonNames[id] or ("Unknown #" .. tostring(id))
end

local hud
local base_address, versionStr, partysize, dv_addr, species_list_addr
local atkdef, spespc
local sessionResetCount = 0
-- Up to 8 split points across the reset sequence instead of 1 giant
-- delay - each fires once per reset cycle, at a genuinely different
-- moment with real game logic in between. Confirmed via direct
-- measurement that more split points meaningfully close the gap toward
-- true uniform coverage (2 splits: 71.5% unique; 4 splits: 94.0% unique
-- out of a real sample). Pushing further since this matters for EVERY
-- user's own save file independently - a coverage gap could mean some
-- save files structurally can't reach a shiny/perfect-DV combination
-- while others can, for no reason the user could ever detect.
-- Split 1 fires immediately on reload (no flag needed, synchronous).
-- Splits 2-6 fire one per mash-loop iteration, up to MASH_SPLITS_TARGET.
-- Split 7 fires the instant the Pokemon is received.
-- Split 8 fires right after the final settle wait, just before reading DVs.
local MASH_SPLITS_TARGET = 5
local mashSplitsFired = 0
local splitAfterReceivedPending = false
local splitAfterSettlePending = false

local function shiny(atk, spc)
    if spc == 0xAA then
        for _, v in ipairs({0x2A, 0x3A, 0x6A, 0x7A, 0xAA, 0xBA, 0xEA, 0xFA}) do
            if atk == v then return true end
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

-- ===== M.init: runs once =====
-- Species and held item are fixed/known for a starter (not variable like
-- a wild encounter), and there's no battle to fight through, so
-- kill-mode doesn't apply either - gray all of these out.
local DISABLED_FIELDS = {
    "chkStopSpecies", "txtSpeciesId",
    "chkStopItem", "txtItemFilter",
    "chkKillMode", "txtKillFilter",
}

function M.init(sharedForm, yOffset, existingHud)
    Stats.load()

    local version = memory.readbyte(0x141)
    local region  = memory.readbyte(0x142)

    if version == 0x54 then -- Crystal
        if region == 0x4A then
            base_address = 0xDC9D; versionStr = "Crystal JP"
        elseif region == 0x45 then
            base_address = 0xDCD7; versionStr = "Crystal US"
        else
            base_address = 0xDCD7; versionStr = "Crystal EU"
        end
    elseif version == 0x55 or version == 0x58 then -- Gold/Silver
        if region == 0x4A then
            base_address = 0xD9E8; versionStr = "G/S JP"
        elseif region == 0x45 then
            base_address = 0xDA22; versionStr = "G/S US"
        elseif region == 0x4B then
            base_address = 0xDB1F; versionStr = "G/S KR"
        else
            base_address = 0xDA22; versionStr = "G/S EU"
        end
    else
        print("No valid ROM detected")
        return false
    end

    partysize = memory.readbyte(base_address)
    dv_addr = (base_address + 0x1D) + partysize * 0x30
    -- Standard Gen 1/2 layout: species ID list starts right after the
    -- count byte, one byte per party slot - NOT independently verified
    -- this session, sanity-check against the actual species shown.
    species_list_addr = base_address + 1 + partysize

    math.randomseed(os.time())

    hud = existingHud
    Gui.reconfigure(hud, DISABLED_FIELDS)

    Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount,
        "Waiting for starter screen (" .. versionStr .. ")...")
    return true
end

-- Called every time this module becomes the active one, whether for the
-- first time or returning to it after a different module ran.
function M.on_switch_to()
    Gui.reconfigure(hud, DISABLED_FIELDS)
    Gui.clear_last_encounter(hud)
end

-- Called every time Start is clicked. Saves the current position as the
-- reset target - position the game right before picking a starter, then
-- click Start.
function M.on_resume()
    savestate.saveslot(3)
    mashSplitsFired = 0
    splitAfterReceivedPending = false
    splitAfterSettlePending = false
end

-- ===== M.step: one call per frame =====
function M.step()
    -- Not received yet - keep mashing A and waiting.
    if memory.readbyte(base_address) == partysize then
        if mashSplitsFired < MASH_SPLITS_TARGET then
            RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
            mashSplitsFired = mashSplitsFired + 1
        end

        for i = 1, 10 do emu.frameadvance() end
        joypad.set({A = true})
        return false
    end

    -- Party size just increased - split point right at the moment of
    -- receiving, before the final settle wait.
    if splitAfterReceivedPending then
        RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
        splitAfterReceivedPending = false
    end

    -- Short wait only - NOT mashing through to
    -- the nickname prompt (that was likely overcorrecting; the actual
    -- confirmed bug was the too-narrow randomization range below, not
    -- read timing). Verify via the per-attempt console log that DVs
    -- come through consistently non-zero and correctly varying with
    -- just this short wait - if not, this needs revisiting.
    for i = 1, 10 do emu.frameadvance() end

    -- Final split point, right after the settle wait, just before
    -- actually reading DVs.
    if splitAfterSettlePending then
        RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
        splitAfterSettlePending = false
    end

    atkdef = memory.readbyte(dv_addr)
    spespc = memory.readbyte(dv_addr + 1)
    local species = memory.readbyte(species_list_addr)
    local speciesName = get_pokemon_name(species)

    local atkv = math.floor(atkdef / 16)
    local defv = atkdef % 16
    local spdv = math.floor(spespc / 16)
    local spcv = spespc % 16
    local isShiny = shiny(atkdef, spespc)

    sessionResetCount = sessionResetCount + 1
    print(string.format("#%d | raw atkdef=$%02X spespc=$%02X | Atk:%d Def:%d Spe:%d Spc:%d%s",
        sessionResetCount, atkdef, spespc, atkv, defv, spdv, spcv, isShiny and " <<< SHINY" or ""))
    Stats.record_encounter()
    Gui.update_last_encounter(hud, sessionResetCount, species, speciesName, atkv, defv, spdv, spcv, isShiny, nil)

    local isPerfect = (atkv == 15 and defv == 15 and spdv == 15 and spcv == 15)
    local isPerfectNegative = (atkv == 0 and defv == 0 and spdv == 0 and spcv == 0)

    if isShiny then
        Stats.record_shiny()
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount, "SHINY FOUND!")
        return true
    elseif Gui.stop_on_perfect(hud) and isPerfect then
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount, "Perfect DVs found!")
        return true
    elseif Gui.stop_on_perfect_negative(hud) and isPerfectNegative then
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount, "Perfect Negative DVs found!")
        return true
    else
        Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount, "Resetting...")
        savestate.loadslot(3)
        -- Up to 8 split points across the reset sequence instead of one
        -- giant wait - this is the first, applied immediately; up to 5
        -- more fire during the dialogue-mash loop, one more right when
        -- received, and a final one right before reading DVs.
        --
        -- "True Randomness" mode uses the full 65536+ frame range for
        -- this first delay instead - much slower per attempt, but
        -- mathematically guarantees reaching every possible DV
        -- combination given enough time, rather than the ~98.8%
        -- empirically-measured coverage of the fast split approach.
        -- Matters most for a single unique target like 15/15/15/15 or
        -- 0/0/0/0, where a small coverage gap has much higher stakes
        -- than it does for shiny hunting (8 valid targets out of 65536).
        if Gui.true_randomness_enabled(hud) then
            Gui.update_counts(hud, Stats.totalEncounters, Stats.totalShinies, Stats.encountersSinceShiny, sessionResetCount,
                "Resetting (True Randomness mode - this will take longer)...")
            RngEnabler.enable_randomness(RngEnabler.FULL_COVERAGE_RANGE)
        else
            RngEnabler.enable_randomness(RngEnabler.SPLIT_RANGE)
        end
        mashSplitsFired = 0
        splitAfterReceivedPending = true
        splitAfterSettlePending = true
        return false
    end
end

return M
