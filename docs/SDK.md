# OmniPlay SDK

Talk to the player's bike, walking pad, speed / cadence sensor, footpod and heart-rate strap
directly from your game, without the OmniPlay app. Runs in browsers, on Android, on desktop,
in any engine that has Lua or JavaScript.

Free for any game, open-source or commercial. One rule: OmniPlay support can't be sold
separately (DLC, add-on, unlock). See [`sdk/LICENSE`](../sdk/LICENSE).

| File | What it is |
|---|---|
| `lua/omniplay.lua` | the core in pure Lua (5.1 to 5.4, LuaJIT): LÖVE desktop and Android, love.js, GMod, any Lua |
| `js/omniplay.js` | the same core as a JavaScript module, plus `connectWebBluetooth()` for browsers |
| `android/OmniPlayBle.java` | the Bluetooth side for Android apps |

The core knows the devices: which services to use, decoding their data, the commands for
hills and belt speed, starting the machine, combining several devices, gait and start/stop
events. It does **no Bluetooth and no OS calls**. Your platform's Bluetooth gives it the bytes it
receives and sends the bytes it asks for. That's why the same code runs everywhere, and why
both cores are tested with the same recorded device data (`tests/sdk/vectors.json`).

Supported: FTMS bikes and treadmills (e.g. Christopeit EM 8000), Sperax walking pads, CSC speed /
cadence sensors in either mode (e.g. Rockbros C3), RSC footpods (e.g. Zwift RunPod), heart-rate
straps (e.g. Polar H10).

## The core

Lua (`OmniPlay.new`) and JS (`OmniPlay.create`) have the same functions; JS uses camelCase.

```lua
local OmniPlay = require("omniplay")
local op = OmniPlay.new{
  send = function(id, char_uuid, bytes) end,   -- write bytes to that characteristic (your Bluetooth)
  on_event = function(name, value) end,        -- "start", "stop", "gait" (walk / run / sprint / stopped)
  -- optional: allow_hills (true), allow_belt (false), max_belt_kmh (4), wheel_mm (2105),
  --           gait = { walk = { pad_kmh = 1, rpm = 30 }, run = { pad_kmh = 3.5, rpm = 70 }, sprint = { pad_kmh = 5, watts = 200, rpm = 85 } }
}
```

