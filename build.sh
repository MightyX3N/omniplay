#!/bin/sh
# Builds the Windows app into dist/OmniPlay/ (+ dist/OmniPlay.zip) and the SDK into dist/OmniPlay-SDK.zip.
# Needs: gcc-mingw-w64-x86-64, zip, curl. Runs on Linux (GitHub Actions runs it on every push).
set -e
cd "$(dirname "$0")"
LOVE_VER=11.5
LOVE_DIR=build/love-$LOVE_VER-win64
mkdir -p build

# 1. Windows Bluetooth helper (WinRT), called from Lua through FFI
x86_64-w64-mingw32-gcc -shared -O2 -Wall -o build/omniplay_ble.dll native/omniplay_ble.c \
  -lruntimeobject -lole32 -lws2_32 -static-libgcc -static

# 2. LÖVE runtime (downloaded once)
if [ ! -d "$LOVE_DIR" ]; then
  curl -sSfL -o build/love.zip "https://github.com/love2d/love/releases/download/$LOVE_VER/love-$LOVE_VER-win64.zip"
  unzip -q -o build/love.zip -d build
fi

# 3. the app: SDK copied in, build stamped, fused into OmniPlay.exe
cp sdk/lua/omniplay.lua app/lib/omniplay.lua
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo dev)$(git diff --quiet 2>/dev/null || echo +)"
printf 'return "%s %s"\n' "$BUILD" "$(date -u +%Y-%m-%d)" > app/version.lua
rm -rf dist && mkdir -p dist/OmniPlay
rm -f build/game.love
(cd app && zip -q -9 -r ../build/game.love . -x 'test/*')
cat "$LOVE_DIR/love.exe" build/game.love > dist/OmniPlay/OmniPlay.exe
cp "$LOVE_DIR"/*.dll dist/OmniPlay/
cp "$LOVE_DIR/license.txt" dist/OmniPlay/LOVE-license.txt
cp build/omniplay_ble.dll LICENSE dist/OmniPlay/
mkdir -p dist/OmniPlay/licenses
cp app/art/fonts/OFL-*.txt app/art/muchopixels/LICENSE.txt dist/OmniPlay/licenses/
cp app/art/loopsnrings/LICENSE.txt dist/OmniPlay/licenses/CC0-art.txt
mkdir -p dist/OmniPlay/gmod-addon && cp -r gmod/omniplay_bridge dist/OmniPlay/gmod-addon/
(cd dist && zip -q -9 -r OmniPlay.zip OmniPlay)

# 4. the SDK for game developers, as its own zip
mkdir -p dist/sdk/OmniPlay-SDK
cp -r sdk/lua sdk/js sdk/android sdk/LICENSE docs/SDK.md dist/sdk/OmniPlay-SDK/
(cd dist/sdk && zip -q -9 -r ../OmniPlay-SDK.zip OmniPlay-SDK)
echo "built dist/OmniPlay.zip and dist/OmniPlay-SDK.zip"
