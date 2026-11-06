# OmniPlay

Free, open-source Windows app that turns your fitness gear into a game controller. Walk on a treadmill, run with a footpod or pedal an exercise bike, and your character moves in the game.

**Status: early development.** What works today is a probe that connects to a Sperax walking pad and reads live state, speed and steps.

## Planned
- **Devices:** standard Bluetooth fitness gear (FTMS treadmills, bikes, cross trainers and rowers; footpods such as the Zwift RunPod; speed/cadence sensors; power meters; heart-rate straps), plus brand protocols, one driver file each. Sperax walking pads already work.
- **Any game:** keyboard and Xbox controller emulation, with per-game profiles and walk/run/sprint thresholds.
- **Mod API:** a localhost WebSocket. Games get live speed, cadence and power, and can send hills and terrain back, which OmniPlay turns into bike resistance or treadmill incline.
- **Garry's Mod gamemode:** a Zwift-style world for GMod, built on the API.

## Device support
| Device | Status |
|---|---|
| Sperax walking pads (`SPERAX_RM01`, e.g. P1) | Working in the probe |
| Zwift RunPod and other footpods | Planned |
| FTMS treadmills, bikes, rowers (e.g. Christopeit EM 8000) | Planned |

No pairing needed: OmniPlay connects directly using the Windows Bluetooth API, the same way Zwift does. Requires Windows 10 (version 1703 or newer) or Windows 11.

## Repo layout
- `app/`: the LÖVE (Lua) app; `app/drivers/` has one file per device protocol
- `native/omniplay_ble.c`: small Bluetooth helper DLL, called from Lua via FFI
- `tests/`: decoder tests built from real captured frames, plus a headless smoke test
- `build.sh`: builds `dist/OmniPlay.zip` (GitHub Actions runs it on every push; download it from the Actions tab)

## Licence
GPL-3.0. The Sperax protocol notes come from [sperax-walkpad](https://github.com/Guhan-SenSam/sperax-walkpad) (MIT).
