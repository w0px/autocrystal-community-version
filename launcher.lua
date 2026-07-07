-- launcher.lua
-- The ONLY script you load into BizHawk's Lua Console. This is the one
-- true persistent window and the one true main loop.
--
-- IMPORTANT: BizHawk does not allow emu.frameadvance() to be called from
-- within a UI callback (confirmed directly from BizHawk's own error:
-- "emu.frameadvance() is not allowed during any callbacks"). Because of
-- this, button click handlers below do NOT do any real work themselves -
-- they only set a flag. All actual logic (loading a module, calling
-- init/step) happens from the main loop at the bottom of this file,
-- which is the one place we know for certain is safe to call
-- emu.frameadvance() and everything that depends on it.
--
-- Folder layout expected:
--   launcher.lua          (this file, base folder)
--   modules/wild.lua, gui_module.lua, (future: fishing.lua, egg.lua, etc.)
--   data/memory.lua, pokemon_names.lua, item_names.lua, wild_stats.txt,
--        launcher_art.png, launcher_art1.png ... launcher_art6.png

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
package.path = script_dir .. "modules/?.lua;" .. script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path

Gui = require("gui_module")

-- `art` = artwork filename (in data/) to show while this mode is selected
-- in the dropdown. Modules without a confirmed art mapping yet just fall
-- back to the base launcher_art.png.
local MODULES = {
    { name = "Wild Encounters", module = "wild", available = true, art = "launcher_art1.png" },
    { name = "Egg Hatching", module = "egg", available = true, art = "launcher_art2.png" },
    { name = "Static Encounters", module = "static", available = true, art = "launcher_art3.png" },
    { name = "Starters", module = "starters", available = true, art = "launcher_art4.png" },
    { name = "Fishing", module = "fishing", available = true, art = "launcher_art5.png" },
    { name = "Headbutt", module = "headbutt", available = true, art = "launcher_art6.png" },
    { name = "Friendship", module = "friendship", available = true, art = "launcher_art8.png" },
    { name = "Game Corner", module = "gamecorner", available = true, art = "launcher_art9.png" },
}

local shell = forms.newform(460, 900, "AutoCrystal Launcher")
forms.setlocation(shell, 100, 100)

forms.label(shell, "Select a mode:", 10, 10, 200, 20)

local PLACEHOLDER_TEXT = "-- Select a mode --"

local dropdownItems = { PLACEHOLDER_TEXT }
for _, entry in ipairs(MODULES) do
    table.insert(dropdownItems, entry.name)
end
local dropdown = forms.dropdown(shell, dropdownItems, 10, 30, 280, 20)

local statusLabel = forms.label(shell, "Idle - pick a mode and click Start.", 10, 90, 300, 20)

local CONTENT_Y_OFFSET = 130

