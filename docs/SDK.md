# OmniPlay SDK

Make your game move with the player's real bike, walking pad or footpod, and send hills back to
the machine. The player runs the OmniPlay app; your game reads it through a small block of
shared memory on the same PC. Reading takes about a microsecond, so you can do it every frame.

The SDK is free for any game, open-source or commercial. The one rule: OmniPlay support can't be
sold separately (as DLC, an add-on or an unlock). See [`sdk/LICENSE`](../sdk/LICENSE).

| You make | Use | Files |
|---|---|---|
| a Garry's Mod gamemode or addon | the `OmniPlay.*` Lua API from the addon | `gmod/omniplay_bridge` (+ the module, installed by OmniPlay) |
| a LÖVE / LuaJIT game | one Lua file, no DLL | `love/omniplay.lua` |
| a C / C++ game | compile one file in, or link the DLL | `omniplay.h`, `omniplay.c` / `bin/x64/omniplay_client.dll` |
| Unity, Godot (C#), anything with a C FFI | the DLL | `bin/x64/omniplay_client.dll`, `examples/unity/OmniPlay.cs` |
| a website | not possible: OmniPlay refuses browsers, so websites can't control someone's machine | |

Other languages can read the shared memory directly; the layout is at the bottom of `omniplay.h`.
WebSocket access for tools and scripts is in [API.md](API.md).

## How it behaves

- **Always optional.** When OmniPlay isn't running, every read returns nothing and every request is
  ignored. Keep keyboard / controller controls; players without OmniPlay still play.
- **Values** (OmniPlay → game, 20 times a second): speed, cadence, power, heart rate, the hill
  currently on the machine, distance, `moving`, `gait` (stopped / walk / run / sprint from the
  player's profile) and the kind of machine (bike, treadmill, footpod). Unknown numbers are
  nil / NaN. The full state as JSON also has the device name, whether the camera sees the feet, the
  recording state and more ([API.md](API.md#state-omniplay--game)).
- **Requests** (game → OmniPlay) are state, not events. OmniPlay keeps the last values:
  - `game`: your game's name, shown in OmniPlay and saved with the workout.
  - `grade`: hill in % (−10 to +20; nil / NaN = flat). OmniPlay ramps it smoothly and only applies it if the player allows hills.
  - `belt_speed`: treadmill speed in km/h. Only if the player allows it; never above their max.
  - `take_input`: true = OmniPlay stops pressing keys, because you read the values yourself.
- **Connected while you read.** Your game counts as connected while it keeps reading (every frame is
  fine, at least once a second). 3 seconds after it stops, OmniPlay flattens the hill and turns the
  keys back on. Call `release()` on quit to do that at once.
- **Ride routes vs. games:** while a game sends a hill, it wins over the player's GPX route.

## Garry's Mod

Ship the `omniplay_bridge` addon with your gamemode (or `AddCSLuaFile` + `include` its one file).
In OmniPlay's Games tab the player presses **Install**: that puts the module
(`gmcl_omniplay_win32.dll` / `gmcl_omniplay_win64.dll`) into `garrysmod/lua/bin` and the addon into
`garrysmod/addons`. Without the module the addon falls back to files in `garrysmod/data/omniplay`;
the API is the same either way (`OmniPlay.Native` says which one is in use).

Client:
```lua
OmniPlay.IsConnected()          -- OmniPlay running and sending
OmniPlay.Get()                  -- table or nil: speed_kmh, cadence, power, hr, steps, moving, gait, grade,
                                --   connected, device = { name, kind, hills, belt_speed, max_speed }, distance_m, elapsed_s
OmniPlay.SetGame("My Gamemode")
OmniPlay.SetGrade(4.5)          -- nil = flat
OmniPlay.SetBeltSpeed(3)
OmniPlay.TakeInput(true)        -- stop OmniPlay's key presses while your gamemode reads Get()
OmniPlay.SetInfo("text")        -- a line in OmniPlay's log, for debugging
hook.Add("OmniPlay_Data", "x", function(d) end)   -- every new state
```

Server (each client forwards its data up to 10 times a second; treat it like any client input):
```lua
ply:OmniPlayData()              -- speed_kmh, cadence, power, hr, moving, gait, grade, kind, camera
ply:OmniPlaySetGrade(4.5)       -- nil = flat
ply:OmniPlayTakeInput(true)
hook.Add("OmniPlay_PlayerData", "x", function(ply, d) end)
```

Console: `omniplay_status` (shows module or data folder, and the live numbers), `omniplay_hill 5`.

A complete small example: [`examples/gmod/omniplay_example.lua`](../sdk/examples/gmod/omniplay_example.lua)
(moves players with their real speed in `SetupMove`, sends the slope under the player as the hill).

Tips for gamemodes:
- Movement: `SetupMove` on the server with `ply:OmniPlayData().speed_kmh` (1 km/h ≈ 14.6 units/s).
  Let `cmd:GetForwardMove()` win when the player uses the keyboard.
- Hills: trace the ground ahead of the player a few times a second and `SetGrade` the slope.
  Clamp jumps from props or stairs; OmniPlay already smooths at 4 % per second.
- Call `TakeInput(true)` only once you actually move the player from the data, otherwise
  OmniPlay's W-key output is the fallback that already works in every gamemode.

## LÖVE / LuaJIT

Copy `love/omniplay.lua` next to `main.lua`:
```lua
local omniplay = require("omniplay")
omniplay.set_game("My Game")
function love.update(dt)
  local v = omniplay.values()   -- nil when OmniPlay isn't running
  if v then player.speed = v.speed_kmh / 3.6 end
  omniplay.set_grade(slope_here) -- nil = flat
end
function love.quit() omniplay.release() end
```
`values()` returns `speed_kmh, cadence, power, hr, grade, distance_m, elapsed_s, steps, moving,
gait, kind, connected`. `state_json()` returns the full state as JSON text and a sequence number.
Setters: `set_game`, `set_grade`, `set_belt_speed`, `take_input`, `set_info`, `release`.
Works on Windows and Linux. Example: [`examples/love/main.lua`](../sdk/examples/love/main.lua).

## C / C++ and the DLL

```c
#include "omniplay.h"
OmniPlayValues v;
omniplay_set_game("My Game");
if (omniplay_values(&v)) speed = v.speed_kmh;   /* every frame */
omniplay_set_grade(4.5f);                       /* NAN = flat */
omniplay_release();                             /* on quit */
```
Compile `omniplay.c` into your game, or use `bin/x64/omniplay_client.dll` (`bin/x86/` for 32-bit)
with `-DOMNIPLAY_USE_DLL`. All functions are plain C (`cdecl`), so C#, Rust, Python ctypes, Godot
GDExtension and others can call the DLL. C# bindings: [`examples/unity/OmniPlay.cs`](../sdk/examples/unity/OmniPlay.cs).

## Testing without the app or hardware

`tools/omniplay_sim.lua` pretends to be OmniPlay with a simulated rider and prints what your game
asks for:
```
luajit tools/omniplay_sim.lua            # bike, 20-30 km/h in waves (power follows your hill)
luajit tools/omniplay_sim.lua walk       # walking pad at 4 km/h
luajit tools/omniplay_sim.lua stop       # connected, standing still
luajit tools/omniplay_sim.lua bike 10    # stop after 10 s, for automatic tests
```
It runs on Windows and Linux, so automatic tests on a Linux machine work too: start the simulator,
run your game (or its logic in plain LuaJIT with `love/omniplay.lua`), check what it printed.

## Version

Shared-memory layout version 1 (`OMNIPLAY_VERSION`). New fields get added to the JSON state;
the fixed layout only changes with a new version number and a new shared-memory name, so old
games keep working.
