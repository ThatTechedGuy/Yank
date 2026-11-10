#!/bin/bash
# Builds the Release version of Yank and checks it.
#
# Usage: scripts/release.sh               Build, check, then install to /Applications/Yank.app.
#        scripts/release.sh --no-install  Build and check only; the app stays in build/.
#        scripts/release.sh --zip         Build an ad hoc signed copy, check it and write
#                                         build/Yank-<version>.zip, the file a GitHub release ships.
#
# build/Yank.xcarchive holds the latest build and its dSYM. An install also copies it to
# build/Installed.xcarchive, the only symbols that can read crash reports from the installed app.
# The installed Yank must not be running during an install; "Yank Debug" is a separate app.
set -euo pipefail
cd "$(dirname "$0")/.."

mode=${1:-}
archive=build/Yank.xcarchive
app=$archive/Products/Applications/Yank.app
binary=$app/Contents/MacOS/Yank

# A zip for other people is always ad hoc signed, whatever Signing.local.xcconfig says: a
# personal Apple Development certificate carries its owner's Apple ID and expires within a year.
signing=""
[[ "$mode" == "--zip" ]] && signing="CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="

xcodegen --quiet
rm -rf "$archive"
# shellcheck disable=SC2086  # $signing is two words on purpose.
xcodebuild archive -scheme Yank -destination 'generic/platform=macOS' \
    -derivedDataPath build/release -archivePath "$archive" -quiet $signing

# Each check stops the script if it fails.
codesign --verify --strict "$app"
# Read into a variable first: `grep -q` on a pipe exits early and pipefail then fails codesign.
signature=$(codesign -dv "$app" 2>&1)
[[ "$signature" == *"flags="*"runtime"* ]] || { echo "Hardened runtime is off."; exit 1; }
# Exactly the entitlements in App/Resources/Yank.entitlements: no get-task-allow, nothing extra.
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - | grep '=>' | sort)
expected='    0 => "com.apple.universalaccessAuthWarn"
  "com.apple.security.app-sandbox" => true
  "com.apple.security.files.user-selected.read-only" => true
  "com.apple.security.network.client" => true
  "com.apple.security.temporary-exception.mach-lookup.global-name" => ['
[[ "$entitlements" == "$expected" ]] || { echo "Unexpected entitlements:"; echo "$entitlements"; exit 1; }
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[[ "$bundle_id" == com.thattechedguy.Yank ]] || { echo "Unexpected bundle id: $bundle_id"; exit 1; }
[[ "$(lipo -archs "$binary")" == arm64 ]] || { echo "Not an arm64-only binary."; exit 1; }
# None of the `#if DEBUG` code (the Developer window, --seed) made it in.
debug=$(strings "$binary" | grep -c -E 'StoreInspector|Open Data Folder|--seed' || true)
[[ "$debug" == 0 ]] || { echo "Debug-only code found in the Release binary."; exit 1; }
echo "Checks passed: $(du -sh "$app" | cut -f1) app, arm64, signed, hardened runtime, sandboxed."

[[ "$mode" == "--no-install" ]] && exit 0

if [[ "$mode" == "--zip" ]]; then
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
    zip=build/Yank-$version.zip
    rm -f "$zip"
    # ditto keeps the signature, symlinks and extended attributes that `zip` can lose.
    ditto -c -k --keepParent "$app" "$zip"
    echo "Wrote $zip"
    shasum -a 256 "$zip"
    exit 0
fi

# `pgrep -f` matches the executable's path, so a running "Yank Debug" doesn't count.
if pgrep -f '^/Applications/Yank.app/Contents/MacOS/Yank' > /dev/null; then
    echo "Yank is running. Quit it from its menu bar icon (Quit Yank), then run this again."
    exit 1
fi
# The old copy goes first so no stale file survives.
rm -rf /Applications/Yank.app
ditto "$app" /Applications/Yank.app
rm -rf build/Installed.xcarchive
ditto "$archive" build/Installed.xcarchive
echo "Installed /Applications/Yank.app (not opened). Its symbols: build/Installed.xcarchive."
