# Builds tests/sdk/vectors.json: the same device conversations run against the Lua and the JS SDK.
# Packets marked "real" were captured from Patrick's devices; the others follow the Bluetooth specs.
import json
FULL = lambda s: "0000%s-0000-1000-8000-00805f9b34fb" % s
PEDAL = "FE 1F 00 0A 00 00 AA 00 00 00 00 00 00 0C 00 8C 00 00 00 00 00 00 00 00 82 00 3D 00 00 00"
IDLE = "FE 1F 00 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"  # real, EM 8000
SPX_RUN = ["F5 18 00 19 00 00 10 00 00 00 3E 00 01 00 01 00 05 14 00 00 00 AC 4E FA",  # real, SPERAX_RM01
           "F5 19 00 19 00 00 10 00 00 00 3E 00 01 00 01 00 05 15 00 00 00 D1 F0 03 FA",
           "F5 18 00 19 00 00 10 00 00 00 41 00 02 00 01 00 0A 1C 00 00 00 63 83 FA"]
SPX_STOP = "F5 19 00 19 00 00 02 00 00 00 43 00 02 00 01 00 0E 00 00 00 00 F0 08 DF FA"  # real
def spx_crc(b):
    crc = 0xFFFF
    for v in b:
        crc ^= v
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA327 if crc & 1 else crc >> 1
    return crc & 0xFF, crc >> 8
def spx(payload):
    f = [0xF5, len(payload) + 6, 0] + payload
    lo, hi = spx_crc(f)
    f += [lo, hi, 0xFA]
    e = [f[0], 0, f[2]]
    for v in f[3:-1]:
        e += [0xF0, v - 0xF0] if v >= 0xF0 else [v]
    e += [0xFA]; e[1] = len(e)
    return e
