local atkdef, spespc

local base_address, versionStr
local version = memory.readbyte(0x141)
local region  = memory.readbyte(0x142)
-- Determine base_address and human-readable version string
if version == 0x54 then  -- Crystal
    if region == 0x4A then
        base_address = 0xDC9D; versionStr = "Crystal JP"
    elseif region == 0x45 then
        base_address = 0xDCD7; versionStr = "Crystal US"
    else
        base_address = 0xDCD7; versionStr = "Crystal EU"
    end
elseif version == 0x55 or version == 0x58 then  -- Gold/Silver
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
    return  -- unsupported version
end

local partysize = memory.readbyte(base_address)
local dv_addr   = (base_address + 0x1D) + partysize * 0x30

-- === GUI setup ===
local frm       = forms.newform(200, 220, "Shiny Hunt Soft Resetting")
forms.setlocation(frm, 100, 100)
-- Script Name and Version
-- Title (simulated bold by overlapping labels)
local lblTitleA = forms.label(frm, "Shiny Starter Soft Resetting", 9, 5, 180, 20)
local lblTitle   = forms.label(frm, "Shiny Starter Soft Resetting", 10, 5, 180, 20)
local lblVersion = forms.label(frm, string.format("Version: %s", versionStr), 10, 25, 180, 20)
-- Main labels
local lblResets  = forms.label(frm, "Resets: 0",           10, 45, 180, 20)
local lblStatus  = forms.label(frm, "Status: Waiting...",  10, 65, 180, 20)
-- History headline
local lblHeader  = forms.label(frm, "Last Encounters:",   10,  90, 180, 20)
-- Last 5 encounters history labels
local history    = {}
local lblHist    = {}
for i = 1, 5 do
    lblHist[i] = forms.label(frm, "", 10, 110 + (i-1)*20, 180, 18)
end

-- Initialize reset counter
local reset_count = 0
forms.settext(lblResets, string.format("Resets: %d", reset_count))
forms.settext(lblStatus, "Status: Initialized")

-- Shiny test function
local function shiny(atk, spc)
    if spc == 0xAA then
        for _, v in ipairs({0x2A,0x3A,0x6A,0x7A,0xAA,0xBA,0xEA,0xFA}) do
            if atk == v then return true end
        end
    end
    return false
end

-- Main loop
while true do
    savestate.saveslot(3)
    -- Advance to encounter
    while memory.readbyte(base_address) == partysize do
        for _ = 1, 10 do emu.frameadvance() end
        joypad.set{A=true}
        emu.frameadvance()
    end
    emu.frameadvance()

    -- Read DVs and save
    atkdef = memory.readbyte(dv_addr)
    spespc = memory.readbyte(dv_addr + 1)
    savestate.save(1)

    -- Exit text
    joypad.set{B=true}
    emu.frameadvance()

    -- Compute stats
    local atkv = math.floor(atkdef / 16)
    local defv = atkdef % 16
    local spdv = math.floor(spespc / 16)
    local spcv = spespc % 16

    -- Update history
    local entry = string.format("Atk:%d Def:%d Spd:%d Spc:%d", atkv, defv, spdv, spcv)
    table.insert(history, 1, entry)
    if #history > 5 then table.remove(history) end
    for i = 1, #history do
        forms.settext(lblHist[i], history[i])
    end

    -- Check shiny
    if shiny(atkdef, spespc) then
        forms.settext(lblStatus, "Status: SHINY!!!")
        forms.settext(lblResets, string.format("Resets: %d", reset_count))
        vba.pause()
        break
    else
        reset_count = reset_count + 1
        forms.settext(lblResets, string.format("Resets: %d", reset_count))
        forms.settext(lblStatus, "Status: Discarded")
        savestate.loadslot(3)
    end

    emu.frameadvance()
end
