#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────────────────────
# release.sh — builds the Release version of Yank, checks it, and installs it in /Applications.
# ≈ `./gradlew bundleRelease` + installing the APK, or `next build` + deploy.
#
# Usage: scripts/release.sh               Build, check, then install to /Applications/Yank.app.
#        scripts/release.sh --no-install  Build and check only; the app stays in build/.
#
# What it makes:
#   build/Yank.xcarchive                  The latest build's "archive": the app plus its dSYM
#                                         (debug symbols, ≈ a source map or ProGuard's mapping.txt).
#   build/Installed.xcarchive             A copy of the archive of the build last installed, kept
#                                         to read crash reports from the copy in /Applications.
#   /Applications/Yank.app                The installed app. Not opened: start it from Finder,
#                                         Spotlight or Launchpad.
#
# The installed Yank must not be running while it installs (macOS keeps a running app's files
# open), so the script stops with a message rather than quitting anything for you. A running
# debug build ("Yank Debug") doesn't matter: it is a separate app. Takes about a minute.
# ─────────────────────────────────────────────────────────────────────────────────────────────

# Stop on the first failure; see check-imports.sh for what each flag does.
set -euo pipefail
cd "$(dirname "$0")/.."

archive=build/Yank.xcarchive
app=$archive/Products/Applications/Yank.app
binary=$app/Contents/MacOS/Yank

# 1. Regenerate the Xcode project, then archive. `archive` always builds the Release
#    configuration (set in project.yml) and signs the app with the Apple Development
#    certificate. `generic/platform=macOS` means "any Mac" rather than this one, the
#    destination Xcode expects for an archive; project.yml limits it to Apple silicon.
xcodegen --quiet
rm -rf "$archive"
xcodebuild archive -scheme Yank -destination 'generic/platform=macOS' \
    -derivedDataPath build/release -archivePath "$archive" -quiet

# 2. Check the result before it goes anywhere. Each check stops the script if it fails.
# The signature covers every file in the app and is intact (≈ `apksigner verify`).
codesign --verify --strict "$app"
# Hardened runtime is on: macOS refuses injected code, unsigned plug-ins and libraries signed by
# anyone but Apple or this team ("library validation"). codesign shows it as the runtime flag.
# (Read into a variable first: `grep -q` straight off a pipe stops reading early, and pipefail
# would then count codesign's broken pipe as a failure.)
signature=$(codesign -dv "$app" 2>&1)
[[ "$signature" == *"flags="*"(runtime)"* ]] || { echo "Hardened runtime is off."; exit 1; }
# The entitlements are exactly the ones in App/Resources/Yank.entitlements: no debugger access
# (get-task-allow) and nothing else crept in. `plutil -p` prints them one per line (an array's
# items on their own lines, which is why the one service name sorts first).
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - | grep '=>' | sort)
expected='    0 => "com.apple.universalaccessAuthWarn"
  "com.apple.security.app-sandbox" => true
  "com.apple.security.files.user-selected.read-only" => true
  "com.apple.security.network.client" => true
  "com.apple.security.temporary-exception.mach-lookup.global-name" => ['
[[ "$entitlements" == "$expected" ]] || { echo "Unexpected entitlements:"; echo "$entitlements"; exit 1; }
# It is the Release app, com.thattechedguy.Yank, so it opens your real history and settings,
# not the debug build's (com.thattechedguy.Yank.debug, see project.yml).
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[[ "$bundle_id" == com.thattechedguy.Yank ]] || { echo "Unexpected bundle id: $bundle_id"; exit 1; }
# Apple silicon only.
[[ "$(lipo -archs "$binary")" == arm64 ]] || { echo "Not an arm64-only binary."; exit 1; }
# None of the debug-only code (`#if DEBUG`: the Developer window, --seed) made it in.
# grep -c counts matching lines; `|| true` because no match makes grep exit 1.
debug=$(strings "$binary" | grep -c -E 'StoreInspector|Open Data Folder|--seed' || true)
[[ "$debug" == 0 ]] || { echo "Debug-only code found in the Release binary."; exit 1; }
echo "Checks passed: $(du -sh "$app" | cut -f1) app, arm64, signed, hardened runtime, sandboxed."

[[ "${1:-}" == "--no-install" ]] && exit 0

# 3. Install. The installed copy must not be running while its files are replaced (macOS keeps a
#    running app's files open), so ask for it to be quit first. `pgrep -f` matches the whole
#    command line, here the executable's path, so a debug build ("Yank Debug", which runs from
#    the build folder) doesn't count: it is a separate app with its own data.
if pgrep -f '^/Applications/Yank.app/Contents/MacOS/Yank' > /dev/null; then
    echo "Yank is running. Quit it from its menu bar icon (Quit Yank), then run this again."
    exit 1
fi
# `ditto` copies an app bundle exactly, keeping its signature, symlinks and extended
# attributes (≈ `cp -R`, but safe for apps). The old copy goes first so no stale file survives.
rm -rf /Applications/Yank.app
ditto "$app" /Applications/Yank.app
# Keep this build's archive under its own name: its dSYM is the only file that can read crash
# reports from the installed copy, and the next `--no-install` run replaces build/Yank.xcarchive.
rm -rf build/Installed.xcarchive
ditto "$archive" build/Installed.xcarchive
echo "Installed /Applications/Yank.app (not opened). Its symbols: build/Installed.xcarchive."
