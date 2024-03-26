Mem = require("/data/Memory")

local desired_species = -1
local atkdef
local spespc
local species
local item = 0
local shinyvalue = 0
local printedMessage = false
local enemy_addr
local daytime
initialX, initialY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)
mapgroup, mapnumber = memory.readbyte(0xdcb5), memory.readbyte(0xdcb6)
local version = memory.readbyte(0x141)
local region = memory.readbyte(0x142)
local encounterCount
local framesInDirection = 0
local maxFramesInDirection = 1
local highestSpeSpc = 0
local highestAtkDef = 0
Mem.SetRomBankAddress("Crystal")
input = {}
actions = {"B", "Right", "Right", "Down", "A","A"}
currentActionIndex = 1
framesInAction = 0
framesPerAction = 1
input2 = {}
actions2 = {"Right", "Up", "Left", "Down"}
currentActionIndex2 = 1
framesInAction2 = 0
framesPerAction2 = 1

local base_address
local version = memory.readbyte(0x141)
local region = memory.readbyte(0x142)

if version == 0x54 then
    if region == 0x44 or region == 0x46 or region == 0x49 or region == 0x53 then
        print("EUR Crystal detected")
        base_address = 0xdcd7
    elseif region == 0x45 then
        print("USA Crystal detected")
        base_address = 0xdcd7
    elseif region == 0x4A then
        print("JPN Crystal detected")
        base_address = 0xdc9d
    end
elseif version == 0x55 or version == 0x58 then
    if region == 0x44 or region == 0x46 or region == 0x49 or region == 0x53 then
        print("EUR Gold/Silver detected")
        base_address = 0xda22
    elseif region == 0x45 then
        print("USA Gold/Silver detected")
        base_address = 0xda22
    elseif region == 0x4A then
        print("JPN Gold/Silver detected")
        base_address = 0xd9e8
    elseif region == 0x4B then
        print("KOR Gold/Silver detected")
        base_address = 0xdb1f
    end
else
    print(string.format("Unknown version, code: %4x", version))
    print("Script stopped")
    return
end

local dv_flag_addr = enemy_addr + 0x21
local species_addr = enemy_addr + 0x22
local item_addr = enemy_addr - 0x05
local daytime_addr = 0xd269

local LoadBattleMenuAddr = Mem.BankAddressToLinear(0x9, 0x4EF2)
local EnemyWildmonInitialized = Mem.BankAddressToLinear(0xF, 0x7648)

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
    input = {[btn]=true}
    for i=1,4 do -- Hold button for 4 frames (make sure the game registers it)
        joypad.set(input)
        emu.frameadvance()
    end
    emu.frameadvance() -- Add one frame buffer so consecutive button presses don't blend together
end

local have_battle_controls = false
Mem.RegisterROMHook(LoadBattleMenuAddr, function()
    --print("Battle menu loaded")
    have_battle_controls = true
end, "Detect Battle Menu")

Mem.RegisterROMHook(EnemyWildmonInitialized, function()
    --print("combat started")
    item = memory.readbyte(item_addr)
        atkdef = memory.readbyte(enemy_addr)
        spespc = memory.readbyte(enemy_addr + 1)
        highestAtkDef = math.max(highestAtkDef, atkdef)
        highestSpeSpc = math.max(highestSpeSpc, spespc)
        species = memory.readbyte(species_addr)

    print(string.format("Atk: %d Def: %d Spe: %d Spc: %d", math.floor(atkdef/16), atkdef%16, math.floor(spespc/16), spespc%16))
    
end, "Tell Display Battle Started / sending data")

while true do
    emu.frameadvance()

    if memory.readbyte(species_addr) == 0 then
        have_battle_controls = false

        for i=1,8,1 do
            emu.frameadvance()
            joypad.set({B=true})
        end


        local currentX, currentY = memory.readbyte(0xdcb8), memory.readbyte(0xdcb7)

        if currentX ~= initialX or currentY ~= initialY and memory.readbyte(species_addr) == 0 then
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
            joypad.set({Right=true})
            emu.frameadvance()
            joypad.set({Right=false})
            joypad.set({Left=true})
            emu.frameadvance()
            joypad.set({Left=false})
            joypad.set({Down=true})
            emu.frameadvance()
            joypad.set({Down=false})
            joypad.set({Up=true})
            emu.frameadvance()
            joypad.set({Up=false})

        end

    else
        while memory.readbyte(dv_flag_addr) ~= 0x01 do
            emu.frameadvance()
            press_button("B")
        end



        item = memory.readbyte(item_addr)
        atkdef = memory.readbyte(enemy_addr)
        spespc = memory.readbyte(enemy_addr + 1)
        highestAtkDef = math.max(highestAtkDef, atkdef)
        highestSpeSpc = math.max(highestSpeSpc, spespc)
        species = memory.readbyte(species_addr)

        
        if shiny(atkdef, spespc) then
            shinyvalue = 1
            print("Shiny found!!")
            break
        end

     
    end

    if memory.readbyte(species_addr) ~= 0 then

        while not have_battle_controls do
            emu.frameadvance()
            currentActionIndex = 1
            press_button("B")
        end

        local currentAction = actions[currentActionIndex]

        press_button(currentAction)

        framesInAction = framesInAction + 1

        if framesInAction >= framesPerAction then
            framesInAction = 0
            currentActionIndex = (currentActionIndex % #actions) + 1
            emu.frameadvance()
        end
    end
end