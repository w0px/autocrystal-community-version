-- gui_module.lua
-- A small reusable info window using BizHawk's `forms` library.
-- Place this file in the SAME folder as your script (e.g. next to wild.lua).

local M = {}

function M.create(title)
    local frm = forms.newform(360, 640, title)
    forms.setlocation(frm, 100, 100)

    local SEPARATOR = string.rep("-", 45)

    local widgets = { frm = frm }
    -- NOTE: BizHawk's forms.label can't be made truly bold - forms.setproperty
    -- throws an exception if you try to set "Font". ALL CAPS is the safe
    -- substitute for visual weight here.
    widgets.lblEncounters  = forms.label(frm, "ENCOUNTERS: 0", 10, 10, 320, 20)
    widgets.lblShinies     = forms.label(frm, "SHINIES: 0", 10, 30, 320, 20)
    widgets.lblRuntime     = forms.label(frm, "RUNTIME: 00:00:00", 10, 50, 320, 20)
    widgets.lblStatus      = forms.label(frm, "STATUS: Starting...", 10, 70, 320, 20)
    widgets.lblSep1        = forms.label(frm, SEPARATOR, 10, 90, 320, 16)

    -- Options. forms.checkbox defaults to a fixed narrow width regardless
    -- of caption length, which clips long labels - widen each one
    -- explicitly via forms.setproperty so the full text is visible.
    widgets.chkStopPerfect  = forms.checkbox(frm, "Stop on Perfect DVs (15/15/15/15)", 10, 105)
    forms.setproperty(widgets.chkStopPerfect, "Width", 300)

    widgets.chkStopNegative = forms.checkbox(frm, "Stop on Perfect Negative DVs (0/0/0/0)", 10, 128)
    forms.setproperty(widgets.chkStopNegative, "Width", 300)

    widgets.chkStopSpecies  = forms.checkbox(frm, "Stop on specific Species ID:", 10, 151)
    forms.setproperty(widgets.chkStopSpecies, "Width", 200)
    widgets.txtSpeciesId    = forms.textbox(frm, "", 60, 20, nil, 215, 149)

    widgets.chkStopItem     = forms.checkbox(frm, "Stop on held item:", 10, 174)
    forms.setproperty(widgets.chkStopItem, "Width", 150)
    widgets.txtItemFilter   = forms.textbox(frm, "", 150, 20, nil, 165, 172)
    widgets.lblItemFilterHint = forms.label(frm, "(ID or name, blank = any item)", 28, 194, 300, 16)

    widgets.chkKillMode     = forms.checkbox(frm, "Kill non-shiny (use first move)", 10, 216)
    forms.setproperty(widgets.chkKillMode, "Width", 300)
    widgets.lblKillFilter   = forms.label(frm, "Only kill IDs or names (comma-sep, blank=all):", 28, 238, 300, 16)
    widgets.txtKillFilter   = forms.textbox(frm, "", 280, 20, nil, 28, 256)

    widgets.chkDiscord      = forms.checkbox(frm, "Send Discord notification (shiny/stop)", 10, 284)
    forms.setproperty(widgets.chkDiscord, "Width", 300)
    widgets.lblDiscordHint  = forms.label(frm, "(requires local relay - see discord_relay.ps1)", 28, 304, 300, 16)

    widgets.lblLastHeader  = forms.label(frm, "Last Encounter:", 10, 329, 300, 20)
    widgets.lblLastSpecies = forms.label(frm, "Species: -", 10, 349, 300, 20)
    widgets.lblLastStats   = forms.label(frm, "Atk/Def/Spe/Spc: -", 10, 369, 300, 20)
    widgets.lblLastItem    = forms.label(frm, "Held Item: -", 10, 389, 300, 20)
    widgets.lblLastShiny   = forms.label(frm, "Shiny: -", 10, 409, 300, 20)

    widgets.lblSep2        = forms.label(frm, SEPARATOR, 10, 431, 320, 16)
    widgets.lblHistHeader  = forms.label(frm, "RECENT ENCOUNTERS:", 10, 448, 320, 20)
    widgets.history = {}
    for i = 1, 8 do
        widgets.history[i] = forms.label(frm, "", 10, 468 + (i - 1) * 18, 340, 16)
    end

    widgets._historyData = {}
    widgets._startTime = os.time()
    return widgets
