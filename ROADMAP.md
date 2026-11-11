# OmniPlay roadmap

OmniPlay has three parts:

1. **The SDK** connects bikes, treadmills, walking pads, footpods and heart-rate straps to any game,
   without the OmniPlay app. Ready to use.
2. **The OmniPlay app** pairs your devices and, later, works as a bridge that turns your movement
   into input for other games.
3. **The OmniPlay game** is a 3D world you ride, walk or run through on your own equipment. It is
   a fork of [REZVIVO](https://github.com/thpg/rezvivo) (GPL-3.0, Castle Game Engine): an
   open-source indoor-cycling app that builds real places from OpenStreetMap and also has
   hand-made Dream Worlds. OmniPlay adds the game around it.


## The game: what OmniPlay adds to REZVIVO

| | What it is |
|---|---|
| **Every device** | The OmniPlay SDK, ported to Pascal, replaces the game's own trainer code, so walking pads and treadmills work as well as bikes and sensors. Walk or run the same world you ride. |
| **Ghosts and segment races** | Every road you ride becomes a race against your own best and other players' best. Leaderboards per segment. |
| **Live riders nearby** | Anyone can host with one click through [playit.gg](https://playit.gg). Hosts are listed on a small OmniPlay server (a Cloudflare Worker), so you see players riding near you and can join, draft or race them. |
| **Exploring** | Places to discover, climbs to conquer, collectibles along the road, and a map that fills in as you ride. |
| **Progression** | Unlock kits, bikes, colours and Dream Worlds by riding. |
| **Tour mode** | A roguelike run: pick your next stage on a branching map, with elite climbs, rewards, and a run that ends if you blow up. |
| **Weekly events** | One route a week that everyone rides, with ghosts, so it works even when few people are online. |
| **Asset packs** | Like Minecraft resource packs: a folder or zip that replaces any texture, model, sound or sky. Players turn packs on and order them; anything a pack doesn't change falls back to the next. Packs change how the world looks, not its shape (the world is generated from map data). |

## Servers

The fork stops using rezvivo.com. Maps come from the public OpenStreetMap services the code already
supports. OmniPlay's own server is a Cloudflare Worker:

- **Ghosts and leaderboards** stored in Cloudflare R2 / D1 (free tier).
- **Host list** for live riding: a host registers its playit.gg address and where it is in the
  world; players ask for hosts near them. The game traffic itself goes player to host over
  playit.gg, not through the Worker.

## Order of work

1. Fork, build for Windows, rebrand, cut loose from rezvivo.com.
2. OmniPlay SDK in Pascal, replacing the game's trainer code.
3. Ghosts and segment races, with the Worker.
4. Live riders through playit.gg.
5. Exploring goals and progression.
6. Tour mode.
7. Weekly events.
8. Asset packs.

Each step is built, tested and shown before the next one starts.

## The app and the SDK

| | Status |
|---|---|
| SDK: FTMS bikes and treadmills, Sperax walking pads, CSC, RSC, heart rate | Done (Lua, JavaScript, Android) |
| SDK: one FTMS command at a time, non-blocking Windows writes | Done |
| App: start screen, pairing with a live test, settings | Done |
| Tested on real hardware: Christopeit EM 8000 bike, Rockbros C3 sensor, Sperax walking pad | Done |
| FTMS treadmills and footpods on real hardware | Needs testers |
| Bridge for other games (keyboard and gamepad output, mod API) | Planned |
