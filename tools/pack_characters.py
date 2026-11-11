#!/usr/bin/env python3
"""Builds the character sheets in app/art/muchopixels/ from Mucho Pixels' Character Animation Asset Pack.

Usage: python3 tools/pack_characters.py "<pack>/Exported PNGs" app/art/muchopixels

One sheet per character and outfit (male_1_1.png ... female_3_3.png), 64x64 frames, one row per
animation (see ANIMS). The shirt is swapped for two marker colours so the game can give every
player their own shirt colour (app/runner.lua): a shirt pixel is one whose colour is in that
outfit's shirt ramp and that differs from the same frame without clothes.
"""
import glob
import os
import sys

from PIL import Image

ANIMS = [("idle", 8), ("walk", 8), ("run", 8), ("jump", 2), ("fall", 2), ("land", 2), ("damage", 2)]
COLS, SIZE = 8, 64
# shirt ramp (light, dark) per outfit number
SHIRT = {1: ((234, 50, 60), (196, 36, 48)), 2: ((90, 197, 79), (51, 152, 75)), 3: ((255, 255, 255), (199, 207, 221))}
MARK_LIGHT, MARK_DARK = (255, 0, 255), (128, 0, 128)


def frame(folder, anim, i):
    hits = glob.glob(os.path.join(folder, f"*_{anim}_{i}.png"))
    if not hits:
        raise SystemExit(f"missing {anim} {i} in {folder}")
    return Image.open(hits[0]).convert("RGBA")


def main(src, dst):
    os.makedirs(dst, exist_ok=True)
    for gender in ("Male", "Female"):
        for c in (1, 2, 3):
            base = os.path.join(src, gender, f"Character {c}")
            for o in (1, 2, 3):
                light, dark = SHIRT[o]
                sheet = Image.new("RGBA", (COLS * SIZE, len(ANIMS) * SIZE), (0, 0, 0, 0))
                for row, (anim, n) in enumerate(ANIMS):
                    for i in range(n):
                        im = frame(os.path.join(base, f"Clothes {o}"), anim, i)
                        bare = frame(os.path.join(base, "No Clothes"), anim, i)
                        px, bp = im.load(), bare.load()
                        for y in range(SIZE):
                            for x in range(SIZE):
                                p = px[x, y]
                                if p[3] and p != bp[x, y]:
                                    if p[:3] == light:
                                        px[x, y] = MARK_LIGHT + (255,)
                                    elif p[:3] == dark:
                                        px[x, y] = MARK_DARK + (255,)
                        sheet.paste(im, (i * SIZE, row * SIZE))
                out = os.path.join(dst, f"{gender.lower()}_{c}_{o}.png")
                sheet.save(out, optimize=True)
                print("wrote", out)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
