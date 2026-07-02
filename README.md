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

<img width="698" height="452" alt="image" src="https://github.com/user-attachments/assets/1e42e0d1-a74f-464d-910b-987cd6fced1e" />

- In the console select the launcher.lua

![image](https://github.com/w0px/autocrystalprivate/assets/152983879/ae20fbce-1346-4566-8643-486ca3d4d655)

<img width="617" height="147" alt="image" src="https://github.com/user-attachments/assets/e3a24d3c-8313-4932-a01d-2f9476cca13d" />

- in the launcher select a module you want to run
<img width="463" height="405" alt="image" src="https://github.com/user-attachments/assets/8359c386-c4a6-47a1-bcca-45ea3dcd2b3c" />




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

## Wild Encountes Module

Self-correcting movement (auto-detects safe directions)
RAM-verified menu navigation, self-corrects on dropped inputs


<img width="454" height="828" alt="image" src="https://github.com/user-attachments/assets/8fe1a5a9-6e31-4098-a79a-59e4bdbb1f42" />



### Stop Conditions

- **Perfect DVs (15/15/15/15)** – Stops when a Pokémon with perfect DVs is encountered
- **Perfect Negative DVs (0/0/0/0)** – Stops when a Pokémon with perfect negative DVs is encountered
- **Specific Species (Name or ID)** – Stops when a specified Pokémon is encountered, whether shiny or non-shiny
- **Held Item (Any or Specific)** – Stops when a Pokémon holding any or a specified item is encountered, if a specific item is in the Allowlist the bot will only stop if that item is encountered
- **Shiny Pokémon** – Always stops upon encountering a shiny Pokémon

### Kill Mode

- Automatically battles non-shiny Pokémon using the first move
- Species Allowlist to avoid unfavorable matchups, the bot will only battle the Pokemon in the Allowlist (ID or Name)
- Automatically flees when all PP for the selected move is depleted
- Automatically cancels Pokémon evolutions
- Pauses auto-leveling when a Pokémon attempts to learn a new move (unless an empty move slot is available)

<img width="800" height="486" alt="2cd5b3901b2209c85db0407c3c6df5ae-ezgif com-video-to-gif-converter" src="https://github.com/user-attachments/assets/138b7d12-612b-4572-a941-e44c0ccc7467" />

- Allowlist is set to Hoothoot only, so the bot will escape from any other encounter

<img width="800" height="506" alt="fd2bc9aa5d130eeae9db2edcb0025bf5-ezgif com-video-to-gif-converter" src="https://github.com/user-attachments/assets/7eb87d91-bb47-4782-bc4b-83257861b5a7" />

### Verbose Logging

Displays every action performed by the bot in the console. Primarily intended for debugging and troubleshooting.


## Starters Module

Place the bot directly in front of the starter Pokémon without interacting with the Poké Ball.

<img width="955" height="519" alt="image" src="https://github.com/user-attachments/assets/15215323-254a-4efb-82a9-2776d4979c91" />

Save the game to BizHawk Save State 1

<img width="1031" height="583" alt="image" src="https://github.com/user-attachments/assets/64bda520-fdb3-4adb-b8bb-5a815c1aaf85" />

Start the Starters module from the launcher

<img width="1495" height="614" alt="image" src="https://github.com/user-attachments/assets/fc6c480e-af67-41f3-82f1-3a309e9dcdda" />

Once the bot is running, verify that the starter Pokémon have different stats after each soft reset

<img width="206" height="171" alt="image" src="https://github.com/user-attachments/assets/cd4da4b3-f1b7-49f3-909f-a79f0ec11812" />

If the stats remain the same, the save state was not created correctly, and the bot will keep encountering the same starter repeatedly


## Headbutt Module

- position infront of a headbutt tree and start the module

<img width="504" height="475" alt="image" src="https://github.com/user-attachments/assets/4ab1a4a0-e977-4c50-8edd-9a53b675d07a" />

### How Headbutt Trees work in Gen 2

A tree's identity is permanently fixed, not random per attempt. Which encounter table a tree draws from (and its encounter rate — some trees are 80%, some 50%, some as low as 10% "rare") is determined by a formula using your Trainer ID plus that tree's exact map coordinates. It's baked into your save file the moment that tree exists on the map — it never rotates, never moves to a different tree, and doesn't change between attempts.
Trees don't deplete. Unlike the HGSS remakes (where a tree that gives nothing on the first try stays empty forever), Gen 2's mechanic has no exhaustion at all — every headbuttable tree has some nonzero encounter chance, permanently, no matter how many times you've already hit it. There are 2 Types of Trees Forest Group and Mountain Group, both with shared and unique encounters.

## Encounter Mechanics

The encounter rate and encounter table of each tree depends on the tree's index and the player's **Trainer ID number**.

The tree's index is an integer from **0 to 9**, which depends on its **X** and **Y** coordinates on the map—that is, its distance from the westernmost and northernmost edges, respectively. Specifically, the tree's index is calculated using the following formula:

```
TreeIndex = ⌊(X·Y + X + Y) / 5⌋ mod 10
```

The encounter rate and tree type depends on the last digit of the player's Trainer ID.

- If a tree's index is equal to that ID digit, the tree is a **"high-encounter tree"** and its encounter rate is **80%**.
- If the tree's index is one of the next four indices after that ID digit (wrapping back around to 0 after 9), the tree is a **"moderate-encounter tree"** and its encounter rate is **50%**.
- Otherwise, the tree is a **"moderate-encounter tree"** and its encounter rate is **10%**.
- High Encounter Trees can be calculated [here](http://tshadowknight.com/Headbutt%20Grid.htm)

## Encounter Rate by Index and Trainer ID

The following is a table depicting the encounter rate of the tree, based on the tree index and the last digit of the player's Trainer ID. Tree indexes are displayed in rows, while Trainer ID digits are displayed in columns.

An **80%** encounter rate indicates the tree is a **"high-encounter tree"**. Otherwise it is a **"moderate-encounter tree"**.

| Tree Index | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|------------|---|---|---|---|---|---|---|---|---|---|
| **0** | 80% | 10% | 10% | 10% | 10% | 10% | 50% | 50% | 50% | 50% |
| **1** | 50% | 80% | 10% | 10% | 10% | 10% | 10% | 50% | 50% | 50% |
| **2** | 50% | 50% | 80% | 10% | 10% | 10% | 10% | 10% | 50% | 50% |
| **3** | 50% | 50% | 50% | 80% | 10% | 10% | 10% | 10% | 10% | 50% |
| **4** | 50% | 50% | 50% | 50% | 80% | 10% | 10% | 10% | 10% | 10% |
| **5** | 10% | 50% | 50% | 50% | 50% | 80% | 10% | 10% | 10% | 10% |
| **6** | 10% | 10% | 50% | 50% | 50% | 50% | 80% | 10% | 10% | 10% |
| **7** | 10% | 10% | 10% | 50% | 50% | 50% | 50% | 80% | 10% | 10% |
| **8** | 10% | 10% | 10% | 10% | 50% | 50% | 50% | 50% | 80% | 10% |
| **9** | 10% | 10% | 10% | 10% | 10% | 50% | 50% | 50% | 50% | 80% |

## Analysis

Since **X** and **Y** are interchangeable in the tree index formula, it is possible to "fix" one dimension to consider traveling along the other. Substituting **Z** for the fixed axis and **n** for the axis that will be traversed, the formula becomes:

```
TreeIndex = ⌊(Z·n + Z + n) / 5⌋ mod 10
          = ⌊((Z + 1)·n + Z) / 5⌋ mod 10
```

This result shows that, if a single row or column of trees is traversed, moving to an adjacent tree increases the tree's index by **(Z + 1) / 5** (modulo 10), where **Z** is the distance of that row or column from its origin edge (north or west). This means that the closer a row or column is to the edge, the slower the indices of those trees change as the row or column is traversed.