| Call | When |
|---|---|
| `OmniPlay.SERVICES` | the service UUIDs to scan for |
| `op:add(id, name, uuids)` | a device connected and its services / characteristics are known. Returns the kind, or nil if it isn't a fitness device OmniPlay knows |
| `op:notify_chars(id)` | the characteristics to subscribe to |
| `op:connected(id)` | subscriptions are on. Starts the machine (FTMS: take control, then start; no reset, which would clear the console's workout) |
| `op:receive(id, char_uuid, bytes)` | every notification, including the FTMS control point's answers (subscribe to everything `notify_chars` lists). Bytes: Lua string or byte array; JS Uint8Array / DataView / array |
| `op:update(dt)` | every frame, seconds since the last. Polls the Sperax, ramps the belt, sends hills |
| `op:values()` | the player's numbers (below) |
| `op:set_grade(pct)` | hill in % (−10 to 20), nil = flat. Bikes get resistance, treadmills that tilt get incline |
| `op:set_belt_speed(kmh)` | treadmill / walking pad speed. Only with `allow_belt`, never above `max_belt_kmh`, ramped, never starts a stopped belt |
| `op:remove(id)` | the device disconnected. Stops a belt the game was driving, then forgets it |
| `OmniPlay.walk_factor(grade)` | walking speed on a slope relative to flat (for walking pads on hilly terrain) |

`values()` returns `speed_kmh, cadence, power, hr, steps` (nil when unknown), `moving`, `gait`,
`kind`, `grade`, `distance_m` and `elapsed_s` (counted while moving), `devices` (id, name, kind,
label, fresh) and `sources` (which device each number came from). With several devices the
best source wins: a speed / cadence sensor decides cadence, speed and start/stop (it reacts within
a second, consoles often take 2 or more), a heart-rate strap decides heart rate.

FTMS machines get one command at a time: the next goes when the machine answers the last one, or
after 0.3 s without an answer (the way qdomyos-zwift drives hundreds of trainers). A newer hill or
belt speed replaces one still waiting, so a busy machine gets the latest, not a backlog. Your
`send` should just write and return; it never needs to wait.

Let the player choose `allow_belt` and `max_belt_kmh` themselves: they're standing on the belt.

Gait on a bike: walk from 30 rpm, run from 70 rpm, sprint from 85 rpm or 200 W (whichever comes first;
many bikes report power and cadence badly and late, so a cadence sensor decides when there is one). Walking pads and footpods go by speed.

## Browsers

```js
import { OmniPlay, connectWebBluetooth } from "./omniplay.js";
const op = OmniPlay.create({ onEvent: (name, value) => console.log(name, value) });
connectButton.onclick = () => connectWebBluetooth(op);   // the browser needs a click; call again for more devices
function frame(dt) { op.update(dt); const v = op.values(); /* move the player with v.speed_kmh */ }
op.setGrade(4.5);
```

`connectWebBluetooth` shows the browser's device picker, connects, subscribes and reconnects if
the device drops. Web Bluetooth exists in Chrome and Edge on Windows, Mac, Linux, ChromeOS and
Android, over HTTPS (or `localhost`). Safari, Firefox and all iPhone browsers don't have it, so
no website can reach the devices there.

## Android

`OmniPlayBle.java` scans, connects, subscribes and writes with Android's Bluetooth API, in a queue
(Android allows one Bluetooth operation at a time; that's why notifications often never arrive in
hand-written code). Wire its listener to the core:

| `OmniPlayBle.Listener` | core |
|---|---|
| `onFound(address, name, rssi)` | show it in your device list, then `ble.connect(address)` |
| `onServices(address, name, uuids)` | `add(address, name, uuids)`; return `notify_chars(address)`, or null if `add` returned nil |
| `onReady(address)` | `connected(address)` |
| `onData(address, char, bytes)` | `receive(address, char, bytes)` |
| `onLost(address)` | `remove(address)` (it reconnects by itself) |
| core `send(id, char, bytes)` | `ble.write(id, char, bytes)` |

Permissions: `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` on Android 12+, `BLUETOOTH`,
`BLUETOOTH_ADMIN` and `ACCESS_FINE_LOCATION` before that.

- **Unity / Godot / Kotlin / Java apps** call `OmniPlayBle` directly and use the JS core, or port the calls.
- **Capacitor / Cordova / React Native** can use `js/omniplay.js` with their own Bluetooth plugin instead.
- **LÖVE on Android** has no way to call Java from Lua out of the box. The APK needs a few lines of JNI
  in love-android's activity that forward `OmniPlayBle`'s listener to Lua and `send` back.

## Desktop

- **Browsers and Electron:** `connectWebBluetooth`.
- **LÖVE / native games:** the core with the platform's Bluetooth: WinRT on Windows (OmniPlay's own
  `omniplay_ble.dll` does this), BlueZ on Linux, CoreBluetooth on macOS. Or, when the OmniPlay app
  is installed, use its [API](API.md) instead; that also covers players whose devices are already
  connected to the app.

Don't connect to the same device from the app and your game at once: most devices accept only one connection.

## Tests

```
luajit tests/test_sdk.lua        # Lua core (also: lua5.1 / lua5.4)
node tests/sdk/test_sdk.mjs      # JS core + Web Bluetooth adapter against a fake browser
```
Both run `tests/sdk/vectors.json`, built by `tests/sdk/make_vectors.py`: device conversations with
packets captured from real devices (EM 8000, SPERAX_RM01) and from the Bluetooth specs, checking
values, the exact bytes sent and the events. Add a device there and both cores must pass it.
