#!/usr/bin/env bash
# Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
# Compile only the replay probe against already-built Release products.
set -euo pipefail
if [[ $# != 2 ]]; then echo "usage: $0 RELEASE_PRODUCTS OUTPUT_EXECUTABLE" >&2; exit 2; fi
products="$(cd "$1" && pwd)"
source_dir="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$products/OpenEmuBase.framework/OpenEmuBase" && -f "$products/SNES9x.oecoreplugin/Contents/MacOS/SNES9x" ]] || {
    echo 'Build Release OpenEmu + SNES9x first; products are missing.' >&2; exit 1;
}
mkdir -p "$(dirname "$2")"
xcrun clang -fobjc-arc -arch arm64 -F "$products" -framework OpenEmuBase -framework Foundation -framework Cocoa \
    -Wl,-rpath,"$products" "$source_dir/snes-replay.m" -o "$2"
