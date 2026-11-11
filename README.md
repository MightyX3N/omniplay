# OmniPlay

Your bike is the controller. OmniPlay connects bikes, treadmills, walking pads, footpods and heart-rate straps to games: its own side-scroller you play with your legs, and, on Windows, a bridge that turns your movement into input for other games.

**Status: being rebuilt.** The new app is written in LÖVE (Lua) for Windows, Android and the browser. Done so far: the start screen, pairing your devices with a live test, and settings. The game, the Bridge for other games and playing together come next. The SDK below is ready to use.

## Running the app

- **Windows:** download `OmniPlay-windows` from the latest run in the Actions tab, unzip, start `OmniPlay.exe`.
- **From source:** install [LÖVE 11.5](https://love2d.org) and run `love app`. Add `--fake` for pretend devices (a bike, a walking pad, a cadence sensor and a heart-rate strap); keys 0-3 set how hard the pretend rider goes.
- **Build:** `sh build.sh` (Linux, needs `gcc-mingw-w64-x86-64`, `zip`, `curl`) makes `dist/OmniPlay.zip` and `dist/OmniPlay-SDK.zip`.

## The SDK

The OmniPlay SDK talks to the devices straight from your game, **without the OmniPlay app**. Players install nothing but your game. Pure Lua (5.1 to 5.4, LuaJIT) and JavaScript cores, plus the Bluetooth side for Android. See [docs/SDK.md](docs/SDK.md).

Supported: FTMS bikes and treadmills (e.g. Christopeit EM 8000), Sperax walking pads, CSC speed / cadence sensors (e.g. Rockbros C3), RSC footpods (e.g. Zwift RunPod), heart-rate straps (e.g. Polar H10).

## Repo layout

- `app/`: the app (LÖVE). `devices.lua` connects devices through the SDK, `bt/win.lua` is Windows Bluetooth, `bt/fake.lua` the pretend devices, `screens/` the screens
- `app/art/`: fonts (OFL), the Loops N Rings tiles (CC0) and the characters (Mucho Pixels; **not GPL**, see `app/art/muchopixels/LICENSE.txt`)
- `sdk/`: the SDK (`lua/`, `js/`, `android/`) and its licence
- `docs/`: [SDK guide](docs/SDK.md) and the [mod API](docs/API.md) for games that talk to the OmniPlay app
- `gmod/omniplay_bridge/`: the Garry's Mod addon for the mod API
- `native/omniplay_ble.c`: the Windows Bluetooth (WinRT) helper DLL
- `tests/`: SDK tests against recorded device data, and `tests/app/full.lua`, which plays the app with pretend devices:
  `OMNIPLAY_FAKE=1 OMNIPLAY_SCRIPT=$PWD/tests/app/full.lua xvfb-run -a love app`, and `tests/native/test_writes.c`,
  which checks the Windows Bluetooth helper never makes the game wait on a write
- `tools/pack_characters.py`: builds the character sheets from the Mucho Pixels pack

GitHub Actions tests the SDK and the app on every push, then builds the Windows app and the SDK zip.

## Licence

Code: GPL-3.0. Art has its own licences (see `app/art/`). SDK: its own licence in [sdk/LICENSE](sdk/LICENSE) (free for any game; OmniPlay support can't be sold separately). The Sperax protocol notes come from [sperax-walkpad](https://github.com/Guhan-SenSam/sperax-walkpad) (MIT).
