#!/bin/bash
# Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nx-stun-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
python3 - "$repo" "$scratch" <<'PYCODE'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
src = (root/'OpenEmu/NetworkPlayController.swift').read_text().split('// MARK: - Bounded UDP STUN check', 1)[1]
(out/'Probe.swift').write_text('import Foundation\nimport Network\n//' + src + (root/'Scripts/check-network-stun.swift').read_text())
PYCODE
swiftc -module-cache-path "$scratch/modules" -parse-as-library "$scratch/Probe.swift" -o "$scratch/check"
"$scratch/check" "$@"
