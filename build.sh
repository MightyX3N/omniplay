#!/bin/sh
# Builds the Windows release into dist/OmniPlay/ and dist/OmniPlay.zip.
# Needs: gcc-mingw-w64-x86-64, gcc-mingw-w64-i686 (32-bit GMod module), zip, curl. Runs on Linux (also used by GitHub Actions).
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

# 1b. Game SDK: client DLL for any language, and the Garry's Mod module (32- and 64-bit GMod)
SDKF="-shared -O2 -Wall -static-libgcc -Wl,--kill-at"
x86_64-w64-mingw32-gcc $SDKF -DOMNIPLAY_BUILD_DLL -o build/omniplay_client_x64.dll sdk/omniplay.c
i686-w64-mingw32-gcc   $SDKF -DOMNIPLAY_BUILD_DLL -o build/omniplay_client_x86.dll sdk/omniplay.c
x86_64-w64-mingw32-gcc $SDKF -o build/gmcl_omniplay_win64.dll sdk/gmod/gmcl_omniplay.c sdk/omniplay.c
i686-w64-mingw32-gcc   $SDKF -o build/gmcl_omniplay_win32.dll sdk/gmod/gmcl_omniplay.c sdk/omniplay.c

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
# the GMod module ships with the app, which installs it into garrysmod/lua/bin
mkdir -p dist/OmniPlay/gmod-module && cp build/gmcl_omniplay_win32.dll build/gmcl_omniplay_win64.dll dist/OmniPlay/gmod-module/
# the SDK for game developers, as its own zip
rm -rf dist/sdk && mkdir -p dist/sdk/OmniPlay-SDK/bin/x64 dist/sdk/OmniPlay-SDK/bin/x86 dist/sdk/OmniPlay-SDK/gmod dist/sdk/OmniPlay-SDK/love dist/sdk/OmniPlay-SDK/examples
cp sdk/omniplay.h sdk/omniplay.c sdk/LICENSE docs/SDK.md dist/sdk/OmniPlay-SDK/
cp build/omniplay_client_x64.dll dist/sdk/OmniPlay-SDK/bin/x64/omniplay_client.dll
cp build/omniplay_client_x86.dll dist/sdk/OmniPlay-SDK/bin/x86/omniplay_client.dll
cp build/gmcl_omniplay_win32.dll build/gmcl_omniplay_win64.dll sdk/gmod/gmcl_omniplay.c dist/sdk/OmniPlay-SDK/gmod/
cp -r gmod/omniplay_bridge dist/sdk/OmniPlay-SDK/gmod/
cp sdk/love/omniplay.lua dist/sdk/OmniPlay-SDK/love/
cp -r sdk/examples/. dist/sdk/OmniPlay-SDK/examples/
mkdir -p dist/sdk/OmniPlay-SDK/tools && cp sdk/tools/omniplay_sim.lua dist/sdk/OmniPlay-SDK/tools/
(cd dist/sdk && zip -q -9 -r ../OmniPlay-SDK.zip OmniPlay-SDK)
(cd dist && zip -q -9 -r OmniPlay.zip OmniPlay)
echo "built dist/OmniPlay.zip"
