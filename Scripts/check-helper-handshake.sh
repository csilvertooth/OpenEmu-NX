#!/bin/bash
# Copyright (c) 2026, OpenEmu Team. See LICENSE.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:?Usage: check-helper-handshake.sh /path/to/OpenEmu-NX.app}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation
internal import os.log
extension OSLog { static let helper = OSLog(subsystem: "net.azimuthsystems.helpercheck", category: "test") }
do {
    let helper = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Contents/MacOS/OpenEmuHelperApp")
    let cn = try NSXPCConnection.makeConnection(serviceName: "org.openemu.broker", executableURL: helper)
    cn.resume()
    print("PASS: helper launched and completed its handshake without loading a ROM")
    cn.invalidate()
} catch { print("FAIL:", error); exit(1) }
SWIFT
swiftc -module-cache-path "$scratch/modules" "$repo/OpenEmuKit/Source/OEXPCMatchMaking.swift" "$repo/OpenEmuKit/Source/NSXPCConnection+HelperApp.swift" "$scratch/main.swift" -o "$scratch/check"
"$scratch/check" "$app"
