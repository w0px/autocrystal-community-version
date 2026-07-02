-- stats.lua (lives in data/)
-- Shared lifetime stats across ALL modules (wild, starters, future ones).
-- One file, one set of numbers, regardless of which mode contributed to
-- them - "TOTAL ENCOUNTERS" means total across everything you've ever
-- run, not per-module.

local M = {}

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("(.*[/\\])") or "./"
local STATS_FILE_PATH = script_dir .. "wild_stats.txt"

M.totalEncounters = 0
M.totalShinies = 0
M.encountersSinceShiny = 0

function M.load()
    local f = io.open(STATS_FILE_PATH, "r")
    if f == nil then return end
    for line in f:lines() do
        local key, value = line:match("^(%a+)=(%d+)$")
        if key == "encounters" then
            M.totalEncounters = tonumber(value)
        elseif key == "shinies" then
            M.totalShinies = tonumber(value)
        elseif key == "sinceshiny" then
            M.encountersSinceShiny = tonumber(value)
        end
    end
    f:close()
end

function M.save()
    local f = io.open(STATS_FILE_PATH, "w")
    if f == nil then
        print("WARNING: couldn't write " .. STATS_FILE_PATH .. " - lifetime stats won't be saved")
        return
    end
    f:write(string.format("encounters=%d\nshinies=%d\nsinceshiny=%d\n",
        M.totalEncounters, M.totalShinies, M.encountersSinceShiny))
    f:close()
end

-- Call once per real encounter/reset attempt, from any module.
function M.record_encounter()
    M.totalEncounters = M.totalEncounters + 1
    M.encountersSinceShiny = M.encountersSinceShiny + 1
    M.save()
end

-- Call when a shiny is found, from any module.
function M.record_shiny()
    M.totalShinies = M.totalShinies + 1
    M.encountersSinceShiny = 0
    M.save()
end

return M
