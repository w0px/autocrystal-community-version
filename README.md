![MuIXxKj](https://github.com/w0px/autocrystal-community-version/assets/152983879/0ac9ab7d-fbea-4395-974f-002211fae965)

# autocrystal Shiny Hunting Bot
 
 API Project: https://github.com/w0px/w0p-autocrystal

## Functions

### Wild Encounter Hunting ✅
- Shiny Detection
- Held Item Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications
- Automatic Level Grinding
- Targeted Encounter Hunting

### Starter Hunting ✅
- Shiny Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications

### Fishing Encounter Hunting 🟡
- Shiny Detection
- Held Item Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications
- Automatic Level Grinding
- Targeted Encounter Hunting

### Static Encounter Hunting 🟡
- Shiny Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications

### Headbutt Encounter Hunting 🟡
- Shiny Detection
- Held Item Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications
- Automatic Level Grinding
- Targeted Encounter Hunting

### Egg Hunting 🟡
- Shiny Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications


## Supported Versions:

Crystal US✅ EU✅ JP✅

Silver US✅ EU🟡 JP🟡

Gold US✅ EU🟡 JP🟡


## How to run

download latest BizHawk release
https://github.com/TASEmulators/BizHawk/releases/

- Download a official Crystal ROM

- Start the ROM in the BizHawk Emulator

- In the BizHawk menu select LUA Console

![image](https://github.com/w0px/autocrystalprivate/assets/152983879/3f4e8e0c-d3a1-49fe-9853-f0aac4a04d2e)

- In the console select the launcher.lua

![image](https://github.com/w0px/autocrystalprivate/assets/152983879/ae20fbce-1346-4566-8643-486ca3d4d655)
<img width="617" height="147" alt="image" src="https://github.com/user-attachments/assets/e3a24d3c-8313-4932-a01d-2f9476cca13d" />



## Emulator Speed

100% ✅

200% ✅

400% ✅

potentially even more ✅


## Discord Notifications
<img width="571" height="173" alt="image" src="https://github.com/user-attachments/assets/4c882ee4-8eab-4c6c-a6d0-7c9113ad187b" />




BizHawk's comm.httpPost can't send Discord's required JSON format directly (it wraps everything as a form field, which Discord rejects). A tiny local relay handles the translation instead.

### 1. Create a webhook


Discord → Server Settings → Integrations → Webhooks → New Webhook
Copy the Webhook URL


### 2. Set up the relay


Open discord_relay.ps1, paste your webhook URL into $DiscordWebhookUrl
Double-click start_relay.bat — a console window opens and must stay running the whole time you're botting


### 3. Point BizHawk at the relay

move the DCNotifications_start.bat file into your downloaded Bizhawk directory and double click to start the emulator


### 4. Configure the bot

in any module, check "Send Discord notification (shiny/stop)" in the GUI.


# Modules

## Wild Encounter Module (wild.lua)

Self-correcting movement (auto-detects safe directions)
RAM-verified menu navigation, self-corrects on dropped inputs
Full DV + shiny detection
Species & held-item names (Dex + full Gen II item table)

<img width="987" height="642" alt="image" src="https://github.com/user-attachments/assets/dff36482-9ce3-4b5b-be0d-a3cfe5cf1310" />


### Stop Conditions

Perfect DVs (15/15/15/15)
Perfect Negative DVs (0/0/0/0)
Specific species (ID or name)
Held item (any or specific)
Shiny (always)


### Kill Mode

Auto-fights non-shinies with first move
Species allowlist (avoid bad matchups)
Flees if PP hits 0


https://github.com/user-attachments/assets/633d66f2-3de2-486c-b88d-c53aa299ed70



https://github.com/user-attachments/assets/bc844c39-1e5c-4dc0-9c40-d2bc32267d49




Live encounter/shiny/runtime/status
Last encounter + 8-entry history
All settings adjustable live






