#!/bin/bash
# Runs Yank's tests.
#
# Usage: scripts/test.sh          Import check, package tests, then UI tests. About a minute.
#        scripts/test.sh --fast   Import check and package tests minus the slow ones. No app
#                                 launch, a few seconds.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/check-imports.sh
# --fast skips the tests whose names start with "slow" (they seed 100,000 items).
if [[ "${1:-}" == "--fast" ]]; then
    (cd Packages/ClipCore && swift test --skip '/slow')
    exit 0
fi
# On CI (GitHub sets CI) two tests that need a real Mac are skipped: the search timing test (its
# 33 ms budget measured 42 ms on the shared runner) and the one that reads words from an image
# (Vision found none on the runner's virtual Mac; presumably it has no Neural Engine).
(cd Packages/ClipCore && swift test ${CI:+--skip 'slowSearchOverAHundredThousandItems|slowWordsInAnImage'})

echo "UI tests launch Yank and may write to your clipboard."
# The tests run "Yank Debug", which has its own history. The everyday Release copy is quit while
# they run: it would save every test copy into the real history, and it holds ⇧⌘V. Both builds
# have the process name Yank, so tell them apart by bundle id.
daily_path=""
for pid in $(pgrep -x Yank || true); do
    path=$(ps -o comm= -p "$pid" | sed 's|/Contents/MacOS/Yank$||')
    id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist" 2>/dev/null || true)
    [[ "$id" == com.thattechedguy.Yank ]] && daily_path=$path
done
[[ -n "$daily_path" ]] && osascript -e 'quit app id "com.thattechedguy.Yank"' && sleep 1
# Reopen the everyday copy when the script ends, pass or fail.
trap '[[ -n "$daily_path" ]] && open "$daily_path"' EXIT

xcodegen --quiet
xcodebuild test -scheme Yank -derivedDataPath build -destination 'platform=macOS,arch=arm64' \
    -only-testing:YankUITests -quiet
