# PhysPlay

A Garry's Mod gamemode for riding and running through a real-scale island with your bike trainer,
walking pad or footpod (through [OmniPlay](https://github.com/MightyX3N/omniplay)), or with the keyboard.

Based on [OpenRadlr](https://github.com/Lethonium/OpenRadlr): the riding physics and the Valley Island
map and routes come from it. PhysPlay is not affiliated with or endorsed by OpenRadlr.

Licence: AGPL-3.0 (see LICENSE), like OpenRadlr.

## Playing
- Start OmniPlay and connect your device, then pick the PhysPlay gamemode in GMod (any map; gm_flatgrass is lightest).
- No device: hold W to ride (Shift for harder), A / D to change lane.
- `physplay_difficulty 0-100` how much of each hill your trainer feels (default 50).
- `physplay_weight <kg>` your weight for the physics (default 75).
- `physplay_route <id>` (server) rolling-hills, riverside-flats, forge-circuit, balcony-road, col-de-la-forge, cape-loop, island-tour.
- `physplay_restart` back to the start line.