def h(b): return " ".join("%02X" % x for x in b)
def crank(revs, t): return h([0x02, revs % 256, revs // 256 % 256, t % 256, t // 256 % 256])
def wheel(revs, t): return h([0x01, revs % 256, revs // 256 % 256, revs // 65536 % 256, revs // 16777216 % 256, t % 256, t // 256 % 256])

S = []
# 1. detection
S.append({"name": "detect", "steps": [
  {"detect": [FULL("1826"), FULL("2ad2"), FULL("2ad9")], "name": "HT2405118", "kind": "ftms_bike"},
  {"detect": ["1826", "2acd"], "name": "Treadmill", "kind": "ftms_treadmill"},
  {"detect": ["fff0", "fff1", "fff2"], "name": "SPERAX_RM01", "kind": "sperax"},
  {"detect": ["1816"], "name": "ROCKBROS C3", "kind": "csc"},
  {"detect": ["180D", "2A37"], "name": "Polar H10", "kind": "hr"},
  {"detect": ["1814", "2a53"], "name": "RunPod", "kind": "rsc"},
  {"detect": ["180f", "1800"], "name": "TV", "kind": None},
]})
# 2. bike: start commands (one at a time, each after the machine's answer), data, hills
S.append({"name": "bike", "opts": {}, "steps": [
  {"add": "bike", "name": "HT2405118", "uuids": ["1826", "2ad2", "2ad9", "2ada"], "kind": "ftms_bike"},
  {"notify": "bike", "chars": [FULL("2ad2"), FULL("2ad9"), FULL("2ada")]},
  {"connected": "bike"},
  {"writes": ["bike 2ad9 00"]},  # take control; no reset (it clears the console's workout)
  {"rx": "bike", "char": "2ad9", "hex": "80 00 01"}, {"writes": ["bike 2ad9 07"]},  # answered: start
  {"rx": "bike", "char": "2ad2", "hex": IDLE}, {"update": 0.1},
  {"expect": {"speed_kmh": 0, "cadence": 0, "power": 0, "moving": False, "gait": "stopped", "kind": "ftms_bike"}},
  {"writes": []},  # the flat hill waits for the answer to start
  {"rx": "bike", "char": "2ad9", "hex": "80 07 01"}, {"writes": ["bike 2ad9 11 00 00 00 00 28 33"]},
  {"rx": "bike", "char": "2ad9", "hex": "80 11 01"},
  {"rx": "bike", "char": "2ad2", "hex": PEDAL}, {"update": 0.1},
  {"expect": {"speed_kmh": 25.6, "cadence": 85, "power": 140, "hr": 130, "moving": True, "gait": "sprint"}},
  {"events": [["start"], ["gait", "sprint"]]},
  {"grade": 5}, {"update": 0.3},
  {"writes": ["bike 2ad9 11 00 00 F4 01 28 33"]},
  {"grade": -2}, {"update": 0.1}, {"writes": []}, {"update": 0.2},  # no answer: the next goes after 0.3 s
  {"writes": ["bike 2ad9 11 00 00 38 FF 28 33"]},
  {"grade": -2.05}, {"update": 0.3}, {"writes": []},  # under 0.1 %: not sent again
  {"expect": {"grade": -2}},
  {"rx": "bike", "char": "2ada", "hex": "FF"}, {"writes": ["bike 2ad9 00"]},  # control lost: ask again
  {"remove": "bike"}, {"writes": ["bike 2ad9 08 01"]},
  {"expect": {"speed_kmh": None, "moving": False, "kind": None}},
]})
# 2b. a slow bike: nothing is sent while it's busy, commands keep their order, and it carries on
#     if an answer never comes
S.append({"name": "bike queue", "opts": {}, "steps": [
  {"add": "bike", "name": "Slow bike", "uuids": ["1826", "2ad2"]}, {"connected": "bike"},
  {"writes": ["bike 2ad9 00"]},
  {"grade": 3}, {"update": 0.1}, {"writes": []},  # start and the hill both wait
  {"rx": "bike", "char": "2ad9", "hex": "80 00 01"}, {"writes": ["bike 2ad9 07"]},
  {"update": 0.2}, {"writes": []}, {"update": 0.15},  # no answer to start in 0.3 s: carry on
  {"writes": ["bike 2ad9 11 00 00 2C 01 28 33"]},
]})
# 2c. a bike that only sends averages
S.append({"name": "bike averages", "opts": {}, "steps": [
  {"add": "bike", "name": "Avg bike", "uuids": ["1826", "2ad2"]}, {"connected": "bike"},
  {"rx": "bike", "char": "2ad2", "hex": "0B 00 D0 07 A0 00"}, {"update": 0.1},
  {"expect": {"speed_kmh": 20.0, "cadence": 80, "moving": True}},
]})
# 3. Sperax pad: polling, real frames, belt speed only when allowed and running
steps = [
  {"add": "pad", "name": "SPERAX_RM01", "uuids": ["fff0", "fff1", "fff2"], "kind": "sperax"},
  {"connected": "pad"}, {"writes": []},
  {"update": 0.25}, {"writes": ["pad fff2 F5 08 00 19 F0 0A 59 FA"]},
  {"rx": "pad", "char": "fff1", "hex": SPX_RUN[0][:30]}, {"rx": "pad", "char": "fff1", "hex": SPX_RUN[0][30:]},  # split frame
  {"update": 0.05},
  {"expect": {"speed_kmh": 2.0, "steps": 5, "moving": True, "kind": "sperax", "gait": "walk"}},
  {"belt": 3}, {"update": 1.2}, {"writes_without_status": []},  # not allowed: no speed command
  {"rx": "pad", "char": "fff1", "hex": SPX_STOP}, {"update": 0.05},
  {"expect": {"speed_kmh": 0, "moving": False, "gait": "stopped"}},
]
S.append({"name": "sperax", "opts": {}, "steps": steps})
S.append({"name": "sperax belt", "opts": {"allow_belt": True, "max_belt_kmh": 6}, "steps": [
  {"add": "pad", "name": "SPERAX_RM01", "uuids": ["fff0"], "kind": "sperax"}, {"connected": "pad"},
  {"belt": 3},
  {"rx": "pad", "char": "fff1", "hex": SPX_STOP}, {"update": 1.1},
  {"writes_without_status": []},  # stopped: never starts the belt
  {"rx": "pad", "char": "fff1", "hex": SPX_RUN[0]}, {"update": 1.1},
  {"writes_without_status": ["pad fff2 " + h(spx([0x15, 0x01, 26, 0x00]))]},  # 2.0 + 0.5 km/h per second x 1.1 s
  {"update": 1.1}, {"writes_without_status": []},  # the belt hasn't followed yet: wait, don't run ahead
  {"rx": "pad", "char": "fff1", "hex": SPX_RUN[2]}, {"update": 1.1},  # belt at 2.8: past the command, carry on
  {"writes_without_status": ["pad fff2 " + h(spx([0x15, 0x01, 30, 0x00]))]},
  {"remove": "pad"}, {"writes_without_status": ["pad fff2 " + h(spx([0x15, 0x00, 0x00, 0x00]))]},
]})
# 4. speed / cadence sensor: cadence mode, then speed mode
st = [{"add": "rb", "name": "ROCKBROS C3", "uuids": ["1816", "2a5b"], "kind": "csc"}, {"connected": "rb"}]
for i in range(1, 9):  # 90 rpm: a revolution every 0.667 s, packet every second
    st += [{"rx": "rb", "char": "2a5b", "hex": crank(int(i * 1.5), int(i * 1.5) * 683)}, {"update": 1.0}]
st += [{"expect": {"cadence": 90, "moving": True, "kind": "csc", "speed_kmh": None}}]
for i in range(9, 12):
    st += [{"rx": "rb", "char": "2a5b", "hex": crank(12, 12 * 683)}, {"update": 1.0}]
st += [{"expect": {"cadence": 0, "moving": False}}]
for i in range(1, 12):  # speed mode, 3 wheel revolutions a second on 2105 mm = 22.7 km/h
    st += [{"rx": "rb", "char": "2a5b", "hex": wheel(1000 + 3 * i, i * 1024 % 65536)}, {"update": 1.0}]
st += [{"expect": {"speed_kmh": 22.7, "moving": True, "cadence": None, "gait": "walk"}}]
S.append({"name": "csc", "opts": {}, "steps": st})
# 5. bike + sensor + strap combined
st = [{"add": "bike", "name": "HT2405118", "uuids": ["1826", "2ad2"]}, {"connected": "bike"},
      {"add": "rb", "name": "ROCKBROS C3", "uuids": ["1816"]}, {"connected": "rb"},
      {"add": "h10", "name": "Polar H10", "uuids": ["180d"]}, {"connected": "h10"}]
for i in range(1, 6):
    st += [{"rx": "bike", "char": "2ad2", "hex": PEDAL}, {"rx": "rb", "char": "2a5b", "hex": crank(i, i * 1024)},
           {"rx": "h10", "char": "2a37", "hex": "00 98"}, {"update": 1.0}]
st += [{"expect": {"speed_kmh": 25.6, "cadence": 60, "power": 140, "hr": 152, "moving": True, "kind": "ftms_bike",
                   "sources": {"speed": "bike", "cadence": "rb", "hr": "h10", "power": "bike", "moving": "rb"}}}]
S.append({"name": "combined", "opts": {}, "steps": st})
# 6. sprint on a bike that reports little power: cadence decides (85 rpm), power can too (200 W)
st = [{"add": "bike", "name": "HT2405118", "uuids": ["1826", "2ad2"]}, {"connected": "bike"},
      {"add": "rb", "name": "ROCKBROS C3", "uuids": ["1816"]}, {"connected": "rb"}]
for i in range(1, 8):  # 100 rpm: a revolution every 0.6 s (614/1024 s)
    st += [{"rx": "bike", "char": "2ad2", "hex": PEDAL}, {"rx": "rb", "char": "2a5b", "hex": crank(i, i * 614)}, {"update": 0.6}]
st += [{"expect": {"cadence": 100, "power": 140, "gait": "sprint"}}]
for i in range(8, 16):  # 80 rpm: still run
    st += [{"rx": "bike", "char": "2ad2", "hex": PEDAL}, {"rx": "rb", "char": "2a5b", "hex": crank(i, 7 * 614 + (i - 7) * 768)}, {"update": 0.75}]
st += [{"expect": {"cadence": 80, "gait": "run"}}]
S.append({"name": "sprint by cadence", "opts": {}, "steps": st})
# 6. footpod and 16-bit heart rate
S.append({"name": "rsc + hr16", "opts": {}, "steps": [
  {"add": "pod", "name": "RunPod", "uuids": ["1814"]}, {"connected": "pod"},
  {"add": "hr", "name": "Strap", "uuids": ["180d"]}, {"connected": "hr"},
  {"rx": "pod", "char": "2a53", "hex": "00 39 03 A0"},  # 825/256 m/s = 11.6 km/h, 160 spm
  {"rx": "hr", "char": "2a37", "hex": "01 B4 00"}, {"update": 0.1},
  {"expect": {"speed_kmh": 11.6, "cadence": 160, "hr": 180, "moving": True, "kind": "rsc", "gait": "sprint"}},
]})
json.dump(S, open("tests/sdk/vectors.json", "w"), indent=1)
print(len(S), "scenarios")
