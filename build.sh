#!/bin/sh
# Builds the Windows release into dist/OmniPlay/ and dist/OmniPlay.zip.
# Needs: gcc-mingw-w64-x86-64, zip, curl. Runs on Linux (also used by GitHub Actions).
set -e
cd "$(dirname "$0")"
LOVE_VER=11.5
LOVE_DIR=build/love-$LOVE_VER-win64

# 1. Helper DLL: Bluetooth (WinRT) + the HTTPS front door for phone cameras (mbedTLS, Apache-2.0)
mkdir -p build
MBEDTLS_VER=v3.6.2
MBEDTLS=build/mbedtls-$MBEDTLS_VER
if [ ! -d "$MBEDTLS" ]; then
  git clone -q --depth 1 --branch "$MBEDTLS_VER" https://github.com/Mbed-TLS/mbedtls.git "$MBEDTLS"
fi
if [ ! -f "$MBEDTLS/libmbed-win.a" ]; then
  mkdir -p build/mbed-obj
  for f in "$MBEDTLS"/library/*.c; do
    x86_64-w64-mingw32-gcc -O2 -w -I"$MBEDTLS/include" -c "$f" -o "build/mbed-obj/$(basename "$f" .c).o"
  done
  x86_64-w64-mingw32-ar rcs "$MBEDTLS/libmbed-win.a" build/mbed-obj/*.o
fi
x86_64-w64-mingw32-gcc -shared -O2 -Wall -o build/omniplay_ble.dll native/omniplay_ble.c native/omniplay_tls.c \
  -I"$MBEDTLS/include" "$MBEDTLS/libmbed-win.a" \
  -lruntimeobject -lole32 -lws2_32 -lbcrypt -static-libgcc -static

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
cp "$MBEDTLS/LICENSE" dist/OmniPlay/mbedTLS-LICENSE.txt
mkdir -p dist/OmniPlay/gmod-addon && cp -r gmod/omniplay_bridge dist/OmniPlay/gmod-addon/ && cp docs/API.md dist/OmniPlay/
# the SDK for game developers, as its own zip (pure Lua + JS core, Android adapter, docs)
rm -rf dist/sdk && mkdir -p dist/sdk/OmniPlay-SDK
cp -r sdk/lua sdk/js sdk/android sdk/LICENSE docs/SDK.md dist/sdk/OmniPlay-SDK/
(cd dist/sdk && zip -q -9 -r ../OmniPlay-SDK.zip OmniPlay-SDK)
(cd dist && zip -q -9 -r OmniPlay.zip OmniPlay)
echo "built dist/OmniPlay.zip"
