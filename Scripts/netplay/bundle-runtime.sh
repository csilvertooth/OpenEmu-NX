#!/bin/bash
# Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
cmake_bin="$(command -v cmake || true)"
if [[ -z "$cmake_bin" && -x /opt/homebrew/bin/cmake ]]; then cmake_bin=/opt/homebrew/bin/cmake; fi
[[ -n "$cmake_bin" ]] || { echo 'error: CMake is required for Network Play runtime support.' >&2; exit 1; }
build="$TARGET_TEMP_DIR/NetworkRuntime"
dest="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/NetworkPlay"
"$cmake_bin" -S "$repo/Runtime/Snes9x" -B "$build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
"$cmake_bin" --build "$build" --target emu-identity -j 8
license_dest="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/NetworkPlayLicenses"
mkdir -p "$dest" "$license_dest"
rm -f "$dest/Snes9x-LICENSE" "$dest/GameNetworkingSockets-LICENSE"
# Replace executables with a new inode. Overwriting a mapped Mach-O can leave
# macOS's code-signature cache referring to the previous running helper.
copy_binary() {
    cp "$1" "$2.new"
    mv -f "$2.new" "$2"
}
copy_binary "$build/emu-identity" "$dest/emu-identity"
copy_binary "$build/libemu_snes.dylib" "$dest/libemu_snes.dylib"
cp "$repo/SNES9x/src/LICENSE" "$license_dest/Snes9x-LICENSE"
# Use separately built public Valve/OpenSSL/Protobuf dependencies.
gns_root="${EMU_GNS_ROOT:-$repo/Dependencies/GameNetworkingSockets}"
deps_root="${EMU_DEPS_ROOT:-$repo/Dependencies/macos14.0}"
gns_archive="${EMU_GNS_ARCHIVE:-$gns_root/build/src/libGameNetworkingSockets_s.a}"
"$cmake_bin" -S "$repo/Runtime/Netplay" -B "$TARGET_TEMP_DIR/NetworkSession" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DGNS_ROOT="$gns_root" -DGNS_ARCHIVE="$gns_archive" -DDEPS_ROOT="$deps_root" -DRUNTIME_LIBRARY="$build/libemu_snes.dylib"
"$cmake_bin" --build "$TARGET_TEMP_DIR/NetworkSession" --target emu-live -j 8
copy_binary "$TARGET_TEMP_DIR/NetworkSession/emu-live" "$dest/emu-live"
cp "$gns_root/LICENSE" "$license_dest/GameNetworkingSockets-LICENSE"
game_app="$dest/NetworkPlay.app"
mkdir -p "$game_app/Contents/MacOS"
copy_binary "$dest/emu-live" "$game_app/Contents/MacOS/emu-live"
copy_binary "$dest/libemu_snes.dylib" "$game_app/Contents/MacOS/libemu_snes.dylib"
cat > "$game_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>emu-live</string>
<key>CFBundleIdentifier</key><string>org.openemu.NetworkPlay.debug</string>
<key>CFBundleName</key><string>Network Play</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [[ "${CODE_SIGNING_ALLOWED:-NO}" != NO && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$dest/libemu_snes.dylib"
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$dest/emu-identity"
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$dest/emu-live"
    copy_binary "$dest/libemu_snes.dylib" "$game_app/Contents/MacOS/libemu_snes.dylib"
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$game_app"
fi
