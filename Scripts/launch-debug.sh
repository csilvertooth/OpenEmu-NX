#!/bin/bash
#
# launch-debug.sh — launch the freshest debug OpenEmu.app, refusing stale builds.
#
# Why this script exists:
#   `open <path>` and bare `open -a OpenEmu` happily launch a stale debug build
#   from an old DerivedData hash whenever Xcode rotates the hash (workspace path
#   change, scheme change, system cleanup). The user only finds out when the UI
#   looks wrong. This script picks the newest OpenEmu.app across all known build
#   locations and refuses to launch if source is newer than the binary or an
#   app/game helper is already running. It never closes a running game.
#
# Usage:
#   ./Scripts/launch-debug.sh            # newest Debug build
#   ./Scripts/launch-debug.sh --release  # newest Release build instead
#   ./Scripts/launch-debug.sh --force    # skip staleness check

set -uo pipefail

CONFIG="Debug"
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --release) CONFIG="Release" ;;
        --force) FORCE=1 ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "launch-debug: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 1a. Prefer the build for the current git branch if one exists. This avoids
#     accidentally launching another worktree's newer binary just because it
#     was built more recently. Falls through to global newest-wins below.
BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|/|-|g')
BRANCH_APP=""
if [[ -n "$BRANCH" && "$BRANCH" != "HEAD" ]]; then
    candidate="$HOME/Builds/openemu/$BRANCH/Build/Products/$CONFIG/OpenEmu.app"
    if [[ -f "$candidate/Contents/MacOS/OpenEmu" ]]; then
        BRANCH_APP="$candidate"
    fi
fi

# 1b. Find newest OpenEmu.app across both DerivedData and the worktree-stable build dir.
APPS=()
while IFS= read -r p; do APPS+=("$p"); done < <(
    {
        find "$HOME/Library/Developer/Xcode/DerivedData" \
            -maxdepth 5 \
            -path "*/Build/Products/$CONFIG/OpenEmu.app" \
            -prune 2>/dev/null
        find "$HOME/Builds/openemu" \
            -maxdepth 5 \
            -path "*/Build/Products/$CONFIG/OpenEmu.app" \
            -prune 2>/dev/null
    }
)

if [[ ${#APPS[@]} -eq 0 ]]; then
    echo "launch-debug: no OpenEmu.app found in DerivedData or ~/Builds/openemu for config $CONFIG." >&2
    echo "  build first: ./Scripts/build-for-worktree.sh" >&2
    exit 1
fi

NEWEST=""
NEWEST_MTIME=0
for app in "${APPS[@]}"; do
    bin="$app/Contents/MacOS/OpenEmu"
    [[ -f "$bin" ]] || continue
    mt=$(stat -f %m "$bin")
    if (( mt > NEWEST_MTIME )); then
        NEWEST_MTIME=$mt
        NEWEST="$app"
    fi
done

if [[ -z "$NEWEST" ]]; then
    echo "launch-debug: found .app bundles but no OpenEmu binary inside any of them." >&2
    exit 1
fi

# Branch-match wins over global newest. Note when this differs so the user can
# tell whether they're running a build that's branch-correct vs just freshest.
if [[ -n "$BRANCH_APP" ]]; then
    if [[ "$BRANCH_APP" != "$NEWEST" ]]; then
        echo "launch-debug: using current-branch build ($BRANCH); a newer build exists for a different branch."
        echo "  current : $BRANCH_APP"
        echo "  newer   : $NEWEST"
    fi
    NEWEST="$BRANCH_APP"
    NEWEST_MTIME=$(stat -f %m "$NEWEST/Contents/MacOS/OpenEmu")
fi

# 2. Staleness check — refuse if any source file is newer than the binary.
if [[ $FORCE -eq 0 ]]; then
    NEWEST_SRC=$(find "$REPO_ROOT/OpenEmu" \
        \( -name '*.swift' -o -name '*.m' -o -name '*.h' \) \
        -type f -print0 2>/dev/null \
        | xargs -0 stat -f '%m %N' 2>/dev/null \
        | sort -rn | head -n1)
    if [[ -n "$NEWEST_SRC" ]]; then
        SRC_MTIME=${NEWEST_SRC%% *}
        SRC_PATH=${NEWEST_SRC#* }
        if (( SRC_MTIME > NEWEST_MTIME )); then
            echo "launch-debug: source newer than build — refusing to launch a stale binary." >&2
            echo "  newest source : $SRC_PATH" >&2
            echo "  newest build  : $NEWEST" >&2
            echo "  fix: ./Scripts/build-for-worktree.sh   (or pass --force to launch anyway)" >&2
            exit 1
        fi
    fi
fi

# Do not interrupt a game or create a second copy. Check before signing too:
# re-signing a bundle in use can disrupt the running app and its helpers.
# A process-inspection failure is not proof that it is safe to launch.
assert_no_running_game() {
    local process result
    for process in OpenEmu OpenEmuHelperApp emu-live; do
        pgrep -x "$process" >/dev/null 2>&1
        result=$?
        if [[ $result -eq 0 ]]; then
            echo "launch-debug: $process is already running; leaving it untouched." >&2
            echo "  Save and quit it yourself when ready, then run this command once." >&2
            return 1
        elif [[ $result -ne 1 ]]; then
            echo "launch-debug: cannot verify running apps; refusing to launch." >&2
            return 1
        fi
    done
}
assert_no_running_game || exit 1

# Sign debug builds with a stable local certificate so macOS keeps the Input Monitoring grant across rebuilds.
# Ad-hoc signatures change on every build, which silently revokes it. Create a code-signing certificate named
# "OpenEmu Debug" in Keychain Access (or set OE_DEBUG_SIGN_IDENTITY); without one the build is launched as is.
if [[ "$CONFIG" == "Debug" ]]; then
    SIGN_NAME="${OE_DEBUG_SIGN_IDENTITY:-OpenEmu Debug}"
    if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_NAME\""; then
        if ! codesign -dvv "$NEWEST" 2>&1 | grep -qxF "Authority=$SIGN_NAME"; then
            echo "launch-debug: signing with \"$SIGN_NAME\" so permissions survive rebuilds"
            codesign --force --deep --preserve-metadata=entitlements,requirements,flags,runtime \
                --sign "$SIGN_NAME" "$NEWEST" >/dev/null 2>&1 \
                || echo "launch-debug: warning: signing failed, launching the ad-hoc build" >&2
        fi
    else
        echo "launch-debug: no \"$SIGN_NAME\" certificate found — Input Monitoring will need re-granting after each rebuild." >&2
    fi
fi

# Recheck after signing, in case the user opened a game in the meantime.
assert_no_running_game || exit 1
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NEWEST/Contents/Info.plist" 2>/dev/null || printf 'unknown')
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$NEWEST/Contents/Info.plist" 2>/dev/null || printf 'unknown')
echo "launch-debug: opening $VERSION (build $BUILD)"
echo "  $NEWEST"

# A single Launch Services request. Do not force another instance with -n,
# retry in a loop, or submit this command to a restarting service.
open "$NEWEST"
