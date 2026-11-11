# OmniPlay

Your bike is the controller. OmniPlay connects bikes, treadmills, walking pads, footpods and heart-rate straps to games: its own side-scroller you play with your legs, and, on Windows, a bridge that turns your movement into input for other games.

**Status: being rebuilt.** The old app has been removed; the new one is being written in LÖVE (Lua) for Windows, Android and the browser. The SDK below is ready to use.

## The SDK

The OmniPlay SDK talks to the devices straight from your game, **without the OmniPlay app**. Players install nothing but your game. Pure Lua (5.1 to 5.4, LuaJIT) and JavaScript cores, plus the Bluetooth side for Android. See [docs/SDK.md](docs/SDK.md).

Supported: FTMS bikes and treadmills (e.g. Christopeit EM 8000), Sperax walking pads, CSC speed / cadence sensors (e.g. Rockbros C3), RSC footpods (e.g. Zwift RunPod), heart-rate straps (e.g. Polar H10).

## Repo layout

- `sdk/`: the SDK (`lua/`, `js/`, `android/`) and its licence
- `docs/`: [SDK guide](docs/SDK.md) and the [mod API](docs/API.md) for games that talk to the OmniPlay app
- `gmod/omniplay_bridge/`: the Garry's Mod addon for the mod API
- `native/omniplay_ble.c`: the Windows Bluetooth (WinRT) helper, reused by the new app
- `tests/`: SDK tests, run against recorded device data (`luajit tests/test_sdk.lua`, `node tests/sdk/test_sdk.mjs`)

GitHub Actions tests the SDK on every push and packages it as the `OmniPlay-SDK` artifact.

## Licence

App: GPL-3.0. SDK: its own licence in [sdk/LICENSE](sdk/LICENSE) (free for any game; OmniPlay support can't be sold separately). The Sperax protocol notes come from [sperax-walkpad](https://github.com/Guhan-SenSam/sperax-walkpad) (MIT).
