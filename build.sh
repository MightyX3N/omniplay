#!/bin/sh
# Builds the Windows release into dist/OmniPlay/ and dist/OmniPlay.zip.
# Needs: gcc-mingw-w64-x86-64, zip, curl. Runs on Linux (also used by GitHub Actions).
set -e
cd "$(dirname "$0")"
LOVE_VER=11.5
LOVE_DIR=build/love-$LOVE_VER-win64

# 1. Bluetooth helper DLL
mkdir -p build
x86_64-w64-mingw32-gcc -shared -O2 -Wall -o build/omniplay_ble.dll native/omniplay_ble.c \
  -lruntimeobject -lole32 -static-libgcc -static

# 2. LÖVE runtime (downloaded once)
if [ ! -d "$LOVE_DIR" ]; then
  curl -sSfL -o build/love.zip "https://github.com/love2d/love/releases/download/$LOVE_VER/love-$LOVE_VER-win64.zip"
  unzip -q -o build/love.zip -d build
fi

# 3. Stamp the build, then fuse the Lua app into OmniPlay.exe
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo dev)$(git diff --quiet 2>/dev/null || echo +)"
printf 'return "%s %s"\n' "$BUILD" "$(date -u +%Y-%m-%d)" > app/version.lua
rm -rf dist && mkdir -p dist/OmniPlay
(cd app && zip -q -9 -r ../build/game.love .)
cat "$LOVE_DIR/love.exe" build/game.love > dist/OmniPlay/OmniPlay.exe
cp "$LOVE_DIR"/*.dll dist/OmniPlay/
cp "$LOVE_DIR/license.txt" dist/OmniPlay/LOVE-license.txt
cp build/omniplay_ble.dll LICENSE dist/OmniPlay/
(cd dist && zip -q -9 -r OmniPlay.zip OmniPlay)
echo "built dist/OmniPlay.zip"
