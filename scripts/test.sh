#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────────────────────
# test.sh — runs Yank's tests. ≈ `bun test` plus an e2e step, or `./gradlew check connectedCheck`.
#
# Usage: scripts/test.sh          Full run: import check, package tests, then UI tests.
#                                 Run it before every commit. Takes about a minute.
#        scripts/test.sh --fast   Import check and package tests only. No app launch, a few
#                                 seconds. Run it often while coding.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────

# Stop on the first failure; see check-imports.sh for what each flag does.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. Module boundary check (fails fast, before any compiling).
scripts/check-imports.sh
# 2. Unit and integration tests in the local package. `swift test` builds and runs every test
#    target in Package.swift. The parentheses run it in a subshell so the `cd` doesn't leak.
#    In --fast mode the tests whose names start with "slow" (they seed 100,000 items) are
#    skipped; `--skip` matches test names by regular expression.
if [[ "${1:-}" == "--fast" ]]; then
    (cd Packages/ClipCore && swift test --skip '/slow')
else
    (cd Packages/ClipCore && swift test)
fi

# In --fast mode we are done: skip the UI tests, which need a full app build and a launch.
# ("${1:-}" is the first argument, or "" if there is none; plain "$1" would trip `set -u`.)
[[ "${1:-}" == "--fast" ]] && exit 0

echo "UI tests launch Yank and may write to your clipboard."
# The tests run the Debug build, "Yank Debug" (bundle id com.thattechedguy.Yank.debug), which has
# its own history and settings. Your everyday Release copy (com.thattechedguy.Yank) is quit while
# they run anyway: it would save every test copy into your real history, and it holds ⇧⌘V.
# We remember where it was and reopen it at the end.
# Find it among the running processes named Yank (both builds have that process name):
# pgrep -x matches the exact name, `|| true` keeps `set -e` from stopping the script when nothing
# matches. ps prints each one's executable path (…/Yank.app/Contents/MacOS/Yank), sed trims it
# back to the .app folder, and PlistBuddy reads that app's bundle id from its Info.plist.
daily_path=""
for pid in $(pgrep -x Yank || true); do
    path=$(ps -o comm= -p "$pid" | sed 's|/Contents/MacOS/Yank$||')
    id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist" 2>/dev/null || true)
    [[ "$id" == com.thattechedguy.Yank ]] && daily_path=$path
done
# Ask the app to quit politely (AppleScript), the same as choosing Quit from its menu, then give
# it a second to go away before the tests start.
[[ -n "$daily_path" ]] && osascript -e 'quit app id "com.thattechedguy.Yank"' && sleep 1
# Reopen the everyday copy when the script ends, pass or fail, so a failed test run does not leave
# you without your clipboard manager. (`trap ... EXIT` ≈ a `finally` block.)
trap '[[ -n "$daily_path" ]] && open "$daily_path"' EXIT

# 3. Regenerate the Xcode project (in case files were added), then run only the UI test target.
#    The package tests already ran above, so we skip them here.
#    -derivedDataPath build   keep build output in ./build (git-ignored) instead of ~/Library.
#    -destination ...arm64    this Mac, Apple silicon (otherwise xcodebuild warns about picking).
#    -quiet                   print only warnings, errors and the result.
xcodegen --quiet
xcodebuild test -scheme Yank -derivedDataPath build -destination 'platform=macOS,arch=arm64' \
    -only-testing:YankUITests -quiet
