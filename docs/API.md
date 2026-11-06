# OmniPlay mod API

Games and mods can read live data from the user's bike, walking pad or footpod, and send
hills or belt speed back. OmniPlay must be running on the same PC.

## Two ways to connect

**WebSocket** — `ws://127.0.0.1:21890`
Only local connections are accepted. Requests with an `Origin` header (web browsers) are
refused, so websites can't control the user's machine. `GET http://127.0.0.1:21890/state`
returns the latest state once, for quick checks.

**File bridge** (Garry's Mod, or any game that can only read/write files)
OmniPlay finds Garry's Mod through Steam and uses `garrysmod/data/omniplay/`:
- `live.txt` — the state below, rewritten about 10 times a second (atomically).
- `cmd.txt` — written by the game. Include a `beat` number that changes every write
  (every 0.5 s is fine); OmniPlay treats the game as gone 3 s after the beat stops changing.

For GMod, use the `omniplay_bridge` addon (`gmod/omniplay_bridge`) instead of touching the files.

## State (OmniPlay → game)

```json
{"type":"state","v":1,"seq":1234,"app":"OmniPlay","connected":true,
 "device":{"name":"HT2405118","kind":"bike","hills":true,"belt_speed":false},
 "speed_kmh":25.6,"cadence":61,"power":140,"hr":130,"steps":null,
 "moving":true,"gait":"run","grade":4.0,
 "recording":"recording","distance_m":1520,"elapsed_s":312}
```

- `device.kind`: `bike`, `treadmill` or `footpod`.
- `gait`: `stopped`, `walk`, `run` or `sprint`, from the user's active game profile.
- `power`, `hr`, `steps` are missing when the device doesn't report them.
- `grade`: the hill currently applied to the machine.
- `camera`: true when OmniPlay's camera page is watching the user's feet. Then `moving` and `cadence`
  come from the camera (instant), and `device_cadence` is what the device itself reports.
- When OmniPlay closes, `live.txt` gets `{"closed":true}`.

## Requests (game → OmniPlay)

Send a JSON object with any of these fields (all optional):

| field | meaning |
|---|---|
| `game` | your game's name, shown in OmniPlay and saved with the workout |
| `grade` | hill in %, −10 to +20. `false` = flat. Smoothed at 4 %/s. Only applied if the user enabled "Games may set hills". |
| `belt_speed` | treadmill speed in km/h. Only if the user enabled it, capped at their max, ramped at 0.5 km/h per second. |
| `take_input` | `true` = OmniPlay stops pressing keys while you're connected, because you read the data yourself. |

Requests are state, not events: send the current values whenever they change (or with every
heartbeat). When your game disconnects, OmniPlay ramps the hill back to flat and resumes the keys.

## Garry's Mod addon

Client:
```lua
OmniPlay.IsConnected()
OmniPlay.Get()              -- the state table above, or nil
OmniPlay.SetGame("PhysPlay")
OmniPlay.SetGrade(4.5)      -- nil = flat
OmniPlay.SetBeltSpeed(3)
OmniPlay.TakeInput(true)
hook.Add("OmniPlay_Data", "x", function(d) end)
```

Server (each client forwards its data 4 times a second):
```lua
ply:OmniPlayData()          -- speed_kmh, cadence, power, hr, moving, gait, grade, kind
ply:OmniPlaySetGrade(4.5)
ply:OmniPlayTakeInput(true)
hook.Add("OmniPlay_PlayerData", "x", function(ply, d) end)
```

Console: `omniplay_status` prints the live data, `omniplay_hill 5` tries a 5 % hill.