end

-- Convenience readers for the option controls. Returns whether each stop
-- condition is currently armed, and (for species) the target ID typed in.
function M.stop_on_perfect(w)
    return forms.ischecked(w.chkStopPerfect)
end

function M.stop_on_perfect_negative(w)
    return forms.ischecked(w.chkStopNegative)
end

-- Returns (enabled, targetId). targetId is nil if the box is empty or not
-- a valid number, in which case the caller should treat it as not armed
-- even if the checkbox is checked (avoids accidentally matching species 0).
function M.stop_on_species(w)
    local enabled = forms.ischecked(w.chkStopSpecies)
    local targetId = tonumber(forms.gettext(w.txtSpeciesId))
    return enabled and targetId ~= nil, targetId
end

-- Returns (enabled, filterTokens). filterTokens is nil if the box is
-- blank, meaning "any held item counts" - matching against the raw item
-- ID vs name is left to the caller, same pattern as kill_species_filter.
function M.stop_on_item(w)
    local enabled = forms.ischecked(w.chkStopItem)
    local raw = forms.gettext(w.txtItemFilter)
    if raw == nil or raw:match("^%s*$") then
        return enabled, nil
    end
    local tokens = {}
    for token in raw:gmatch("[^,]+") do
        local trimmed = token:match("^%s*(.-)%s*$")
        if trimmed ~= "" then table.insert(tokens, trimmed) end
    end
    if #tokens == 0 then return enabled, nil end
    return enabled, tokens
end

function M.kill_non_shiny(w)
    return forms.ischecked(w.chkKillMode)
end

-- Returns a list of raw, trimmed tokens from the comma-separated text box
-- (each could be a numeric ID like "69" or a name like "Bellsprout"), or
-- nil if the box is empty/blank - callers should treat nil as "no filter,
-- any species is fair game to kill". Matching against ID vs name is left
-- to the caller (wild.lua), since this module doesn't know the Pokemon
-- name table.
function M.kill_species_filter(w)
    local raw = forms.gettext(w.txtKillFilter)
    if raw == nil or raw:match("^%s*$") then
        return nil
    end

    local tokens = {}
    for token in raw:gmatch("[^,]+") do
        local trimmed = token:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(tokens, trimmed)
        end
    end

    if #tokens == 0 then return nil end
    return tokens
end

function M.discord_enabled(w)
    return forms.ischecked(w.chkDiscord)
end

function M.update_counts(w, encounterCount, shinyCount, status)
    forms.settext(w.lblEncounters, string.format("ENCOUNTERS: %d", encounterCount))
    forms.settext(w.lblShinies, string.format("SHINIES: %d", shinyCount))
    forms.settext(w.lblRuntime, "RUNTIME: " .. os.date("!%H:%M:%S", os.time() - w._startTime))
    if status then
        forms.settext(w.lblStatus, "STATUS: " .. status)
    end
end

function M.update_last_encounter(w, index, species, speciesName, atk, def, spe, spc, isShiny, itemName)
    forms.settext(w.lblLastSpecies, string.format("Species: %s (#%d)", speciesName, species))
    forms.settext(w.lblLastStats, string.format("Atk/Def/Spe/Spc: %d/%d/%d/%d", atk, def, spe, spc))
    forms.settext(w.lblLastItem, "Held Item: " .. (itemName or "-"))
    forms.settext(w.lblLastShiny, "Shiny: " .. (isShiny and "YES!" or "no"))

    local entry = string.format("#%d  %-10s  A:%-2d D:%-2d S:%-2d Sp:%-2d%s%s",
        index, speciesName, atk, def, spe, spc,
        (itemName and itemName ~= "(no item)") and ("  [" .. itemName .. "]") or "",
        isShiny and "  *SHINY*" or "")
    table.insert(w._historyData, 1, entry)
    if #w._historyData > 8 then table.remove(w._historyData) end
    for i = 1, 8 do
        forms.settext(w.history[i], w._historyData[i] or "")
    end
end

function M.close(w)
    forms.destroy(w.frm)
end

return M
