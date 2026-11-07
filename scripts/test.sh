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
(cd Packages/ClipCore && swift test)

# In --fast mode we are done: skip the UI tests, which need a full app build and a launch.
# ("${1:-}" is the first argument, or "" if there is none; plain "$1" would trip `set -u`.)
[[ "${1:-}" == "--fast" ]] && exit 0

echo "UI tests launch Yank and may write to your clipboard."
# If you're running your everyday copy of Yank, quit it first: two copies would both watch the
# clipboard and fight over the ⇧⌘V shortcut. We remember where it was and reopen it at the end.
# Find the running copy's process id, if any. pgrep -x matches the exact process name; `|| true`
# keeps `set -e` from stopping the script when nothing matches (pgrep exits 1 then).
daily=$(pgrep -x Yank | head -1 || true)
# Remember which .app to reopen later, but only if a copy was running (${daily:+...} expands to
# the command's output only when $daily is non-empty). ps prints the executable's path
# (…/Yank.app/Contents/MacOS/Yank); sed trims it back to the .app folder that `open` needs.
daily_path=${daily:+$(ps -o comm= -p "$daily" | sed 's|/Contents/MacOS/Yank$||')}
# Ask the app to quit politely (AppleScript), the same as choosing Quit from its menu, then give
# it a second to go away before the tests launch their own copy.
[[ -n "$daily" ]] && osascript -e 'quit app id "com.thattechedguy.Yank"' && sleep 1
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