-- Artwork switching: rather than redrawing ONE picturebox with a new
-- image each time the selection changes (repeated draws onto the same
-- picturebox proved unreliable elsewhere in this project - see
-- gui_module.lua's design notes), we create ONE picturebox PER distinct
-- artwork file, draw each exactly once (the "first draw always works"
-- pattern that's been reliable throughout), and just toggle which one
-- is Visible - a simple boolean property, not a repeated draw.
local ART_X, ART_Y, ART_W, ART_H = 335, 10, 110, 110
local artCanvases = {} -- filename -> picturebox handle
local currentArtFile = nil

local function get_or_create_art_canvas(filename)
    if artCanvases[filename] then return artCanvases[filename] end

    local canvas = forms.pictureBox(shell, ART_X, ART_Y, ART_W, ART_H)
    local path = script_dir .. "data/" .. filename
    local ok, err = pcall(forms.drawImage, canvas, path, 0, 0, ART_W, ART_H)
    if not ok then
        print("Couldn't load " .. path .. " (" .. tostring(err) .. ")")
    end
    artCanvases[filename] = canvas
    return canvas
end

local function show_art(filename)
    if filename == currentArtFile then return end
    for existingFile, canvas in pairs(artCanvases) do
        forms.setproperty(canvas, "Visible", existingFile == filename)
    end
    if artCanvases[filename] == nil then
        get_or_create_art_canvas(filename)
        forms.setproperty(artCanvases[filename], "Visible", true)
    end
    currentArtFile = filename
end

-- Pre-load the base artwork immediately so something shows before any
-- selection is made.
show_art("launcher_art.png")

-- Global (not local) so every module's ROM hooks can check "am I
-- actually the active one right now?" - hooks never get unregistered
-- once a module has been used, so without this check, a PREVIOUSLY-used
-- module's stale hooks would keep firing alongside the currently active
-- one's, corrupting its state.
ActiveModuleName = nil

local running = false
local sharedHud = nil
local initializedModules = {} -- module name -> the required module table
local loadedModule = nil
local loadedModuleName = nil
local btnStart, btnStop

-- Flags set by button callbacks (safe: just a variable write), consumed
-- by the main loop (safe: not a callback context).
local startRequestedEntry = nil
local stopRequested = false

local function on_start()
    local selectedText = forms.gettext(dropdown)
    if selectedText == PLACEHOLDER_TEXT then
        startRequestedEntry = "placeholder"
        return
    end
    for _, entry in ipairs(MODULES) do
        if entry.name == selectedText then
            startRequestedEntry = entry
            break
        end
    end
end

local function on_stop()
    stopRequested = true
end

btnStart = forms.button(shell, "Start", on_start, 10, 55, 100, 25)
btnStop  = forms.button(shell, "Stop", on_stop, 120, 55, 100, 25)
forms.setproperty(btnStop, "Enabled", false)

while true do
    emu.frameadvance()

    -- Live-preview the artwork for whatever's currently selected in the
    -- dropdown, even before Start is clicked. Polled each frame - cheap,
    -- and matches the safe "check in the main loop" pattern used
    -- throughout this file.
    do
        local selectedText = forms.gettext(dropdown)
        local selectedEntry = nil
        for _, entry in ipairs(MODULES) do
            if entry.name == selectedText then
                selectedEntry = entry
                break
            end
        end
        show_art((selectedEntry and selectedEntry.art) or "launcher_art.png")
    end

    if startRequestedEntry ~= nil then
        local chosen = startRequestedEntry
        startRequestedEntry = nil

        if chosen == "placeholder" then
            forms.settext(statusLabel, "Please select a mode first.")
        elseif not chosen.available then
            forms.settext(statusLabel, chosen.name .. " isn't built yet.")
        else
            if initializedModules[chosen.module] == nil then
                local mod = require(chosen.module)

                if sharedHud == nil then
                    sharedHud = Gui.create(shell, CONTENT_Y_OFFSET)
                end

                local ok = mod.init(shell, CONTENT_Y_OFFSET, sharedHud)
                if ok == false then
                    forms.settext(statusLabel, "Failed to initialize " .. chosen.name .. " - check the Lua console.")
                else
                    initializedModules[chosen.module] = mod
                end
            end

            local mod = initializedModules[chosen.module]
            if mod ~= nil then
                loadedModule = mod
                loadedModuleName = chosen.module
                ActiveModuleName = chosen.module

                -- Every time a module becomes active - whether for the
                -- first time or returning to one already used before -
                -- let it reconfigure which settings apply and clear out
                -- stale data from whatever was previously showing.
                if mod.on_switch_to then
                    mod.on_switch_to()
                end
                if mod.on_resume then
                    mod.on_resume()
                end

                running = true
                forms.setproperty(dropdown, "Enabled", false)
                forms.setproperty(btnStart, "Enabled", false)
                forms.setproperty(btnStop, "Enabled", true)
                forms.settext(statusLabel, "Running: " .. chosen.name)
            end
        end
    end

    if stopRequested then
        stopRequested = false
        running = false
        forms.setproperty(dropdown, "Enabled", true)
        forms.setproperty(btnStart, "Enabled", true)
        forms.setproperty(btnStop, "Enabled", false)
        forms.settext(statusLabel, "Stopped. Pick a mode and click Start.")
    end

    if running and loadedModule ~= nil then
        local done = loadedModule.step()
        if done then
            running = false
            forms.setproperty(dropdown, "Enabled", true)
            forms.setproperty(btnStart, "Enabled", true)
            forms.setproperty(btnStop, "Enabled", false)
            forms.settext(statusLabel, "Finished. Pick a mode and click Start.")
        end
    end
end
