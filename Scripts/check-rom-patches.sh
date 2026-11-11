#!/bin/bash
# Copyright (c) 2026, OpenEmu Team. See LICENSE.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cp "$repo/Scripts/check-rom-patches.swift" "$scratch/main.swift"
swiftc -module-cache-path "$scratch/modules" "$repo/OpenEmu/NXROMPatch.swift" "$scratch/main.swift" -o "$scratch/check"
"$scratch/check"
